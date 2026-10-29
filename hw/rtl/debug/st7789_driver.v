`default_nettype none

// Drives the 1.14" 240x135 ST7789V panel over its 4-line serial interface and
// streams full frames forever.
//
// Power-up and init list follow Sipeed's example (TangNano-9K-example 61adac1,
// spi_lcd/src/top.v): reset low 100 ms, wait 200 ms, SLPOUT, wait 120 ms, then
// the command list, which ends by setting the window to columns 40-279 and
// rows 53-187.
//
// SPI (ST7789V datasheet v1.3 section 8.4.2): MSB first, SDA and D/CX sampled
// on SCL rising, D/CX low for a command. SDA and D/CX change on SCL falling.
// SCL = clk / 2 = 13.5 MHz, a 74 ns cycle; section 7.4.2 Table 5 needs
// TSCYCW >= 66 ns. CS stays low across the bytes of a command and its data.
//
// Each frame: frame_start pulse, wait for frame_ready (checked from the second
// cycle after the pulse), RAMWR (0x2C), then 240x135 pixels, row by row,
// high byte first. RAMWR resets the write position to the window start
// (section 9.1.22), so each frame starts at (0, 0) without relying on wrap.
//
// Pixels: pix_req pulses with pix_x/pix_y; pixel must hold the color in the
// 4th cycle after the pix_req cycle (4 register stages are allowed).
module st7789_driver #(
    parameter RESET_CYCLES = 2_700_000,  // 100 ms at 27 MHz
    parameter WAKE_CYCLES  = 5_400_000,  // 200 ms
    parameter SLEEP_CYCLES = 3_240_000   // 120 ms
) (
    input  wire        clk,
    input  wire        rst,
    output reg         frame_start,
    input  wire        frame_ready,
    output reg         pix_req,
    output reg  [7:0]  pix_x,
    output reg  [7:0]  pix_y,
    input  wire [15:0] pixel,
    output wire        lcd_resetn,
    output wire        lcd_clk,
    output wire        lcd_cs,
    output wire        lcd_rs,
    output wire        lcd_data
);

    localparam INIT_LEN = 69;
    localparam W = 240, H = 135;

    localparam S_RESET = 4'd0, S_WAKE = 4'd1, S_SLPOUT = 4'd2, S_SLEEP = 4'd3,
               S_INIT = 4'd4, S_FSTART = 4'd5, S_FWAIT0 = 4'd6, S_FWAIT = 4'd7,
               S_FRAME = 4'd8;

    // {dc, byte}, as Sipeed's init_cmd
    reg [6:0] init_idx;
    reg [8:0] init_word;
    always @* begin
        case (init_idx)
            7'd0:  init_word = 9'h036;  // MADCTL
            7'd1:  init_word = 9'h170;
            7'd2:  init_word = 9'h03A;  // COLMOD: RGB565
            7'd3:  init_word = 9'h105;
            7'd4:  init_word = 9'h0B2;
            7'd5:  init_word = 9'h10C;
            7'd6:  init_word = 9'h10C;
            7'd7:  init_word = 9'h100;
            7'd8:  init_word = 9'h133;
            7'd9:  init_word = 9'h133;
            7'd10: init_word = 9'h0B7;
            7'd11: init_word = 9'h135;
            7'd12: init_word = 9'h0BB;
            7'd13: init_word = 9'h119;
            7'd14: init_word = 9'h0C0;
            7'd15: init_word = 9'h12C;
            7'd16: init_word = 9'h0C2;
            7'd17: init_word = 9'h101;
            7'd18: init_word = 9'h0C3;
            7'd19: init_word = 9'h112;
            7'd20: init_word = 9'h0C4;
            7'd21: init_word = 9'h120;
            7'd22: init_word = 9'h0C6;
            7'd23: init_word = 9'h10F;
            7'd24: init_word = 9'h0D0;
            7'd25: init_word = 9'h1A4;
            7'd26: init_word = 9'h1A1;
            7'd27: init_word = 9'h0E0;
            7'd28: init_word = 9'h1D0;
            7'd29: init_word = 9'h104;
            7'd30: init_word = 9'h10D;
            7'd31: init_word = 9'h111;
            7'd32: init_word = 9'h113;
            7'd33: init_word = 9'h12B;
            7'd34: init_word = 9'h13F;
            7'd35: init_word = 9'h154;
            7'd36: init_word = 9'h14C;
            7'd37: init_word = 9'h118;
            7'd38: init_word = 9'h10D;
            7'd39: init_word = 9'h10B;
            7'd40: init_word = 9'h11F;
            7'd41: init_word = 9'h123;
            7'd42: init_word = 9'h0E1;
            7'd43: init_word = 9'h1D0;
            7'd44: init_word = 9'h104;
            7'd45: init_word = 9'h10C;
            7'd46: init_word = 9'h111;
            7'd47: init_word = 9'h113;
            7'd48: init_word = 9'h12C;
            7'd49: init_word = 9'h13F;
            7'd50: init_word = 9'h144;
            7'd51: init_word = 9'h151;
            7'd52: init_word = 9'h12F;
            7'd53: init_word = 9'h11F;
            7'd54: init_word = 9'h11F;
            7'd55: init_word = 9'h120;
            7'd56: init_word = 9'h123;
            7'd57: init_word = 9'h021;  // INVON
            7'd58: init_word = 9'h029;  // DISPON
            7'd59: init_word = 9'h02A;  // CASET 40-279
            7'd60: init_word = 9'h100;
            7'd61: init_word = 9'h128;
            7'd62: init_word = 9'h101;
            7'd63: init_word = 9'h117;
            7'd64: init_word = 9'h02B;  // RASET 53-187
            7'd65: init_word = 9'h100;
            7'd66: init_word = 9'h135;
            7'd67: init_word = 9'h100;
            default: init_word = 9'h1BB;
        endcase
    end

    reg [3:0] state;
    reg [22:0] count;
    reg resetn, sck, cs, dc, sda;
    reg [15:0] shift;        // bits still to send, MSB next
    reg [4:0] bits_left;
    reg [3:0] req_pipe;
    reg [15:0] pix_buf;
    reg [14:0] pix_left;     // pixels not yet loaded into shift

    initial begin
        state = S_RESET;
        count = 0;
        init_idx = 0;
        resetn = 0;
        sck = 0;
        cs = 1;
        dc = 0;
        sda = 0;
        shift = 0;
        bits_left = 0;
        req_pipe = 0;
        pix_buf = 0;
        pix_left = 0;
        frame_start = 0;
        pix_req = 0;
        pix_x = 0;
        pix_y = 0;
    end

    assign lcd_resetn = resetn;
    assign lcd_clk = sck;
    assign lcd_cs = cs;
    assign lcd_rs = dc;
    assign lcd_data = sda;

    // The last bit's falling edge is this cycle's edge
    wire word_done = bits_left == 5'd1 && sck;

    always @(posedge clk) begin
        pix_req <= 1'b0;
        req_pipe <= {req_pipe[2:0], pix_req};
        if (req_pipe[3]) pix_buf <= pixel;

        if (bits_left != 0) begin
            sck <= ~sck;
            if (sck) begin
                bits_left <= bits_left - 1'b1;
                sda <= shift[15];
                shift <= {shift[14:0], 1'b0};
            end
        end

        if (rst) begin
            state <= S_RESET;
            count <= 0;
            resetn <= 1'b0;
            sck <= 1'b0;
            cs <= 1'b1;
            bits_left <= 0;
            frame_start <= 1'b0;
            req_pipe <= 0;
        end else begin
            case (state)
                S_RESET:
                    if (count == RESET_CYCLES) begin
                        count <= 0;
                        resetn <= 1'b1;
                        state <= S_WAKE;
                    end else begin
                        count <= count + 1'b1;
                    end
                S_WAKE:
                    if (count == WAKE_CYCLES) begin
                        count <= 0;
                        send(16'h1100, 5'd8, 1'b0);  // SLPOUT
                        state <= S_SLPOUT;
                    end else begin
                        count <= count + 1'b1;
                    end
                S_SLPOUT:
                    if (word_done) begin
                        cs <= 1'b1;
                        state <= S_SLEEP;
                    end
                S_SLEEP:
                    if (count == SLEEP_CYCLES) begin
                        count <= 0;
                        send({init_word[7:0], 8'h00}, 5'd8, init_word[8]);
                        init_idx <= 1;
                        state <= S_INIT;
                    end else begin
                        count <= count + 1'b1;
                    end
                S_INIT:
                    if (word_done) begin
                        if (init_idx == INIT_LEN) begin
                            cs <= 1'b1;
                            state <= S_FSTART;
                        end else begin
                            send({init_word[7:0], 8'h00}, 5'd8, init_word[8]);
                            init_idx <= init_idx + 1'b1;
                        end
                    end
                S_FSTART: begin
                    frame_start <= 1'b1;
                    state <= S_FWAIT0;
                end
                S_FWAIT0: begin
                    // frame_ready can't have dropped yet
                    frame_start <= 1'b0;
                    state <= S_FWAIT;
                end
                S_FWAIT:
                    if (frame_ready) begin
                        send(16'h2C00, 5'd8, 1'b0);  // RAMWR
                        pix_left <= W * H;
                        pix_req <= 1'b1;
                        pix_x <= 0;
                        pix_y <= 0;
                        state <= S_FRAME;
                    end
                S_FRAME:
                    if (word_done) begin
                        if (pix_left == 0) begin
                            cs <= 1'b1;
                            state <= S_FSTART;
                        end else begin
                            send(pix_buf, 5'd16, 1'b1);
                            pix_left <= pix_left - 1'b1;
                            if (pix_left != 1) begin
                                pix_req <= 1'b1;
                                if (pix_x == W - 1) begin
                                    pix_x <= 0;
                                    pix_y <= pix_y + 1'b1;
                                end else begin
                                    pix_x <= pix_x + 1'b1;
                                end
                            end
                        end
                    end
                default: state <= S_RESET;
            endcase
        end
    end

    // Start a word: first bit out now, SCL rises next cycle
    task send(input [15:0] word, input [4:0] nbits, input is_data);
        begin
            cs <= 1'b0;
            dc <= is_data;
            sck <= 1'b0;
            sda <= word[15];
            shift <= {word[14:0], 1'b0};
            bits_left <= nbits;
        end
    endtask

endmodule

`default_nettype wire
