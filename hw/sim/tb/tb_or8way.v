`timescale 1ns / 1ps

// Reads "in" vectors from or8way_vectors.hex and prints "out" for each
module tb_or8way;

  reg [7:0] vectors [0:255];
  reg [7:0] in;
  wire out;
  integer i, n;

  hack_or8way dut (.in(in), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("or8way_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      in = vectors[i];
      #1 $display("%0d", out);
    end
    $finish;
  end

endmodule
