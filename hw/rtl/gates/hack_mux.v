module hack_mux(
  input a, b, sel,
  output out
);

  /* Basic implementation
  wire not_sel;
  wire a_not_sel, b_sel;

  hack_not not1 (.in(sel), .out(not_sel));

  hack_and and1 (.a(a), .b(not_sel) .out(a_not_sel));
  hack_and and2 (.a(b), .b(sel) .out(b_sel));

  hack_or or1 (.a(a_not_sel), .b(b_sel), .out(out));
  */

  // Nand optimized implementation
  wire not_sel;
  wire not_a_or_sel, nand_b_sel;

  hack_not not1 (.in(sel), .out(not_sel));
  hack_nand nand2 (.a(a), .b(not_sel), .out(not_a_or_sel));
  hack_nand nand3 (.a(b), .b(sel), .out(nand_b_sel));
  hack_nand nand4 (.a(not_a_or_sel), .b(nand_b_sel), .out(out));

endmodule
