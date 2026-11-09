module hack_not(
  input in,
  output out
);

  // Basic implementation is equivalent to nand optimized implementation
  hack_nand nand1 (.a(in), .b(in), .out(out));

endmodule
