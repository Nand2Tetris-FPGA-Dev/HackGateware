`timescale 1ns / 1ps

// Reads {in, sel} vectors from dmux8way_vectors.hex and prints "a b c d e f g h" for each
module tb_dmux8way;

  reg [7:0] vectors [0:15];
  reg in;
  reg [2:0] sel;
  wire a, b, c, d, e, f, g, h;
  integer i, n;

  hack_dmux8way dut (.in(in), .sel(sel), .a(a), .b(b), .c(c), .d(d), .e(e), .f(f), .g(g), .h(h));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("dmux8way_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {in, sel} = {vectors[i][4], vectors[i][2:0]};
      #1 $display("%0d %0d %0d %0d %0d %0d %0d %0d", a, b, c, d, e, f, g, h);
    end
    $finish;
  end

endmodule
