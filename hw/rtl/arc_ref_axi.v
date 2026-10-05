`timescale 1ns / 1ps
// AXI4-Lite wrapper so the Zynq PS can move bytes between its UART1 (the
// Zybo USB-UART) and the referee logic. Used as a module reference in the
// Vivado block design, so it has to stay plain Verilog.
//
// Register map (32-bit, byte offsets):
//   0x00 ID       RO  0x41524346 ("ARCF")
//   0x04 VERSION  RO  0x00010000
//   0x08 RX_DATA  WO  [7:0] byte from the browser
//   0x0C TX_DATA  RO  [8] valid, [7:0] next byte to the browser (read pops)
//   0x10 STATUS   RO  [15:0] TX FIFO level, [16] TX FIFO empty
//   0x14 CTRL     RW  [0] soft reset of the referee logic
//   0x18 COUNTERS RO  [15:0] good control frames, [31:16] bad control frames
//   0x1C INPUTS   RO  [3:0] buttons, [7:4] switches (debounced)
module arc_ref_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 6,
    parameter integer CLK_HZ             = 50_000_000,
    parameter integer DEBOUNCE_MS        = 10,
    parameter integer ROBOT_BAUD         = 115_200
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                          s_axi_aclk,
    input  wire                          s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [31:0]                   s_axi_wdata,
    input  wire [3:0]                    s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output reg                           s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output reg  [31:0]                   s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready,

    input  wire [3:0]                    btn,
    input  wire [3:0]                    sw,
    output wire [3:0]                    led,
    output wire                          robot_tx,
    input  wire                          robot_rx
);
    wire clk = s_axi_aclk;

    reg  [31:0] ctrl;
    wire        core_rst = !s_axi_aresetn || ctrl[0];

    // ---------------------------------------------------------------- write
    reg                          aw_got, w_got;
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr;
    reg [31:0]                   w_data;
    reg                          rx_valid;
    reg [7:0]                    rx_byte;

    assign s_axi_awready = !aw_got && !s_axi_bvalid;
    assign s_axi_wready  = !w_got && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        if (!s_axi_aresetn) begin
            aw_got <= 1'b0; w_got <= 1'b0; s_axi_bvalid <= 1'b0;
            ctrl <= 32'd0; rx_byte <= 8'd0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin aw_addr <= s_axi_awaddr; aw_got <= 1'b1; end
            if (s_axi_wvalid && s_axi_wready)   begin w_data  <= s_axi_wdata;  w_got  <= 1'b1; end
            if (aw_got && w_got) begin
                aw_got <= 1'b0; w_got <= 1'b0; s_axi_bvalid <= 1'b1;
                case (aw_addr[5:2])
                    4'h2: begin rx_valid <= 1'b1; rx_byte <= w_data[7:0]; end
                    4'h5: ctrl <= w_data;
                    default: ;
                endcase
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ----------------------------------------------------------------- core
    wire [7:0]  tx_byte;
    wire        tx_empty;
    wire [10:0] tx_count;
    wire [15:0] rx_ok, rx_err;
    wire [7:0]  inputs_level;
    wire        tx_rd;

    arc_ref_top #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .FIFO_AW(10),
                  .ROBOT_BAUD(ROBOT_BAUD)) u_top (
        .clk(clk), .rst(core_rst),
        .rx_valid(rx_valid), .rx_byte(rx_byte),
        .tx_rd(tx_rd), .tx_byte(tx_byte), .tx_empty(tx_empty), .tx_count(tx_count),
        .rx_ok(rx_ok), .rx_err(rx_err),
        .btn(btn), .sw(sw), .led(led), .inputs_level(inputs_level),
        .robot_tx(robot_tx), .robot_rx(robot_rx)
    );

    // ----------------------------------------------------------------- read
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;
    assign tx_rd = s_axi_arvalid && s_axi_arready && (s_axi_araddr[5:2] == 4'h3) && !tx_empty;

    always @(posedge clk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= 32'h41524346;
                    4'h1: s_axi_rdata <= 32'h00010000;
                    4'h3: s_axi_rdata <= {23'd0, !tx_empty, tx_byte};
                    4'h4: s_axi_rdata <= {15'd0, tx_empty, 5'd0, tx_count};
                    4'h5: s_axi_rdata <= ctrl;
                    4'h6: s_axi_rdata <= {rx_err, rx_ok};
                    4'h7: s_axi_rdata <= {24'd0, inputs_level};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
