`timescale 1ns / 1ps

// Reads {a, b, c, d, sel} vectors from mux4way16_vectors.hex and prints "out" for each
module tb_mux4way16;

  reg [67:0] vectors [0:65535];
  reg [15:0] a, b, c, d;
  reg [1:0] sel;
  wire [15:0] out;
  integer i, n;

  hack_mux4way16 dut (.a(a), .b(b), .c(c), .d(d), .sel(sel), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("mux4way16_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b, c, d, sel} = {vectors[i][67:4], vectors[i][1:0]};
      #1 $display("%16b", out);
    end
    $finish;
  end

endmodule
