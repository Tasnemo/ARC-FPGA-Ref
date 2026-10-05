`timescale 1ns / 1ps
// Standalone build over its UART pins only, as the browser sees it through a
// USB-UART Pmod: sends TIME, CONFIG (1v1, 10 s battle), skip-to-init, then a
// hit on red once the battle runs; then flips SW3 and checks the link moves
// to the other pin. Dumps the PC link to out/sa_pc.hex and the robot link to
// out/sa_robot.hex for tools/check_standalone.py.
module tb_standalone;
    `include "arc_crc.vh"

    localparam integer CLK_HZ = 60_000;
    localparam integer SEC    = CLK_HZ;
    localparam integer BAUD   = CLK_HZ / 3;
    localparam integer BIT    = 3;          // clock cycles per bit

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [3:0] btn = 0, sw = 0;
    wire [3:0] led;
    wire pc_a, pc_b, robot_tx;
    reg  host_tx = 1'b1;                // host -> board
    reg  swapped = 1'b0;
    // The adapter drives the pin the board reads; the other pin the board drives.
    assign pc_b = swapped ? 1'bz : host_tx;
    assign pc_a = swapped ? host_tx : 1'bz;
    wire board_txd = swapped ? pc_b : pc_a;

    arc_ref_standalone #(.USE_MMCM(0), .CLK_HZ(CLK_HZ), .PC_BAUD(BAUD),
                         .ROBOT_BAUD(BAUD), .DEBOUNCE_MS(1)) dut (
        .sysclk(clk), .btn(btn), .sw(sw), .led(led),
        .pc_a(pc_a), .pc_b(pc_b), .robot_tx(robot_tx), .robot_rx(1'b1)
    );

    // Host-side receivers for both links
    reg  tap_rst = 1'b1;
    initial #100 tap_rst = 1'b0;
    wire pv, rv;
    wire [7:0] pb, rb;
    arc_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) host_rx (
        .clk(clk), .rst(tap_rst), .rxd(board_txd === 1'bz ? 1'b1 : board_txd), .valid(pv), .data(pb));
    arc_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) robot_rx (
        .clk(clk), .rst(tap_rst), .rxd(robot_tx), .valid(rv), .data(rb));
    integer fpc, frb, after_swap = 0;
    always @(posedge clk) begin
        if (pv) begin $fwrite(fpc, "%02x\n", pb); if (swapped) after_swap = after_swap + 1; end
        if (rv) $fwrite(frb, "%02x\n", rb);
    end

    task send_byte;
        input [7:0] b;
        integer i;
        begin
            host_tx = 1'b0; repeat (BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin host_tx = b[i]; repeat (BIT) @(posedge clk); end
            host_tx = 1'b1; repeat (BIT * 2) @(posedge clk);
        end
    endtask

    reg [7:0] fb [0:63];
    reg [7:0] seq = 0;
    task send_frame;
        input [15:0]  cmd;
        input [7:0]   len;
        input [191:0] data;
        integer i;
        reg [7:0]  c8;
        reg [15:0] c16;
        begin
            fb[0] = 8'hA5; fb[1] = len; fb[2] = 8'h00; fb[3] = seq;
            c8 = 8'hFF;
            for (i = 0; i < 4; i = i + 1) c8 = crc8_byte(c8, fb[i]);
            fb[4] = c8; fb[5] = cmd[7:0]; fb[6] = cmd[15:8];
            for (i = 0; i < len; i = i + 1) fb[7 + i] = data[8*i +: 8];
            c16 = 16'hFFFF;
            for (i = 0; i < 7 + len; i = i + 1) c16 = crc16_byte(c16, fb[i]);
            fb[7 + len] = c16[7:0]; fb[8 + len] = c16[15:8];
            for (i = 0; i < 9 + len; i = i + 1) send_byte(fb[i]);
            seq = seq + 1;
        end
    endtask

    initial begin
        fpc = $fopen("out/sa_pc.hex", "w");
        frb = $fopen("out/sa_robot.hex", "w");
        repeat (400) @(posedge clk);                       // power-on reset
        send_frame(16'hF008, 8'd4, 192'd1700000000);
        send_frame(16'hF002, 8'd6, {16'd3, 16'd10, 8'd1, 8'd5});   // 1v1, link red, 10 s
        send_frame(16'hF001, 8'd1, 192'd2);                         // skip to init
        repeat (SEC * 21) @(posedge clk);                           // 15 + 5 s
        send_frame(16'hF003, 8'd3, {8'd0, 8'd1, 8'd1});             // red armor 1
        repeat (SEC) @(posedge clk);
        // Flip SW3: the board now transmits on JE3 and listens on JE2.
        sw[3] = 1'b1;
        repeat (SEC / 10) @(posedge clk);
        swapped = 1'b1;
        send_frame(16'hF003, 8'd3, {8'd0, 8'd2, 8'd4});             // blue armor 2
        repeat (SEC) @(posedge clk);
        $display("bytes after swap: %0d", after_swap);
        $fclose(fpc);
        $fclose(frb);
        $finish;
    end
endmodule
