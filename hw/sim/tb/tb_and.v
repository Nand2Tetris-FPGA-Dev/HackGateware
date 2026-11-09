`timescale 1ns / 1ps

// Reads {a, b} vectors from and_vectors.hex and prints "out" for each
module tb_and;

  reg [7:0] vectors [0:3];
  reg a, b;
  wire out;
  integer i, n;

  hack_and dut (.a(a), .b(b), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("and_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b} = {vectors[i][4], vectors[i][0]};
      #1 $display("%0d", out);
    end
    $finish;
  end

endmodule
