module hack_mux4way16(
  input [15:0] a, b, c, d,
  input [1:0] sel,
  output [15:0] out
);

  // Basic implementation
  wire [15:0] mux_a_b, mux_c_d;

  hack_mux16 mux1 (.a(a), .b(b), .sel(sel[0]), .out(mux_a_b));
  hack_mux16 mux2 (.a(c), .b(d), .sel(sel[0]), .out(mux_c_d));
  hack_mux16 mux3 (.a(mux_a_b), .b(mux_c_d), .sel(sel[1]), .out(out));

endmodule
