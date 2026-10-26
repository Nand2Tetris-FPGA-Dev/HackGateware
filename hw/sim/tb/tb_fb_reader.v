`timescale 1ns / 1ps

// Draws one frame from a preloaded screen and writes it to frame.txt as
// 480 lines of 640 characters: 1 = black, 0 = white, B = border.
module tb_fb_reader;
    reg clk = 0, rst = 1;
    wire [9:0] x, y;
    wire hs, vs, de;
    wire [12:0] vaddr;
    wire [15:0] vdata, unused;
    wire [23:0] rgb;
    wire de_o, hs_o, vs_o;

    video_timing_640x480 timing (
        .clk(clk), .rst(rst), .x(x), .y(y), .hsync(hs), .vsync(vs), .de(de)
    );

    screen_mem u_screen (
        .clk(clk), .we(1'b0), .addr(13'd0), .din(16'd0), .dout(unused),
        .vclk(clk), .vaddr(vaddr), .vdata(vdata)
    );

    hack_fb_reader dut (
        .clk(clk), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
        .vaddr(vaddr), .vdata(vdata),
        .rgb(rgb), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
    );

    always #20 clk = ~clk;

    integer i, fd, pixels = 0, line_len = 0, short_lines = 0;
    integer in_gap = -1, out_gap = -1, in_count = 0, out_count = 0;
    reg in_counting = 0, out_counting = 0, hs_prev = 1, hs_o_prev = 1;
    reg vs_o_prev = 1, capturing = 0;

    initial begin
        for (i = 0; i < 8192; i = i + 1) u_screen.mem[i] = i * 16'h9e37;
        fd = $fopen("frame.txt", "w");
        @(posedge clk);
        #1 rst = 0;
        #(40 * 2000000);
        $display("TIMEOUT pixels=%0d", pixels);
        $finish;
    end

    always @(negedge clk) begin
        // hsync falling edge to the next de, on the input and the output side
        if (hs_prev && !hs) begin in_counting = 1; in_count = 0; end
        if (in_counting && de) begin in_gap = in_count; in_counting = 0; end
        if (in_counting) in_count = in_count + 1;
        if (hs_o_prev && !hs_o) begin out_counting = 1; out_count = 0; end
        if (out_counting && de_o) begin out_gap = out_count; out_counting = 0; end
        if (out_counting) out_count = out_count + 1;
        hs_prev = hs;
        hs_o_prev = hs_o;

        // Capture the first full frame after a vsync on the output
        if (vs_o_prev && !vs_o) capturing = 1;
        vs_o_prev = vs_o;

        if (capturing && de_o) begin
            case (rgb)
                24'h000000: $fwrite(fd, "1");
                24'hffffff: $fwrite(fd, "0");
                24'h404040: $fwrite(fd, "B");
                default:    $fwrite(fd, "X");
            endcase
            pixels = pixels + 1;
            line_len = line_len + 1;
        end else if (line_len != 0) begin
            $fwrite(fd, "\n");
            if (line_len != 640) short_lines = short_lines + 1;
            line_len = 0;
            if (pixels == 640 * 480) begin
                $fclose(fd);
                $display("short_lines=%0d in_gap=%0d out_gap=%0d", short_lines, in_gap, out_gap);
                $finish;
            end
        end
    end
endmodule
