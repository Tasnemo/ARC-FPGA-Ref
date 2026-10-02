`timescale 1ns / 1ps
// Parses referee-format frames arriving from the browser:
//   SOF(0xA5) | len(2, LE) | seq | CRC8 | cmd_id(2, LE) | data[len] | CRC16(2, LE)
// A frame that passes both CRCs produces a one-cycle cmd_valid pulse.
// Frames longer than MAXLEN are counted as errors and dropped.
module arc_rx_parser #(
    parameter integer MAXLEN = 16
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire [7:0]          in_byte,
    output reg                 cmd_valid,
    output reg  [15:0]         cmd_id,
    output reg  [7:0]          cmd_len,
    output reg  [8*MAXLEN-1:0] cmd_data,
    output reg  [15:0]         ok_count,
    output reg  [15:0]         err_count
);
    `include "arc_crc.vh"

    localparam [3:0] S_SOF  = 4'd0,
                     S_LEN0 = 4'd1,
                     S_LEN1 = 4'd2,
                     S_SEQ  = 4'd3,
                     S_CRC8 = 4'd4,
                     S_CMD0 = 4'd5,
                     S_CMD1 = 4'd6,
                     S_DATA = 4'd7,
                     S_CRCL = 4'd8,
                     S_CRCH = 4'd9;

    reg [3:0]          state;
    reg [15:0]         len;
    reg [7:0]          crc8;
    reg [15:0]         crc16;
    reg [7:0]          idx;
    reg [15:0]         id;
    reg [8*MAXLEN-1:0] data;

    wire [7:0]  crc8_next  = crc8_byte(crc8, in_byte);
    wire [15:0] crc16_next = crc16_byte(crc16, in_byte);

    always @(posedge clk) begin
        cmd_valid <= 1'b0;
        if (rst) begin
            state     <= S_SOF;
            ok_count  <= 16'd0;
            err_count <= 16'd0;
            cmd_id    <= 16'd0;
            cmd_len   <= 8'd0;
            cmd_data  <= {8*MAXLEN{1'b0}};
        end else if (in_valid) begin
            case (state)
                S_SOF: if (in_byte == 8'hA5) begin
                    crc8  <= crc8_byte(8'hFF, in_byte);
                    crc16 <= crc16_byte(16'hFFFF, in_byte);
                    state <= S_LEN0;
                end
                S_LEN0: begin
                    len[7:0] <= in_byte;
                    crc8 <= crc8_next; crc16 <= crc16_next;
                    state <= S_LEN1;
                end
                S_LEN1: begin
                    len[15:8] <= in_byte;
                    crc8 <= crc8_next; crc16 <= crc16_next;
                    state <= S_SEQ;
                end
                S_SEQ: begin
                    crc8 <= crc8_next; crc16 <= crc16_next;
                    state <= S_CRC8;
                end
                S_CRC8: begin
                    if (in_byte != crc8 || len > MAXLEN) begin
                        err_count <= err_count + 16'd1;
                        state <= S_SOF;
                    end else begin
                        crc16 <= crc16_next;
                        state <= S_CMD0;
                    end
                end
                S_CMD0: begin
                    id[7:0] <= in_byte;
                    crc16 <= crc16_next;
                    state <= S_CMD1;
                end
                S_CMD1: begin
                    id[15:8] <= in_byte;
                    crc16 <= crc16_next;
                    idx   <= 8'd0;
                    data  <= {8*MAXLEN{1'b0}};
                    state <= (len == 16'd0) ? S_CRCL : S_DATA;
                end
                S_DATA: begin
                    data[8*idx +: 8] <= in_byte;
                    crc16 <= crc16_next;
                    idx   <= idx + 8'd1;
                    if (idx + 8'd1 == len[7:0]) state <= S_CRCL;
                end
                S_CRCL: begin
                    if (in_byte != crc16[7:0]) begin
                        err_count <= err_count + 16'd1;
                        state <= S_SOF;
                    end else begin
                        state <= S_CRCH;
                    end
                end
                S_CRCH: begin
                    if (in_byte != crc16[15:8]) begin
                        err_count <= err_count + 16'd1;
                    end else begin
                        ok_count  <= ok_count + 16'd1;
                        cmd_valid <= 1'b1;
                        cmd_id    <= id;
                        cmd_len   <= len[7:0];
                        cmd_data  <= data;
                    end
                    state <= S_SOF;
                end
                default: state <= S_SOF;
            endcase
        end
    end
endmodule
