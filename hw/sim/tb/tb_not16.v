`timescale 1ns / 1ps

// Reads {a, b} inputs from not16_inputs.hex and prints "out" for each
module tb_not16;

  reg [15:0] inputs [0:65535];
  reg [15:0] in;
  wire [15:0] out;
  integer i, n;

  hack_not16 dut (.in(in), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("not16_inputs.hex", inputs, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      in = inputs[i];
      #1 $display("%16b", out);
    end
    $finish;
  end

endmodule
