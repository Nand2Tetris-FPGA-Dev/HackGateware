module hack_mux8way16(
  input [15:0] a, b, c, d, e, f, g, h,
  input [2:0] sel,
  output [15:0] out
);

  // Basic implementation
  wire [15:0] mux_a_b_c_d, mux_e_f_g_h;

  hack_mux4way16 mux4way1 (.a(a), .b(b), .c(c), .d(d), .sel(sel[1:0]), .out(mux_a_b_c_d));
  hack_mux4way16 mux4way2 (.a(e), .b(f), .c(g), .d(h), .sel(sel[1:0]), .out(mux_e_f_g_h));
  hack_mux16 mux1 (.a(mux_a_b_c_d), .b(mux_e_f_g_h), .sel(sel[2]), .out(out));

endmodule
