// CRC-32 step as in zlib.crc32: reflected, poly 0xEDB88320. Start from all
// ones and invert at the end. Check value 0xCBF43926 over "123456789"
// (RevEng CRC catalog, CRC-32/ISO-HDLC).
function [31:0] crc32_byte(input [31:0] c, input [7:0] d);
    integer i;
    begin
        crc32_byte = c;
        for (i = 0; i < 8; i = i + 1)
            crc32_byte = (crc32_byte[0] ^ d[i]) ? (crc32_byte >> 1) ^ 32'hEDB88320
                                                : crc32_byte >> 1;
    end
endfunction
