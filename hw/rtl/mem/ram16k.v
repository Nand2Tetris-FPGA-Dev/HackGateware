// 16K x 16 RAM. Reads are registered so it maps to block RAM: dout shows the
// word at addr from the previous clock edge.
module ram16k (
    input  wire        clk,
    input  wire        we,
    input  wire [13:0] addr,
    input  wire [15:0] din,
    output reg  [15:0] dout
);

    reg [15:0] mem [0:16383];

    integer i;
    initial begin
        for (i = 0; i < 16384; i = i + 1) mem[i] = 16'd0;
        dout = 16'd0;
    end

    always @(posedge clk) begin
        if (we) mem[addr] <= din;
        dout <= mem[addr];
    end

endmodule
