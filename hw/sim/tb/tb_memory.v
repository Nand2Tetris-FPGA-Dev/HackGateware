`timescale 1ns / 1ps

module tb_memory;
    reg clk = 0, vclk = 0;
    reg [14:0] address = 0;
    reg [15:0] in = 0, keyboard = 0;
    reg load = 0;
    reg [12:0] vaddr = 0;
    wire [15:0] out, vdata;
    integer errors;

    hack_memory dut (
        .clk(clk), .address(address), .in(in), .load(load), .out(out),
        .keyboard(keyboard), .vclk(vclk), .vaddr(vaddr), .vdata(vdata)
    );

    always #18.5 clk = ~clk;
    always #19.85 vclk = ~vclk;

    task write(input [14:0] a, input [15:0] d);
        begin
            @(negedge clk);
            address = a; in = d; load = 1;
            @(negedge clk);
            load = 0;
        end
    endtask

    // out is registered: it shows the address from the previous clock edge
    task expect_read(input [14:0] a, input [15:0] want);
        begin
            @(negedge clk);
            address = a;
            @(negedge clk);
            if (out !== want) begin
                $display("FAIL read %0d: got %04x want %04x", a, out, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        write(0, 16'h1111);
        write(16383, 16'h2222);
        write(16384, 16'h3333);
        write(24575, 16'h4444);
        write(16384 + 100, 16'hbeef);
        expect_read(0, 16'h1111);
        expect_read(16383, 16'h2222);
        expect_read(16384, 16'h3333);
        expect_read(24575, 16'h4444);
        @(negedge vclk) vaddr = 100;
        @(negedge vclk);
        if (vdata !== 16'hbeef) begin
            $display("FAIL video port: got %04x", vdata);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS ram_and_screen");

        errors = 0;
        keyboard = 16'd131;
        expect_read(24576, 16'd131);
        if (errors == 0) $display("PASS keyboard");

        errors = 0;
        write(24576, 16'hffff);
        write(24600, 16'hffff);
        expect_read(24576 & 15'h3fff, 16'h0000);
        expect_read(24600 & 15'h3fff, 16'h0000);
        expect_read(16384 + ((24600 - 16384) & 15'h1fff), 16'h0000);
        expect_read(24600, 16'h0000);
        if (errors == 0) $display("PASS unmapped");

        $finish;
    end
endmodule
