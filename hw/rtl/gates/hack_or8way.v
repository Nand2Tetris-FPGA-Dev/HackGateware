module hack_or8way(
  input [7:0] in,
  output out
);

  // Basic implementation is equivalent to nand optimized implementation
  wire b1_or_b2, b3_or_b4, b5_or_b6, b7_or_b8;
  wire b1_b2_b3_b4_or, b5_b6_b7_b8_or;

  hack_or or1 (.a(in[0]), .b(in[1]), .out(b1_or_b2));
  hack_or or2 (.a(in[2]), .b(in[3]), .out(b3_or_b4));
  hack_or or3 (.a(in[4]), .b(in[5]), .out(b5_or_b6));
  hack_or or4 (.a(in[6]), .b(in[7]), .out(b7_or_b8));

  hack_or or5 (.a(b1_or_b2), .b(b3_or_b4), .out(b1_b2_b3_b4_or));
  hack_or or6 (.a(b5_or_b6), .b(b7_or_b8), .out(b5_b6_b7_b8_or));

  hack_or or7 (.a(b1_b2_b3_b4_or), .b(b5_b6_b7_b8_or), .out(out));

endmodule
