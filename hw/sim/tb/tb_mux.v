`timescale 1ns / 1ps

// Reads {a, b, sel} vectors from mux_vectors.hex and prints "out" for each
module tb_mux;

  reg [11:0] vectors [0:7];
  reg a, b, sel;
  wire out;
  integer i, n;

  hack_mux dut (.a(a), .b(b), .sel(sel), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("mux_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b, sel} = {vectors[i][8], vectors[i][4], vectors[i][0]};
      #1 $display("%0d", out);
    end
    $finish;
  end

endmodule
