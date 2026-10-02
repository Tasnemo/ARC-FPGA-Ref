// CRC helpers shared by the parser, the frame generator and the testbench.
// Both match the RoboMaster referee serial protocol (also used by ARC):
//   CRC8  : Dallas/Maxim, reflected poly 0x8C (0x31), init 0xFF, no final xor
//   CRC16 : CRC-16/MCRF4XX, reflected poly 0x8408 (0x1021), init 0xFFFF, no final xor
// Bit-serial loops unroll into a small XOR tree per byte.

function [7:0] crc8_byte;
    input [7:0] crc;
    input [7:0] data;
    integer i;
    reg [7:0] c;
    begin
        c = crc ^ data;
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ((c >> 1) ^ 8'h8C) : (c >> 1);
        crc8_byte = c;
    end
endfunction

function [15:0] crc16_byte;
    input [15:0] crc;
    input [7:0]  data;
    integer i;
    reg [15:0] c;
    begin
        c = crc ^ {8'h00, data};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ((c >> 1) ^ 16'h8408) : (c >> 1);
        crc16_byte = c;
    end
endfunction
