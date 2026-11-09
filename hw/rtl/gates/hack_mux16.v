module hack_mux16(
  input [15:0] a, b,
  input sel,
  output [15:0] out
);

  // Basic implementation is equivalent to nand optimized implementation
  hack_mux mux_array [15:0] (.a(a), .b(b), .sel(sel), .out(out));

endmodule
