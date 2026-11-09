module hack_dmux(
  input in, sel,
  output a, b
);

  // Basic implementation is equivalent to nand optimized implementation
  wire not_sel;

  hack_not not1 (.in(sel), .out(not_sel));

  hack_and and1 (.a(in), .b(not_sel), .out(a));
  hack_and and2 (.a(in), .b(sel), .out(b));

endmodule
