// 8K x 16 screen memory. Port A is the CPU's (read/write on clk), port B is
// read only for video on vclk.
module screen_mem (
    input  wire        clk,
    input  wire        we,
    input  wire [12:0] addr,
    input  wire [15:0] din,
    output reg  [15:0] dout,
    input  wire        vclk,
    input  wire [12:0] vaddr,
    output reg  [15:0] vdata
);

    reg [15:0] mem [0:8191];

    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 16'd0;
        dout = 16'd0;
        vdata = 16'd0;
    end

    // Write-first: Gowin's dual port BSRAM can't return the old word on a write
    always @(posedge clk) begin
        if (we) begin
            mem[addr] <= din;
            dout <= din;
        end else begin
            dout <= mem[addr];
        end
    end

    always @(posedge vclk)
        vdata <= mem[vaddr];

endmodule
