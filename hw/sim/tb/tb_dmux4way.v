`timescale 1ns / 1ps

// Reads {in, sel} vectors from dmux4way_vectors.hex and prints "a b c d" for each
module tb_dmux4way;

  reg [7:0] vectors [0:7];
  reg in;
  reg [1:0] sel;
  wire a, b, c, d;
  integer i, n;

  hack_dmux4way dut (.in(in), .sel(sel), .a(a), .b(b), .c(c), .d(d));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("dmux4way_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {in, sel} = {vectors[i][4], vectors[i][1:0]};
      #1 $display("%0d %0d %0d %0d", a, b, c, d);
    end
    $finish;
  end

endmodule
