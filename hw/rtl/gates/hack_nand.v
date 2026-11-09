module hack_nand(
  input a, b,
  output out
);

  nand nand1 (out, a, b);

endmodule
