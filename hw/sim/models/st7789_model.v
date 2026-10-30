`timescale 1ns / 1ps

// Simulation model of the ST7789V 4-line serial write interface (datasheet
// v1.3 section 8.4.2): MSB first, SDA and D/CX sampled on SCL rising, D/CX
// low for a command.
//
// Logs every byte to lcd_log.txt as Cxx (command) or Dxx (data). Tracks
// CASET, RASET and RAMWR (sections 9.1.20-9.1.22); each time the window is
// filled it writes frame.hex (the 240x135 visible area, columns 40-279 and
// rows 53-187, row-major) and prints FRAME n. Protocol problems print
// ERROR lines and count in errors. Timing limits from section 7.4.2 Table 5,
// rounded up: SCL high and low >= 30 ns, SCL cycle >= 66 ns, CS high >= 40 ns,
// SDA/DCX setup >= 10 ns and no change while SCL is high.
module st7789_model (
    input wire resetn,
    input wire scl,
    input wire cs,
    input wire dc,
    input wire sda
);

    localparam X0 = 40, Y0 = 53, W = 240, H = 135;

    reg [15:0] fb [0:W*H-1];
    integer log_f, errors = 0, frames_done = 0, nbits = 0, nargs = 0, i;
    reg [7:0] shift, cmd = 0, hi;
    reg byte_dc, have_hi = 0, writing = 0;
    reg [15:0] xs = 0, xe = 0, ys = 0, ye = 0, x = 0, y = 0;
    real t_rise = -1000, t_fall = -1000, t_cs_rise = -1000, t_data = -1000;

    initial begin
        log_f = $fopen("lcd_log.txt", "w");
        for (i = 0; i < W * H; i = i + 1) fb[i] = 0;
    end

    task error(input string why);
        begin
            $display("ERROR %0s at %0t", why, $realtime);
            errors = errors + 1;
        end
    endtask

    function [7:0] hexdigit(input [3:0] n);
        hexdigit = n < 10 ? "0" + n : "A" + n - 10;
    endfunction

    task frame_done;
        integer f;
        begin
            f = $fopen("frame.hex", "w");
            for (i = 0; i < W * H; i = i + 1) $fdisplay(f, "%04h", fb[i]);
            $fclose(f);
            $fflush(log_f);
            frames_done = frames_done + 1;
            $display("FRAME %0d", frames_done);
        end
    endtask

    task put_pixel(input [15:0] p);
        begin
            if (!writing) begin
                error("pixel after the window is full");
            end else begin
                if (x < X0 || x >= X0 + W || y < Y0 || y >= Y0 + H)
                    error("pixel outside the panel");
                else
                    fb[(y - Y0) * W + (x - X0)] = p;
                if (x == xe) begin
                    x = xs;
                    if (y == ye) begin
                        writing = 0;
                        frame_done;
                    end else begin
                        y = y + 1;
                    end
                end else begin
                    x = x + 1;
                end
            end
        end
    endtask

    task got_byte(input is_data, input [7:0] b);
        begin
            $fdisplay(log_f, "%s%s%s", is_data ? "D" : "C", hexdigit(b[7:4]), hexdigit(b[3:0]));
            if (!is_data) begin
                cmd = b;
                nargs = 0;
                have_hi = 0;
                writing = 0;
                if (b == 8'h2C) begin
                    x = xs;
                    y = ys;
                    writing = 1;
                end
            end else begin
                case (cmd)
                    8'h2A: case (nargs)
                        0: xs[15:8] = b;
                        1: xs[7:0] = b;
                        2: xe[15:8] = b;
                        3: xe[7:0] = b;
                        default: ;
                    endcase
                    8'h2B: case (nargs)
                        0: ys[15:8] = b;
                        1: ys[7:0] = b;
                        2: ye[15:8] = b;
                        3: ye[7:0] = b;
                        default: ;
                    endcase
                    8'h2C:
                        if (!have_hi) begin
                            hi = b;
                            have_hi = 1;
                        end else begin
                            have_hi = 0;
                            put_pixel({hi, b});
                        end
                    default: ;
                endcase
                nargs = nargs + 1;
            end
        end
    endtask

    always @(sda or dc) t_data = $realtime;

    always @(negedge cs) begin
        if ($realtime - t_cs_rise < 40) error("CS high < 40 ns");
        nbits = 0;
    end

    always @(posedge cs) begin
        t_cs_rise = $realtime;
        if (nbits != 0) error("CS rose mid-byte");
    end

    always @(posedge scl) if (!cs && resetn) begin
        if ($realtime - t_fall < 30) error("SCL low < 30 ns");
        if ($realtime - t_rise < 66) error("SCL cycle < 66 ns");
        if ($realtime - t_data < 10) error("SDA/DCX setup < 10 ns");
        t_rise = $realtime;
        if (nbits == 0) byte_dc = dc;
        else if (dc !== byte_dc) error("D/CX changed mid-byte");
        shift = {shift[6:0], sda};
        nbits = nbits + 1;
        if (nbits == 8) begin
            nbits = 0;
            got_byte(byte_dc, shift);
        end
    end

    // A change at the same time as the falling edge is fine
    always @(negedge scl) if (!cs && resetn) begin
        if ($realtime - t_rise < 30) error("SCL high < 30 ns");
        if (t_data >= t_rise && t_data < $realtime) error("SDA/DCX changed while SCL high");
        t_fall = $realtime;
    end

endmodule
