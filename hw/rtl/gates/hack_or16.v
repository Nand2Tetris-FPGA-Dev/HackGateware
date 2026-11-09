module hack_or16(
  input [15:0] a, b,
  output [15:0] out
);

  // Basic implementation is equivalent to nand optimized implementation
  hack_or or_array [15:0] (.a(a), .b(b), .out(out));

endmodule
