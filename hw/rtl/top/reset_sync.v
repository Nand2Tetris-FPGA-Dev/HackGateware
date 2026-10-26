// Brings a button into the clk domain with two flip-flops. With DEBOUNCE set,
// the output only changes after the input has been steady for 10 ms.
module reset_sync #(
    parameter DEBOUNCE = 0,
    parameter CLK_HZ = 27000000
) (
    input  wire clk,
    input  wire async_in,
    output reg  sync_out
);

    localparam STEADY = CLK_HZ / 100;

    reg [1:0] sync = 2'b00;
    reg [$clog2(STEADY + 1)-1:0] count = 0;
    initial sync_out = 1'b0;

    always @(posedge clk) begin
        sync <= {sync[0], async_in};

        if (!DEBOUNCE) begin
            sync_out <= sync[1];
        end else if (sync[1] == sync_out) begin
            count <= 0;
        end else if (count == STEADY - 1) begin
            sync_out <= sync[1];
            count <= 0;
        end else begin
            count <= count + 1'b1;
        end
    end

endmodule
