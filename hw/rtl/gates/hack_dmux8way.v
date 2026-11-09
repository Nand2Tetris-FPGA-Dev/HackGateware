module hack_dmux8way(
  input in,
  input [2:0] sel,
  output a, b, c, d, e, f, g, h
);

  // Basic implementation is equivalent to nand optimized implementation
  wire dmux_a_b_c_d, dmux_e_f_g_h;

  hack_dmux dmux1 (.in(in), .sel(sel[2]), .a(dmux_a_b_c_d), .b(dmux_e_f_g_h));
  hack_dmux4way dmux4way1 (.in(dmux_a_b_c_d), .sel(sel[1:0]), .a(a), .b(b), .c(c), .d(d));
  hack_dmux4way dmux4way2 (.in(dmux_e_f_g_h), .sel(sel[1:0]), .a(e), .b(f), .c(g), .d(h));

endmodule
