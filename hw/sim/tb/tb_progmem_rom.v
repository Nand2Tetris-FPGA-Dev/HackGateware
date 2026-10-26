`timescale 1ns / 1ps

module tb_progmem_rom;
    reg clk = 0, req = 0;
    reg [14:0] addr = 0;
    wire ready;
    wire [15:0] data;
    integer errors = 0;

    progmem_rom #(.WORDS(2048)) dut (
        .clk(clk), .fetch_req(req), .fetch_addr(addr), .fetch_ready(ready), .fetch_data(data)
    );

    always #5 clk = ~clk;

    // ready must come exactly one cycle after the request, for one cycle
    task fetch(input [14:0] a, input [15:0] want);
        begin
            @(negedge clk);
            addr = a;
            req = 1;
            @(negedge clk);
            req = 0;
            if (ready !== 1'b1 || data !== want) begin
                $display("FAIL fetch %0d: ready=%b data=%04x want %04x", a, ready, data, want);
                errors = errors + 1;
            end
            @(negedge clk);
            if (ready !== 1'b0) begin
                $display("FAIL fetch %0d: ready held high", a);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        fetch(0, 16'ha000);
        fetch(15, 16'ha00f);
        fetch(3, 16'ha003);
        fetch(100, 16'h0000);
        fetch(2047, 16'h0000);
        fetch(2048, 16'h0000);
        fetch(30000, 16'h0000);
        if (errors == 0) $display("PASS");
        $finish;
    end
endmodule
