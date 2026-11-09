`timescale 1ns / 1ps

// Reads {in, sel} vectors from dmux_vectors.hex and prints "a b" for each
module tb_dmux;

  reg [7:0] vectors [0:3];
  reg in, sel;
  wire a, b;
  integer i, n;

  hack_dmux dut (.in(in), .sel(sel), .a(a), .b(b));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("dmux_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {in, sel} = {vectors[i][4], vectors[i][0]};
      #1 $display("%0d %0d", a, b);
    end
    $finish;
  end

endmodule
