`timescale 1ns / 1ps

// Feeds {de, c, d} vectors from tmds_vectors.hex and prints q for each one
module tb_tmds;
    reg clk = 0;
    reg [10:0] vectors [0:65535];
    reg [7:0] d = 0;
    reg [1:0] c = 0;
    reg de = 0;
    wire [9:0] q;
    integer i, n;

    tmds_encoder dut (.clk(clk), .d(d), .c(c), .de(de), .q(q));

    always #20 clk = ~clk;

    initial begin
        if (!$value$plusargs("N=%d", n)) n = 0;
        $readmemh("tmds_vectors.hex", vectors, 0, n - 1);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk);
            {de, c, d} = vectors[i];
            @(posedge clk);
            #1 $display("%03x", q);
        end
        $finish;
    end
endmodule
