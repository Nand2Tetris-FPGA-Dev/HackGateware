`default_nettype none

// Receives COBS(type, payload..., crc8) 0x00 frames from uart_rx and decodes
// them into a buffer as the bytes arrive. The crc runs over the decoded bytes,
// crc included, so a good frame ends with crc == 0.
// The zero that ends a COBS block is written when the next code byte comes in,
// so the first byte of a frame writes nothing and the buffer from the last
// frame is still readable until the second byte.
// 0xFF codes get no special case: such a block is 254 bytes, past MAX_LEN.
module frame_rx #(
    parameter MAX_LEN = 64            // decoded bytes, crc included, <= 64
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       in_valid,
    input  wire [7:0] in_byte,
    input  wire       in_err,         // uart framing error: spoils the frame
    output reg        frame_ok = 0,
    output reg  [6:0] frame_len = 0,  // type + payload, valid with frame_ok
    output reg        frame_bad = 0,
    input  wire [5:0] rd_addr,        // 0 = type
    output wire [7:0] rd_data
);

`include "crc8.vh"

    reg [7:0] buffer [0:MAX_LEN-1];
    assign rd_data = buffer[rd_addr];

    reg [6:0] count = 0;        // decoded bytes so far
    reg [7:0] left = 0;         // data bytes left in this COBS block
    reg       started = 0;      // got a code byte since the last 0x00
    reg       spoiled = 0;      // uart error or overflow
    reg [7:0] crc = 0;

    wire is_code = left == 0;
    wire [7:0] value = is_code ? 8'h00 : in_byte;
    wire decoded = in_valid && in_byte != 0 && (started || !is_code);
    wire full = count == MAX_LEN;

    always @(posedge clk)
        if (!rst && !in_err && decoded && !full)
            buffer[count[5:0]] <= value;

    always @(posedge clk) begin
        frame_ok <= 0;
        frame_bad <= 0;
        if (rst) begin
            started <= 0;
            spoiled <= 0;
            left <= 0;
            count <= 0;
            crc <= 0;
        end else if (in_err) begin
            spoiled <= 1;
        end else if (in_valid && in_byte == 0) begin
            if (started || spoiled) begin
                if (spoiled || left != 0 || count < 2 || crc != 0) begin
                    frame_bad <= 1;
                end else begin
                    frame_ok <= 1;
                    frame_len <= count - 1'b1;
                end
            end
            started <= 0;
            spoiled <= 0;
            left <= 0;
            count <= 0;
            crc <= 0;
        end else if (in_valid) begin
            started <= 1;
            left <= is_code ? in_byte - 1'b1 : left - 1'b1;
            if (decoded) begin
                crc <= crc8_byte(crc, value);
                if (full)
                    spoiled <= 1;
                else
                    count <= count + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
