`timescale 1ns / 1ps

// Reads {a, b, c, d, e, f, g, h, sel} vectors from mux8way16_vectors.hex and prints "out" for each
module tb_mux8way16;

  reg [131:0] vectors [0:65535];
  reg [15:0] a, b, c, d, e, f, g, h;
  reg [2:0] sel;
  wire [15:0] out;
  integer i, n;

  hack_mux8way16 dut (.a(a), .b(b), .c(c), .d(d), .e(e), .f(f), .g(g), .h(h), .sel(sel), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("mux8way16_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b, c, d, e, f, g, h, sel} = {vectors[i][131:4], vectors[i][2:0]};
      #1 $display("%16b", out);
    end
    $finish;
  end

endmodule
