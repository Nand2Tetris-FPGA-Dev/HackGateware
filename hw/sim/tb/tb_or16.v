`timescale 1ns / 1ps

// Reads {a, b} vectors from or16_vectors.hex and prints "out" for each
module tb_or16;

  reg [31:0] vectors [0:65535];
  reg [15:0] a, b;
  wire [15:0] out;
  integer i, n;

  hack_or16 dut (.a(a), .b(b), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("or16_vectors.hex", vectors, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      {a, b} = vectors[i];
      #1 $display("%16b", out);
    end
    $finish;
  end

endmodule
