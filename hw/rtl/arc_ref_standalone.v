`timescale 1ns / 1ps
// Standalone build: the referee in the FPGA fabric only, no ARM, no SD card.
// Load it over the Zybo's USB cable with openFPGALoader from macOS, Windows
// or Linux (see README). The board's 125 MHz fabric clock (pin K17) runs it,
// so the PS never has to boot.
//
// The Zybo's own USB-serial port is wired to the PS, so the browser link uses
// a USB-UART on Pmod JE instead (Digilent PmodUSBUART or any 3.3 V USB-serial
// adapter):
//   JE2  FPGA TX -> adapter RX      (SW3 down)
//   JE3  FPGA RX <- adapter TX
//   SW3 up swaps JE2 and JE3, for adapters that label the pins the other way.
// Robot link on Pmod JD (3.3 V UART, 115200 8N1, like the referee's User port):
//   JD1  FPGA TX -> robot RX,  JD2  FPGA RX <- robot TX,  JD5 GND
module arc_ref_standalone #(
    parameter integer USE_MMCM   = 1,            // 0 in simulation: clk is the core clock
    parameter integer CLK_HZ     = 50_000_000,   // core clock after the MMCM
    parameter integer PC_BAUD    = 115_200,
    parameter integer ROBOT_BAUD = 115_200,
    parameter integer DEBOUNCE_MS = 10
) (
    input  wire       sysclk,      // 125 MHz from the Ethernet PHY (K17)
    input  wire [3:0] btn,
    input  wire [3:0] sw,
    output wire [3:0] led,
    inout  wire       pc_a,        // JE2
    inout  wire       pc_b,        // JE3
    output wire       robot_tx,    // JD1
    input  wire       robot_rx     // JD2
);
    // ------------------------------------------------------------ clock
    wire clk;
    wire locked;
    generate
        if (USE_MMCM) begin : g_mmcm
            wire clk_mmcm, clk_fb;
            // 125 MHz x 8 = 1000 MHz VCO, / 20 = 50 MHz
            MMCME2_BASE #(
                .CLKIN1_PERIOD(8.0),
                .CLKFBOUT_MULT_F(8.0),
                .DIVCLK_DIVIDE(1),
                .CLKOUT0_DIVIDE_F(20.0)
            ) u_mmcm (
                .CLKIN1(sysclk), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
                .CLKOUT0(clk_mmcm), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
                .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
                .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
            );
            BUFG u_bufg (.I(clk_mmcm), .O(clk));
        end else begin : g_direct
            assign clk = sysclk;
            assign locked = 1'b1;
        end
    endgenerate

    // Power-on reset: held until the clock is stable plus 256 cycles.
    reg [8:0] por = 9'd0;
    always @(posedge clk or negedge locked) begin
        if (!locked)        por <= 9'd0;
        else if (!por[8])   por <= por + 9'd1;
    end
    wire rst = !por[8];

    // ------------------------------------------------------ PC link (JE)
    reg [2:0] swap_s;
    always @(posedge clk) swap_s <= {swap_s[1:0], sw[3]};
    wire swap = swap_s[2];

    wire pc_txd;
    assign pc_a = swap ? 1'bz : pc_txd;
    assign pc_b = swap ? pc_txd : 1'bz;
    wire pc_rxd = swap ? pc_a : pc_b;

    wire       rx_valid;
    wire [7:0] rx_byte;
    arc_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(PC_BAUD)) u_pc_rx (
        .clk(clk), .rst(rst), .rxd(pc_rxd), .valid(rx_valid), .data(rx_byte)
    );

    wire [7:0] tx_byte;
    wire       tx_empty, tx_ready;
    arc_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(PC_BAUD)) u_pc_tx (
        .clk(clk), .rst(rst), .valid(!tx_empty), .data(tx_byte), .ready(tx_ready),
        .txd(pc_txd)
    );

    // ----------------------------------------------------------- referee
    arc_ref_top #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .FIFO_AW(10),
                  .ROBOT_BAUD(ROBOT_BAUD)) u_top (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte(rx_byte),
        .tx_rd(tx_ready && !tx_empty), .tx_byte(tx_byte), .tx_empty(tx_empty), .tx_count(),
        .rx_ok(), .rx_err(),
        .btn(btn), .sw({1'b0, sw[2:0]}), .led(led), .inputs_level(),
        .robot_tx(robot_tx), .robot_rx(robot_rx)
    );
endmodule
