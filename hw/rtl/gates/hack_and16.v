module hack_and16(
  input [15:0] a, b,
  output [15:0] out
);

  // Basic implementation is equivalent to nand optimized implementation
  hack_and and_array [15:0] (.a(a), .b(b), .out(out));

endmodule
