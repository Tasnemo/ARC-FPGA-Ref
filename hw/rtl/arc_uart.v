`timescale 1ns / 1ps
// 8N1 UART transmitter and receiver for the fabric (no PS needed).
// Used for the robot link (the referee's "User" serial port) and, in the
// standalone build, the link to the browser through a USB-UART Pmod.

module arc_uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,     // load data when valid && ready
    input  wire [7:0] data,
    output wire       ready,
    output reg        txd        // idle high
);
    localparam integer DIV = CLK_HZ / BAUD;

    reg [31:0] cnt;
    reg [3:0]  bitn;     // 0 idle, 1..10 start, 8 data, stop
    reg [9:0]  shift;

    assign ready = (bitn == 4'd0);

    always @(posedge clk) begin
        if (rst) begin
            txd <= 1'b1; bitn <= 4'd0; cnt <= 0; shift <= 10'h3FF;
        end else if (bitn == 4'd0) begin
            txd <= 1'b1;
            if (valid) begin
                shift <= {1'b1, data, 1'b0};   // stop, data LSB first, start
                bitn  <= 4'd1;
                cnt   <= 0;
                txd   <= 1'b0;
            end
        end else if (cnt == DIV - 1) begin
            cnt <= 0;
            if (bitn == 4'd10) begin
                bitn <= 4'd0;
                txd  <= 1'b1;
            end else begin
                txd   <= shift[bitn];
                bitn  <= bitn + 4'd1;
            end
        end else begin
            cnt <= cnt + 1;
        end
    end
endmodule

module arc_uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg        valid,     // one-cycle pulse per received byte
    output reg  [7:0] data
);
    localparam integer DIV = CLK_HZ / BAUD;

    reg [2:0]  sync;     // synchroniser, idle high
    reg [31:0] cnt;
    reg [3:0]  bitn;     // 0 idle, 1 start, 2..9 data, 10 stop
    reg [7:0]  shift;
    wire       r = sync[2];

    always @(posedge clk) begin
        sync  <= {sync[1:0], rxd};
        valid <= 1'b0;
        if (rst) begin
            sync <= 3'b111; bitn <= 4'd0; cnt <= 0; data <= 8'd0;
        end else if (bitn == 4'd0) begin
            if (!r) begin                     // start edge
                bitn <= 4'd1;
                cnt  <= DIV / 2;              // sample mid-bit
            end
        end else if (cnt == DIV - 1) begin
            cnt <= 0;
            case (bitn)
                4'd1: bitn <= r ? 4'd0 : 4'd2;   // false start
                4'd10: begin
                    if (r) begin valid <= 1'b1; data <= shift; end
                    bitn <= 4'd0;
                end
                default: begin
                    shift <= {r, shift[7:1]};
                    bitn  <= bitn + 4'd1;
                end
            endcase
        end else begin
            cnt <= cnt + 1;
        end
    end
endmodule
