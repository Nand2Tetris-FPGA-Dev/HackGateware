`timescale 1ns / 1ps

// Runs 2 frames and checks de/hsync/vsync against x, y on every clock
module tb_video_timing;
    reg clk = 0, rst = 1;
    wire [9:0] x, y;
    wire hsync, vsync, de;

    video_timing_640x480 dut (
        .clk(clk), .rst(rst), .x(x), .y(y), .hsync(hsync), .vsync(vsync), .de(de)
    );

    always #20 clk = ~clk;

    integer cycle, de_count = 0, vs_low = 0, hs_pulses = 0, hs_width = 0, bad_width = 0, errors = 0;
    reg hs_prev = 1;

    initial begin
        @(posedge clk);
        @(posedge clk);
        #1 rst = 0;
        for (cycle = 0; cycle < 2 * 800 * 525; cycle = cycle + 1) begin
            @(negedge clk);
            if (de !== (x < 640 && y < 480)) errors = errors + 1;
            if (hsync !== !(x >= 656 && x < 752)) errors = errors + 1;
            if (vsync !== !(y >= 490 && y < 492)) errors = errors + 1;
            if (x > 799 || y > 524) errors = errors + 1;
            if (de) de_count = de_count + 1;
            if (!vsync) vs_low = vs_low + 1;
            if (!hsync) hs_width = hs_width + 1;
            if (hs_prev && !hsync) hs_pulses = hs_pulses + 1;
            if (!hs_prev && hsync) begin
                if (hs_width != 96) bad_width = bad_width + 1;
                hs_width = 0;
            end
            hs_prev = hsync;
        end
        $display("de=%0d hs_pulses=%0d bad_width=%0d vs_low=%0d errors=%0d",
                 de_count, hs_pulses, bad_width, vs_low, errors);
        $finish;
    end
endmodule
