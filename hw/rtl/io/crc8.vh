// CRC-8/SMBUS step: poly 0x07, init 0, MSB first, no final xor.
// Check value 0xF4 over "123456789" (RevEng CRC catalog, CRC-8/SMBUS).
// Running it over a message and then its own crc leaves 0.
function [7:0] crc8_byte(input [7:0] crc, input [7:0] data);
    integer i;
    begin
        crc8_byte = crc ^ data;
        for (i = 0; i < 8; i = i + 1)
            crc8_byte = crc8_byte[7] ? {crc8_byte[6:0], 1'b0} ^ 8'h07 : {crc8_byte[6:0], 1'b0};
    end
endfunction
