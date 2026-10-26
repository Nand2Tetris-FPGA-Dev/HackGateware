`timescale 1ns / 1ps

// CLK_HZ = 1000 makes the 10 ms debounce 10 clocks
module tb_reset_sync;
    reg clk = 0, in = 0;
    wire out;
    integer errors = 0;

    reset_sync #(.DEBOUNCE(1), .CLK_HZ(1000)) dut (.clk(clk), .async_in(in), .sync_out(out));

    always #5 clk = ~clk;

    initial begin
        repeat (20) @(negedge clk);

        in = 1;                        // 5 clock glitch is ignored
        repeat (5) @(negedge clk);
        in = 0;
        repeat (30) @(negedge clk);
        if (out !== 1'b0) begin $display("FAIL glitch got through"); errors = errors + 1; end

        in = 1;                        // a held press gets through
        repeat (30) @(negedge clk);
        if (out !== 1'b1) begin $display("FAIL press not seen"); errors = errors + 1; end

        in = 0;
        repeat (30) @(negedge clk);
        if (out !== 1'b0) begin $display("FAIL release not seen"); errors = errors + 1; end

        if (errors == 0) $display("PASS");
        $finish;
    end
endmodule
