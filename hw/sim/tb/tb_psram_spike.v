`timescale 1ns / 1ps

// Runs the PSRAM spike (64 words) against the W955D8MBYA model, prints its LEDs
// once it's done, then holds S1 and prints the latency they show.
// With +CORRUPT it flips one stored word after the write phase.
module tb_psram_spike;
    reg clk = 0, btn_s1 = 1;
    wire [5:0] led;
    wire [1:0] ck, ck_n, cs_n, reset_n, rwds;
    wire [15:0] dq;

    top #(.N_WORDS(64)) dut (
        .clk(clk), .btn_s1(btn_s1), .btn_s2(1'b1), .led(led),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n),
        .O_psram_reset_n(reset_n), .IO_psram_dq(dq), .IO_psram_rwds(rwds)
    );

    w955d8mbya_model psram (
        .ck(ck), .ck_n(ck_n), .cs_n(cs_n), .reset_n(reset_n), .dq(dq), .rwds(rwds)
    );

    always #18.5 clk = ~clk;

    initial
        if ($test$plusargs("CORRUPT")) begin
            wait (dut.reading);
            psram.die0.mem[5] = ~psram.die0.mem[5];
        end

    initial begin
        wait (led[1] == 1'b0);
        #1000;
        $display("LEDS pass=%0d done=%0d fail=%0d", ~led[0], ~led[1], ~led[2]);
        btn_s1 = 0;
        repeat (10) @(posedge clk);
        $display("LATENCY %0d", ~led);
        $display("MODEL errors=%0d", psram.error_count);
        $finish;
    end

    initial begin
        #(37 * 100000);
        $display("TIMEOUT");
        $finish;
    end
endmodule
