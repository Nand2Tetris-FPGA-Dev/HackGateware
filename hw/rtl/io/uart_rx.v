`default_nettype none

// 8N1 receiver, LSB first. rx goes through two flops, then each bit is sampled
// at its middle, counted from the start bit's falling edge.
// A low stop bit gives frame_err instead of a byte, and the receiver then waits
// for rx to stay high for a whole bit, so a break gives exactly one error.
module uart_rx #(
    parameter CLKS_PER_BIT = 9
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data = 0,
    output reg        valid = 0,
    output reg        frame_err = 0
);

    localparam W = $clog2(CLKS_PER_BIT);
    localparam IDLE = 3'd0, START = 3'd1, DATA = 3'd2, STOP = 3'd3, WAIT = 3'd4;

    reg [1:0] sync = 2'b11;
    always @(posedge clk)
        sync <= {sync[0], rx};
    wire line = sync[1];

    reg [2:0] state = IDLE;
    reg [W-1:0] count = 0;
    reg [2:0] bit_idx = 0;
    reg [7:0] shift = 0;

    always @(posedge clk) begin
        valid <= 0;
        frame_err <= 0;
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE:
                    if (!line) begin
                        state <= START;
                        count <= CLKS_PER_BIT / 2 - 1;
                    end
                START:
                    if (count != 0) begin
                        count <= count - 1'b1;
                    end else if (line) begin
                        state <= IDLE;              // glitch, not a start bit
                    end else begin
                        state <= DATA;
                        count <= CLKS_PER_BIT - 1;
                        bit_idx <= 0;
                    end
                DATA:
                    if (count != 0) begin
                        count <= count - 1'b1;
                    end else begin
                        shift <= {line, shift[7:1]};
                        count <= CLKS_PER_BIT - 1;
                        bit_idx <= bit_idx + 1'b1;
                        if (bit_idx == 3'd7)
                            state <= STOP;
                    end
                STOP:
                    if (count != 0) begin
                        count <= count - 1'b1;
                    end else if (line) begin
                        data <= shift;
                        valid <= 1;
                        state <= IDLE;
                    end else begin
                        frame_err <= 1;
                        state <= WAIT;
                        count <= CLKS_PER_BIT - 1;
                    end
                default:  // WAIT
                    if (!line)
                        count <= CLKS_PER_BIT - 1;
                    else if (count != 0)
                        count <= count - 1'b1;
                    else
                        state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
