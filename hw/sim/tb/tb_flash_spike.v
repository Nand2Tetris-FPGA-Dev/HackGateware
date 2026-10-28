`timescale 1ns / 1ps

// Runs the flash spike against the flash model and prints its LEDs once it's done.
// With +PRESS it then changes the last pattern byte and presses S1 to re-read.
module tb_flash_spike;
    reg clk = 0, btn_s1 = 1;
    wire [5:0] led;
    wire cs_n, sck, mosi, miso;

    top dut (
        .clk(clk), .btn_s1(btn_s1), .btn_s2(1'b1), .led(led),
        .flash_cs_n(cs_n), .flash_clk(sck), .flash_mosi(mosi), .flash_miso(miso)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(cs_n), .clk(sck), .mosi(mosi), .miso(miso)
    );

    always #18.5 clk = ~clk;

    // 10 clock debounce instead of 10 ms
    defparam dut.s1_sync.CLK_HZ = 1000;

    initial begin
        // Power-on reset is 2^16 clocks, then the read takes a few hundred
        wait (led[1] == 1'b0);
        #1000;
        if ($test$plusargs("PRESS")) begin
            $display("FIRST match=%0d done=%0d mismatch=%0d", ~led[0], ~led[1], ~led[2]);
            flash.mem[24'h02000f] = 8'h00;
            btn_s1 = 0;
            repeat (100) @(posedge clk);
            btn_s1 = 1;
            repeat (3000) @(posedge clk);
        end
        $display("LEDS match=%0d done=%0d mismatch=%0d", ~led[0], ~led[1], ~led[2]);
        $finish;
    end

    initial begin
        #(37 * 200000);
        $display("TIMEOUT");
        $finish;
    end
endmodule
