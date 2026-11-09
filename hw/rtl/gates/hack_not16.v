module hack_not16(
  input [15:0] in,
  output [15:0] out
);

  // Basic implementation is equivalent to nand optimized implementation
  hack_not not_array [15:0] (.in(in), .out(out));

endmodule
