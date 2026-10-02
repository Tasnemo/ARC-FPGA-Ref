`timescale 1ns / 1ps
// End-to-end testbench: drives arc_ref_axi over AXI-Lite exactly like the
// ARM bridge does (write RX_DATA, poll TX_DATA) and dumps every byte sent to
// the browser into out/tx_bytes.hex. tools/check_sim.py then decodes the
// stream and checks it.
module tb_arc_ref;
    `include "arc_crc.vh"

    localparam integer CLK_HZ = 30_000;    // 1 s = 30k cycles
    localparam integer SEC    = CLK_HZ;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rstn = 0;

    reg  [5:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    reg  [3:0]  btn = 0, sw = 0;
    wire [3:0]  led;

    arc_ref_axi #(.CLK_HZ(CLK_HZ), .DEBOUNCE_MS(1)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .btn(btn), .sw(sw), .led(led)
    );

    integer fd;
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    // ------------------------------------------------------------- AXI BFM
    task axi_write;
        input [5:0]  a;
        input [31:0] d;
        reg aw_done, w_done;
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1; wdata = d; wvalid = 1; bready = 1;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (awvalid && awready) aw_done = 1;
                if (wvalid && wready)   w_done = 1;
                @(negedge clk);
                if (aw_done) awvalid = 0;
                if (w_done)  wvalid = 0;
            end
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(negedge clk);
            bready = 0;
        end
    endtask

    task axi_read;
        input  [5:0]  a;
        output [31:0] d;
        begin
            @(negedge clk);
            araddr = a; arvalid = 1; rready = 1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            @(negedge clk);
            arvalid = 0;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(negedge clk);
            rready = 0;
        end
    endtask

    // Pull everything currently in the TX FIFO into the dump file.
    task drain;
        reg [31:0] v;
        begin
            axi_read(6'h0C, v);
            while (v[8]) begin
                $fwrite(fd, "%02x\n", v[7:0]);
                axi_read(6'h0C, v);
            end
        end
    endtask

    task run_for;
        input integer n;
        integer until;
        begin
            until = cycles + n;
            while (cycles < until) drain;
        end
    endtask

    // ------------------------------------------------------- frame builder
    reg [7:0] fb [0:63];
    reg [7:0] seq = 0;

    task send_frame;
        input [15:0] cmd;
        input [7:0]  len;
        input [191:0] data;   // byte 0 in bits [7:0]
        input        corrupt;
        integer i, n;
        reg [7:0]  c8;
        reg [15:0] c16;
        begin
            fb[0] = 8'hA5; fb[1] = len; fb[2] = 8'h00; fb[3] = seq;
            c8 = 8'hFF;
            for (i = 0; i < 4; i = i + 1) c8 = crc8_byte(c8, fb[i]);
            fb[4] = c8;
            fb[5] = cmd[7:0]; fb[6] = cmd[15:8];
            for (i = 0; i < len; i = i + 1) fb[7 + i] = data[8*i +: 8];
            c16 = 16'hFFFF;
            for (i = 0; i < 7 + len; i = i + 1) c16 = crc16_byte(c16, fb[i]);
            fb[7 + len] = c16[7:0];
            fb[8 + len] = c16[15:8] ^ (corrupt ? 8'h01 : 8'h00);
            n = 9 + len;
            for (i = 0; i < n; i = i + 1) begin
                axi_write(6'h08, {24'd0, fb[i]});
                drain;
            end
            seq = seq + 1;
        end
    endtask

    task press_button;
        input integer i;
        begin
            btn[i] = 1;
            run_for(100);
            btn[i] = 0;
            run_for(100);
        end
    endtask

    reg [31:0] v;
    integer s;
    reg [7:0] slot0, slot1, slot2;
    initial begin
        fd = $fopen("out/tx_bytes.hex", "w");
        repeat (20) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        axi_read(6'h00, v);
        if (v !== 32'h41524346) begin
            $display("FAIL: ID register = %08x", v);
            $finish;
        end

        // ============================================================ 1v1
        // Slots: 1 = red Infantry, 4 = blue Infantry.
        // CONFIG: 1v1, link slot 1, 30 s battle, 3 s setup. ROBOT: 1v1 Infantry
        // stats (200 HP, heat 80, cooling 12, 120 W, 25 m/s) with 10 projectiles.
        send_frame(16'hF008, 8'd4, 192'd1700000000, 0);
        send_frame(16'hF002, 8'd6, {16'd3, 16'd30, 8'd1, 8'd5}, 0);
        send_frame(16'hF009, 8'd15, {16'd10, 16'd25, 16'd120, 16'd12, 16'd80, 16'd200, 8'h01, 8'd1}, 0);
        send_frame(16'hF009, 8'd15, {16'd10, 16'd25, 16'd120, 16'd12, 16'd80, 16'd200, 8'h01, 8'd4}, 0);
        send_frame(16'hF001, 8'd1, 192'd1, 0);            // setup period (3 s)
        run_for(SEC / 2);
        send_frame(16'hF001, 8'd1, 192'd3, 0);            // timeout: pause 1 s
        run_for(SEC);
        send_frame(16'hF001, 8'd1, 192'd4, 0);            // resume
        run_for(SEC * 23);                                // 2.5 + 15 + 5 s, into battle

        send_frame(16'hF003, 8'd2, {8'd1, 8'd1}, 0);      // red armor 1: 200 -> 180
        press_button(2);                                  // red armor 2: -> 160
        send_frame(16'hF003, 8'd3, {8'd1, 8'd0, 8'd4}, 0);// blue collision: 200 -> 198
        for (s = 0; s < 9; s = s + 1)                     // 9 red shots, 25.0 m/s
            send_frame(16'hF004, 8'd8, {16'd250, 32'h41C80000, 8'd5, 8'd1}, 0);
        run_for(SEC / 5);                                 // heat 90 > 80: locked
        send_frame(16'hF004, 8'd8, {16'd250, 32'h41C80000, 8'd5, 8'd1}, 0); // refused
        send_frame(16'hF004, 8'd8, {16'd310, 32'h41F80000, 8'd5, 8'd4}, 0); // blue 31 m/s
        send_frame(16'hF004, 8'd8, {16'd250, 32'h41C80000, 8'd5, 8'd4}, 0); // refused
        send_frame(16'hF005, 8'd2, {8'd2, 8'd1}, 0);      // red yellow: -30 -> 130
        send_frame(16'hF005, 8'd2, {8'd2, 8'd1}, 0);      // again <30 s: -60 -> 70
        send_frame(16'hF007, 8'd3, {16'd200, 8'd4}, 0);   // blue 200 W > 120 W
        send_frame(16'hF003, 8'd2, {8'd3, 8'd1}, 1);      // corrupt CRC16, dropped
        run_for(SEC * 31);                                // time-out: blue wins on HP

        // 1v1 round 2: skip setup; three yellows on blue -> red card -> defeat.
        send_frame(16'hF001, 8'd1, 192'd6, 0);
        send_frame(16'hF001, 8'd1, 192'd2, 0);
        run_for(SEC * 20 + SEC / 2);
        for (s = 0; s < 3; s = s + 1)
            send_frame(16'hF005, 8'd2, {8'd2, 8'd4}, 0);
        run_for(SEC);

        // ============================================================ 3v3
        // Slots 0/3 Hero (42 mm, 350 HP, heat 200, cool 24, 100 W, 15 m/s, 0 rounds),
        // 1/4 Infantry HP+Cooldown (350, 88, 24, 75 W, 25 m/s, 0), 2/5 Sentry
        // (400, 260, 30, 100 W, 25 m/s, 750). 65 s battle, link = red Infantry.
        send_frame(16'hF001, 8'd1, 192'd6, 0);
        send_frame(16'hF002, 8'd6, {16'd3, 16'd65, 8'd1, 8'd4}, 0);
        for (s = 0; s < 2; s = s + 1) begin
            slot0 = 3 * s; slot1 = 3 * s + 1; slot2 = 3 * s + 2;
            send_frame(16'hF009, 8'd15, {16'd0,   16'd15, 16'd100, 16'd24, 16'd200, 16'd350, 8'h03, slot0}, 0);
            send_frame(16'hF009, 8'd15, {16'd0,   16'd25, 16'd75,  16'd24, 16'd88,  16'd350, 8'h01, slot1}, 0);
            send_frame(16'hF009, 8'd15, {16'd750, 16'd25, 16'd100, 16'd30, 16'd260, 16'd400, 8'h01, slot2}, 0);
        end
        send_frame(16'hF001, 8'd1, 192'd2, 0);            // straight to init
        run_for(SEC * 20 + SEC / 2);

        send_frame(16'hF00A, 8'd2, {8'd1, 8'd1}, 0);      // red Infantry in resupply zone
        send_frame(16'hF00B, 8'd3, {16'd100, 8'd1}, 0);   // buys 100 x 17 mm: 200 -> 100 coins
        send_frame(16'hF00B, 8'd3, {16'd5, 8'd0}, 0);     // Hero not in zone: refused
        send_frame(16'hF00A, 8'd2, {8'd1, 8'd0}, 0);
        send_frame(16'hF00B, 8'd3, {16'd5, 8'd0}, 0);     // 5 x 42 mm: -> 50 coins
        send_frame(16'hF003, 8'd3, {8'd2, 8'd0, 8'd4}, 0);// 42 mm on blue Infantry: immune
        send_frame(16'hF004, 8'd8, {16'd140, 32'h41600000, 8'd1, 8'd0}, 0); // Hero fires 14 m/s
        send_frame(16'hF003, 8'd3, {8'd2, 8'd1, 8'd4}, 0);// now counts: 350 -> 150
        send_frame(16'hF00A, 8'd2, {8'd2, 8'd5}, 0);      // blue Sentry takes the capture point
        for (s = 0; s < 8; s = s + 1)                     // red Sentry: 400 -> 240
            send_frame(16'hF003, 8'd3, {8'd0, 8'd2, 8'd2}, 0);
        send_frame(16'hF00A, 8'd2, {8'd0, 8'd1}, 0);      // red Infantry leaves the zone
        for (s = 0; s < 18; s = s + 1)                    // red Infantry defeated
            send_frame(16'hF003, 8'd3, {8'd0, 8'd0, 8'd1}, 0);
        run_for(SEC * 5 + SEC / 2);                       // respawns: 70 HP, weak, invincible
        send_frame(16'hF004, 8'd8, {16'd200, 32'h41A00000, 8'd5, 8'd1}, 0); // refused (weak)
        send_frame(16'hF003, 8'd3, {8'd0, 8'd0, 8'd1}, 0);// ignored (invincible)
        send_frame(16'hF00A, 8'd2, {8'd1, 8'd1}, 0);      // back to resupply: heals 25 %/s
        run_for(SEC * 2 + SEC / 5);
        send_frame(16'hF005, 8'd2, {8'd2, 8'd2}, 0);      // red Sentry yellow
        run_for(SEC * 60);                                // time-out: blue wins on VP

        // 3v3 round 2: red forfeits.
        send_frame(16'hF001, 8'd1, 192'd6, 0);
        send_frame(16'hF001, 8'd1, 192'd2, 0);
        run_for(SEC * 20 + SEC / 2);
        send_frame(16'hF005, 8'd2, {8'd4, 8'd1}, 0);
        run_for(SEC / 2);

        axi_read(6'h18, v);
        $display("rx ok=%0d err=%0d", v[15:0], v[31:16]);
        $fclose(fd);
        $display("DONE");
        $finish;
    end
endmodule
