`timescale 1ns / 1ps
// Byte FIFO with first-word-fall-through output (dout is the head while
// !empty). Small enough that Vivado maps it to LUTRAM.
module arc_byte_fifo #(
    parameter integer AW = 10   // depth = 2**AW
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr,
    input  wire [7:0]  din,
    input  wire        rd,
    output wire [7:0]  dout,
    output wire        empty,
    output wire        full,
    output reg  [AW:0] count
);
    reg [7:0]    mem [0:(1<<AW)-1];
    reg [AW-1:0] wp, rp;

    assign dout  = mem[rp];
    assign empty = (count == 0);
    assign full  = (count == (1 << AW));

    wire do_wr = wr && !full;
    wire do_rd = rd && !empty;

    always @(posedge clk) begin
        if (rst) begin
            wp <= 0; rp <= 0; count <= 0;
        end else begin
            if (do_wr) begin
                mem[wp] <= din;
                wp <= wp + 1'b1;
            end
            if (do_rd) rp <= rp + 1'b1;
            count <= count + (do_wr ? 1'b1 : 1'b0) - (do_rd ? 1'b1 : 1'b0);
        end
    end
endmodule
