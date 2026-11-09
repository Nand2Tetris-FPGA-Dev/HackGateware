module hack_xor(
  input a, b,
  output out
);

  /* Basic implementation
  wire not_a, not_b;
  wire a_not_b, b_not_a;

  hack_not not1 (.in(a), .out(not_a));
  hack_not not2 (.in(b), .out(not_b));

  hack_and and1 (.a(a), .b(not_b) .out(a_not_b));
  hack_and and2 (.a(b), .b(not_a) .out(b_not_a));

  hack_or or1 (.a(a_not_b), .b(b_not_a), .out(out));
  */

  // Nand optimized implementation
  wire nand_a_b, not_a_or_b, not_b_or_a;

  hack_nand nand1 (.a(a), .b(b), .out(nand_a_b));
  hack_nand nand2 (.a(a), .b(nand_a_b), .out(not_a_or_b));
  hack_nand nand3 (.a(nand_a_b), .b(b), .out(not_b_or_a));
  hack_nand nand4 (.a(not_a_or_b), .b(not_b_or_a), .out(out));

endmodule
