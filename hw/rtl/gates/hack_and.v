module hack_and(
  input a, b,
  output out
);

  // Basic implementation is equivalent to nand optimized implementation
  wire nand_a_b;

  hack_nand n1 (.a(a), .b(b), .out(nand_a_b));
  hack_not n2 (.in(nand_a_b), .out(out));

endmodule
