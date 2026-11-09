`timescale 1ns / 1ps

// Reads {a, b, sel} vectors from mux16_vectors.hex and prints "out" for each
module tb_mux16;

  reg [35:0] vectors [0:65535];
  reg [15:0] a, b;
  reg sel;
  wire [15:0] out;
  integer i, n;

  hack_mux16 dut (.a(a), .b(b), .sel(sel), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("mux16_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b, sel} = {vectors[i][35:4], vectors[i][0]};
      #1 $display("%16b", out);
    end
    $finish;
  end

endmodule
