`timescale 1ns / 1ps

// Reads in inputs from not_inputs.hex and prints "out" for each
module tb_not;

  reg [3:0] inputs [0:1];
  reg in;
  wire out;
  integer i, n;

  hack_not dot (.in(in), .out(out));

  initial begin
    if (!$value$plusargs("N=%d", n)) n = 0;
    $readmemh("not_inputs.hex", inputs, 0, n - 1);
    for (i = 0; i < n; i = i + 1) begin
      in = inputs[i];
      #1 $display("%0d", out);
    end
    $finish;
  end

endmodule
