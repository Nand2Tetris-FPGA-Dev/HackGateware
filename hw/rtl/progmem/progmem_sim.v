// Simulation-only program memory. fetch_ready pulses LATENCY cycles after
// fetch_req, with fetch_data valid in that cycle.
module progmem_sim #(
    parameter LATENCY = 1
) (
    input  wire        clk,
    input  wire        fetch_req,
    input  wire [14:0] fetch_addr,
    output reg         fetch_ready,
    output reg  [15:0] fetch_data
);

    reg [15:0] mem [0:32767];
    reg [14:0] addr_q;
    integer wait_count = 0;

    integer i;
    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 16'd0;
        fetch_ready = 0;
        fetch_data = 0;
    end

    always @(posedge clk) begin
        fetch_ready <= 1'b0;
        if (fetch_req) begin
            addr_q <= fetch_addr;
            if (LATENCY <= 1) begin
                fetch_ready <= 1'b1;
                fetch_data <= mem[fetch_addr];
            end else begin
                wait_count <= LATENCY - 1;
            end
        end else if (wait_count != 0) begin
            wait_count <= wait_count - 1;
            if (wait_count == 1) begin
                fetch_ready <= 1'b1;
                fetch_data <= mem[addr_q];
            end
        end
    end

endmodule
