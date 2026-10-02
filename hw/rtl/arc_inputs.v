`timescale 1ns / 1ps
// Synchronises and debounces the Zybo buttons and switches.
// btn_press is a one-cycle pulse on each debounced press.
module arc_inputs #(
    parameter integer CLK_HZ      = 100_000_000,
    parameter integer DEBOUNCE_MS = 10
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [3:0] btn_raw,
    input  wire [3:0] sw_raw,
    output reg  [3:0] btn_press,
    output reg  [3:0] btn_level,
    output reg  [3:0] sw_level
);
    localparam integer N = (CLK_HZ / 1000) * DEBOUNCE_MS;

    reg [7:0]  s1, s2;          // 2-FF synchroniser {sw, btn}
    reg [7:0]  stable;
    reg [31:0] cnt [0:7];
    integer i;

    always @(posedge clk) begin
        s1 <= {sw_raw, btn_raw};
        s2 <= s1;
        btn_press <= 4'd0;
        if (rst) begin
            stable <= 8'd0;
            btn_level <= 4'd0;
            sw_level <= 4'd0;
            for (i = 0; i < 8; i = i + 1) cnt[i] <= 0;
        end else begin
            for (i = 0; i < 8; i = i + 1) begin
                if (s2[i] == stable[i]) begin
                    cnt[i] <= 0;
                end else if (cnt[i] == N - 1) begin
                    cnt[i] <= 0;
                    stable[i] <= s2[i];
                    if (i < 4 && s2[i]) btn_press[i % 4] <= 1'b1;
                end else begin
                    cnt[i] <= cnt[i] + 1;
                end
            end
            btn_level <= stable[3:0];
            sw_level  <= stable[7:4];
        end
    end
endmodule
