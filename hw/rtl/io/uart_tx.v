`default_nettype none

// 8N1 transmitter, LSB first. A byte is taken when valid and ready are both
// high; ready comes back right after the stop bit, so bytes can go out back to
// back.
module uart_tx #(
    parameter CLKS_PER_BIT = 9
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output reg        tx = 1
);

    localparam W = $clog2(CLKS_PER_BIT);

    reg [8:0] shift = 0;       // data bits, then the stop bit
    reg [3:0] bits_left = 0;   // including the bit on the line now
    reg [W-1:0] count = 0;

    assign ready = bits_left == 0;

    always @(posedge clk) begin
        if (rst) begin
            bits_left <= 0;
            tx <= 1;
        end else if (bits_left == 0) begin
            if (valid) begin
                tx <= 0;
                shift <= {1'b1, data};
                bits_left <= 4'd10;
                count <= CLKS_PER_BIT - 1;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            bits_left <= bits_left - 1'b1;
            count <= CLKS_PER_BIT - 1;
            if (bits_left != 4'd1) begin
                tx <= shift[0];
                shift <= shift >> 1;
            end
        end
    end

endmodule

`default_nettype wire
