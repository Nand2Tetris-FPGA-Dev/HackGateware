module hack_dmux4way(
  input in,
  input [1:0] sel,
  output a, b, c, d
);

  // Basic implementation is equivalent to nand optimized implementation
  wire dmux_a_b, dmux_c_d;

  hack_dmux dmux1 (.in(in), .sel(sel[1]), .a(dmux_a_b), .b(dmux_c_d));
  hack_dmux dmux2 (.in(dmux_a_b), .sel(sel[0]), .a(a), .b(b));
  hack_dmux dmux3 (.in(dmux_c_d), .sel(sel[0]), .a(c), .b(d));

endmodule
