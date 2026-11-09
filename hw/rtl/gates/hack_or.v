module hack_or(
  input a, b,
  output out
);

  // Basic implementation is equivalent to nand optimized implementation
  wire not_a;
  wire not_b;

  hack_not not1 (.in(a), .out(not_a));
  hack_not not2 (.in(b), .out(not_b));
  hack_nand nand1 (.a(not_a), .b(not_b), .out(out));

endmodule
