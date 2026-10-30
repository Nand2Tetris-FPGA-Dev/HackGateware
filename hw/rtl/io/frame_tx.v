`default_nettype none

// Sends COBS(type, payload..., crc8) 0x00 to uart_tx. The message is read
// through src_addr; byte index len is the crc. A pass over the source works out
// the crc, then each COBS block is scanned for its next zero to get the code
// byte before its data goes out. Messages are under 254 bytes, so no block
// needs a 0xFF code.
module frame_tx (
    input  wire       clk,
    input  wire       rst,
    input  wire       start,          // taken when busy is low
    input  wire [6:0] len,            // type + payload bytes, at most 63
    output wire       busy,
    output wire [5:0] src_addr,
    input  wire [7:0] src_data,       // combinational on src_addr
    output reg        out_valid = 0,
    output reg  [7:0] out_byte = 0,
    input  wire       out_ready
);

`include "crc8.vh"

    localparam IDLE = 3'd0, CRC = 3'd1, SCAN = 3'd2, CODE = 3'd3, DATA = 3'd4, DELIM = 3'd5;

    reg [2:0] state = IDLE;
    reg [6:0] last = 0;         // index of the crc byte
    reg [6:0] idx = 0;
    reg [6:0] pos = 0;          // first byte of the current block
    reg [6:0] blk_end = 0;      // index of the zero ending it, or last + 1
    reg [7:0] crc = 0;

    assign busy = state != IDLE;
    assign src_addr = idx[5:0];
    wire [7:0] cur = idx == last ? crc : src_data;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            out_valid <= 0;
        end else case (state)
            IDLE:
                if (start) begin
                    last <= len;
                    idx <= 0;
                    crc <= 0;
                    state <= CRC;
                end
            CRC:
                if (idx == last) begin
                    idx <= 0;
                    pos <= 0;
                    state <= SCAN;
                end else begin
                    crc <= crc8_byte(crc, src_data);
                    idx <= idx + 1'b1;
                end
            SCAN:
                if (idx > last || cur == 0) begin
                    out_byte <= {1'b0, idx - pos} + 1'b1;
                    out_valid <= 1;
                    blk_end <= idx;
                    idx <= pos;
                    state <= CODE;
                end else begin
                    idx <= idx + 1'b1;
                end
            CODE:
                if (out_ready) begin
                    out_valid <= 0;
                    state <= DATA;
                end
            DATA:
                if (out_valid) begin
                    if (out_ready) begin
                        out_valid <= 0;
                        idx <= idx + 1'b1;
                    end
                end else if (idx != blk_end) begin
                    out_byte <= cur;
                    out_valid <= 1;
                end else if (blk_end > last) begin
                    out_byte <= 8'h00;
                    out_valid <= 1;
                    state <= DELIM;
                end else begin
                    idx <= blk_end + 1'b1;
                    pos <= blk_end + 1'b1;
                    state <= SCAN;
                end
            default:  // DELIM
                if (out_ready) begin
                    out_valid <= 0;
                    state <= IDLE;
                end
        endcase
    end

endmodule

`default_nettype wire
