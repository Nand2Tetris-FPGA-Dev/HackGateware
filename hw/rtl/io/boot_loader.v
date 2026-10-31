// Copies a program image from SPI flash to the program memory load port.
// Image format (hacktools/image.py): 32-byte header, then words high byte first.
//   0-3 "HACK", 4 version (1), 6-7 word count (1-32768), 8-11 CRC-32 of the data,
//   12-27 name (byte 12 ends up in name[127:120])
// A bad header sets err_header before anything is written. Each load writes two
// words: load_data = {word 2k+1, word 2k} at load_addr = 2k; strobe 0011 for the
// last word of an odd count. done is set only if the CRC matches, else err_crc.
// done and the error flags hold until rst_n.
module boot_loader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [23:0] slot_base,
    output reg         rd_start,
    output reg  [23:0] rd_addr,
    output reg         rd_stop,
    input  wire        rd_valid,
    input  wire [7:0]  rd_byte,
    output wire        rd_ready,
    output reg         load_valid,
    input  wire        load_ready,
    output reg  [14:0] load_addr,
    output reg  [31:0] load_data,
    output reg  [3:0]  load_strb,
    output reg         busy,
    output reg         done,
    output reg         err_header,
    output reg         err_crc,
    output reg  [15:0] word_count,
    output reg  [127:0] name
);

    localparam IDLE = 3'd0, HEADER = 3'd1, CHECK = 3'd2, DATA = 3'd3, LAST = 3'd4, HALT = 3'd5;

    reg [2:0] state = IDLE;
    reg [4:0] hdr_idx = 0;
    reg magic_ok = 0;
    reg [7:0] version = 0;
    reg [15:0] count = 0;
    reg [31:0] crc_expect = 0;
    reg [31:0] crc = 0;
    reg [16:0] bytes_left = 0;
    reg [1:0] lane = 0;

    initial begin
        rd_start = 0;
        rd_addr = 0;
        rd_stop = 0;
        load_valid = 0;
        load_addr = 0;
        load_data = 0;
        load_strb = 0;
        busy = 0;
        done = 0;
        err_header = 0;
        err_crc = 0;
        word_count = 0;
        name = 0;
    end

`include "crc32.vh"

    function [7:0] magic_byte(input [1:0] i);
        magic_byte = i == 0 ? "H" : i == 1 ? "A" : i == 2 ? "C" : "K";
    endfunction

    assign rd_ready = state == HEADER || (state == DATA && !load_valid);
    wire take = rd_valid && rd_ready;

    always @(posedge clk) begin
        rd_start <= 1'b0;
        rd_stop <= 1'b0;

        if (!rst_n) begin
            rd_stop <= 1'b1;  // don't rely on the reader sharing this reset
            state <= IDLE;
            load_valid <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            err_header <= 1'b0;
            err_crc <= 1'b0;
            word_count <= 0;
        end else case (state)
            IDLE:
                if (start) begin
                    rd_start <= 1'b1;
                    rd_addr <= slot_base;
                    busy <= 1'b1;
                    hdr_idx <= 0;
                    magic_ok <= 1'b1;
                    crc <= 32'hFFFFFFFF;
                    load_addr <= 0;
                    lane <= 0;
                    state <= HEADER;
                end

            HEADER:
                if (take) begin
                    hdr_idx <= hdr_idx + 1'b1;
                    if (hdr_idx < 4 && rd_byte != magic_byte(hdr_idx[1:0])) magic_ok <= 1'b0;
                    if (hdr_idx == 4) version <= rd_byte;
                    if (hdr_idx == 6) count[15:8] <= rd_byte;
                    if (hdr_idx == 7) count[7:0] <= rd_byte;
                    if (hdr_idx >= 8 && hdr_idx < 12) crc_expect <= {crc_expect[23:0], rd_byte};
                    if (hdr_idx >= 12 && hdr_idx < 28) name <= {name[119:0], rd_byte};
                    if (hdr_idx == 31) state <= CHECK;
                end

            CHECK:
                if (magic_ok && version == 8'd1 && count != 0 && count <= 16'd32768) begin
                    word_count <= count;
                    bytes_left <= {count, 1'b0};
                    state <= DATA;
                end else begin
                    rd_stop <= 1'b1;
                    err_header <= 1'b1;
                    busy <= 1'b0;
                    state <= HALT;
                end

            DATA: begin
                if (load_valid && load_ready) begin
                    load_valid <= 1'b0;
                    load_addr <= load_addr + 2'd2;
                end
                if (take) begin
                    crc <= crc32_byte(crc, rd_byte);
                    bytes_left <= bytes_left - 1'b1;
                    lane <= lane + 1'b1;
                    case (lane)
                        2'd0: load_data <= {16'h0000, rd_byte, 8'h00};
                        2'd1: load_data[7:0] <= rd_byte;
                        2'd2: load_data[31:24] <= rd_byte;
                        2'd3: load_data[23:16] <= rd_byte;
                    endcase
                    if (lane == 2'd3 || bytes_left == 1) begin
                        load_valid <= 1'b1;
                        load_strb <= lane == 2'd3 ? 4'b1111 : 4'b0011;
                    end
                    if (bytes_left == 1) begin
                        rd_stop <= 1'b1;
                        state <= LAST;
                    end
                end
            end

            LAST:
                if (load_ready) begin
                    load_valid <= 1'b0;
                    busy <= 1'b0;
                    if (~crc == crc_expect) done <= 1'b1;
                    else err_crc <= 1'b1;
                    state <= HALT;
                end

            default: ;
        endcase
    end

endmodule
