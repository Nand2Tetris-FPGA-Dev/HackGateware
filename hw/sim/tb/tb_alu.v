`timescale 1ns / 1ps

// Reads {x, y, ctrl} vectors from alu_vectors.hex and prints "out zr ng" for each
module tb_alu;
    reg [47:0] vectors [0:16383];
    reg [15:0] x, y;
    reg [5:0] ctrl;
    wire [15:0] out;
    wire zr, ng;
    integer i, n;

    hack_alu dut (
        .x(x), .y(y),
        .zx(ctrl[5]), .nx(ctrl[4]), .zy(ctrl[3]), .ny(ctrl[2]), .f(ctrl[1]), .no(ctrl[0]),
        .out(out), .zr(zr), .ng(ng)
    );

    initial begin
        if (!$value$plusargs("N=%d", n)) n = 0;
        $readmemh("alu_vectors.hex", vectors, 0, n - 1);
        for (i = 0; i < n; i = i + 1) begin
            {x, y, ctrl} = {vectors[i][47:16], vectors[i][5:0]};
            #1 $display("%04x %0d %0d", out, zr, ng);
        end
        $finish;
    end
endmodule
