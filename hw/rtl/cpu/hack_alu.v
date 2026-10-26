module hack_alu(
    input  [15:0] x, y,     // 16 bit inputs
    input  zx, nx,          // x-input control: zero, negate
    input  zy, ny,          // y-input control: zero, negate
    input  f,               // Function: 1 for Add 0 for And
    input  no,              // Output: negate
    output [15:0] out,      // 16 bit output
    output zr, ng           // Zero and Negative status flags
);

    reg [15:0] x_processed, y_processed, alu_out;

    always @(*) begin
        x_processed = zx ? 16'b0 : x; // Zero x if zx is 1
        if (nx) x_processed = ~x_processed; // Negate x if nx is 1

        y_processed = zy ? 16'b0 : y; // Zero y if zy is 1
        if (ny) y_processed = ~y_processed; // Negate y if ny is 1

        alu_out = f ? (x_processed + y_processed) : (x_processed & y_processed);

        if (no) alu_out = ~alu_out; // Negate output if no is 1
    end

    assign out = alu_out;
    assign zr = (alu_out == 16'b0); // Set zr if output is zero
    assign ng = alu_out[15]; // Set ng if output is negative (MSB is 1)

endmodule
