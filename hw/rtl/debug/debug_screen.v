`default_nettype none

// Status text for st7789_driver: 30x16 cells of 8x8 pixels, white on black.
//
// frame_start latches every input. The numbers are then converted to decimal
// one field at a time by a shared double dabble unit (signed fields convert
// their magnitude), and frame_ready rises when all are done, so a frame never
// mixes old and new values.
//
// Pixels take 4 register stages: cell -> character -> font row -> color.
// Font: font8x8_basic, github.com/dhepper/font8x8 commit 8e279d2 (public
// domain), glyph c row r at c*8+r, bit 0 is the leftmost pixel. Glyph 0 is
// blank, so zero bytes in the name show as spaces.
`ifndef FONT_HEX
`define FONT_HEX "hw/rtl/debug/font8x8.hex"
`endif
module debug_screen (
    input  wire         clk,
    input  wire         rst,
    input  wire         frame_start,
    output reg          frame_ready,
    input  wire         pix_req,
    input  wire [7:0]   pix_x,
    input  wire [7:0]   pix_y,
    output reg  [15:0]  pixel,
    input  wire [2:0]   boot_state,
    input  wire [4:0]   slot,
    input  wire [127:0] prog_name,
    input  wire [15:0]  prog_words,
    input  wire [14:0]  pc,
    input  wire [15:0]  instr,
    input  wire [15:0]  a,
    input  wire [15:0]  d,
    input  wire [15:0]  sp,
    input  wire [15:0]  sp_max,
    input  wire [14:0]  heap_hi
);

    // Snapshot
    reg [2:0]   state_q = 0;
    reg [4:0]   slot_q = 0;
    reg [127:0] name_q = 0;
    reg [15:0]  words_q = 0, instr_q = 0, a_q = 0, d_q = 0, sp_q = 0, max_q = 0;
    reg [14:0]  pc_q = 0, heap_q = 0;

    // Decimal fields as 6 right-aligned characters each, field f in
    // fmt[f*48 +: 48]: slot, words, pc, a, d, sp, max, heap
    localparam NF = 8;
    reg [NF*48-1:0] fmt = 0;

    reg busy = 0;
    reg [2:0] fld = 0;
    reg [4:0] step = 0;   // 0 load, 1-16 shift, 17 store
    reg [15:0] bin = 0;
    reg [19:0] bcd = 0;
    reg neg = 0;

    initial begin
        frame_ready = 1'b0;
        pixel = 16'h0000;
    end

    // Continuous assigns rather than always @*, which Icarus doesn't run until
    // an input changes. Functions only see their arguments.
    wire [15:0] src = fld == 3'd0 ? {11'd0, slot_q} : fld == 3'd1 ? words_q :
                      fld == 3'd2 ? {1'b0, pc_q} : fld == 3'd3 ? a_q :
                      fld == 3'd4 ? d_q : fld == 3'd5 ? sp_q :
                      fld == 3'd6 ? max_q : {1'b0, heap_q};
    wire src_neg = (fld == 3'd3 || fld == 3'd4) && src[15];

    function [19:0] add3(input [19:0] b);
        integer i;
        begin
            for (i = 0; i < 5; i = i + 1)
                add3[i*4 +: 4] = b[i*4 +: 4] >= 4'd5 ? b[i*4 +: 4] + 4'd3 : b[i*4 +: 4];
        end
    endfunction

    // Right-align the digits in 6 places with the sign just left of them
    function [47:0] place(input [19:0] b, input minus);
        integer i, n;
        reg [23:0] w;
        begin
            w = {4'd0, b};
            n = b[19:16] != 0 ? 5 : b[15:12] != 0 ? 4 : b[11:8] != 0 ? 3 :
                b[7:4] != 0 ? 2 : 1;
            for (i = 0; i < 6; i = i + 1)
                if (i < n) place[i*8 +: 8] = {4'h3, w[i*4 +: 4]};
                else if (i == n && minus) place[i*8 +: 8] = "-";
                else place[i*8 +: 8] = " ";
        end
    endfunction
    wire [47:0] chars = place(bcd, neg);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            frame_ready <= 1'b0;
        end else if (frame_start) begin
            state_q <= boot_state;
            slot_q <= slot;
            name_q <= prog_name;
            words_q <= prog_words;
            pc_q <= pc;
            instr_q <= instr;
            a_q <= a;
            d_q <= d;
            sp_q <= sp;
            max_q <= sp_max;
            heap_q <= heap_hi;
            frame_ready <= 1'b0;
            busy <= 1'b1;
            fld <= 0;
            step <= 0;
        end else if (busy) begin
            if (step == 0) begin
                bin <= src_neg ? -src : src;
                neg <= src_neg;
                bcd <= 0;
                step <= 1;
            end else if (step != 17) begin
                {bcd, bin} <= {add3(bcd), bin} << 1;
                step <= step + 1'b1;
            end else begin
                fmt <= {chars, fmt[NF*48-1:48]};
                step <= 0;
                fld <= fld + 1'b1;
                if (fld == NF - 1) begin
                    busy <= 1'b0;
                    frame_ready <= 1'b1;
                end
            end
        end
    end

    function [127:0] bits16(input [15:0] v);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) bits16[i*8 +: 8] = 8'h30 | v[i];
        end
    endfunction

    function [47:0] state_name(input [2:0] s);
        case (s)
            3'd0: state_name = "WAIT  ";
            3'd1: state_name = "LOAD  ";
            3'd2: state_name = "RUN   ";
            3'd3: state_name = "RESET ";
            3'd4: state_name = "NO IMG";
            3'd5: state_name = "BADCRC";
            default: state_name = "      ";
        endcase
    endfunction
    wire [47:0] state_txt = state_name(state_q);

    wire show_name = state_q == 3'd2 || state_q == 3'd3;

    wire [239:0] line0 = {"HACK  slot ", fmt[0*48 +: 16], "           ", state_txt};
    wire [239:0] line1 = {name_q, " ", fmt[1*48 +: 40], " words  "};
    wire [239:0] line3 = {"PC  ", fmt[2*48 +: 48], " IR ", bits16(instr_q)};
    wire [239:0] line4 = {"A   ", fmt[3*48 +: 48], " D   ", fmt[4*48 +: 48], "         "};
    wire [239:0] line5 = {"SP  ", fmt[5*48 +: 48], " max ", fmt[6*48 +: 48], "         "};
    wire [239:0] line6 = {"heap", fmt[7*48 +: 48], "                    "};

    // Stage 1: cell (column counted from the right, as in the line vectors);
    // 2: character; 3: font row (BSRAM); 4: color
    reg [4:0] row_q = 0, rcol = 0;
    reg [2:0] gy1 = 0, gx1 = 0, gy2 = 0, gx2 = 0, gx3 = 0;
    reg [7:0] ch = 0, font_row = 0;
    reg [7:0] font [0:1023];

    initial $readmemh(`FONT_HEX, font);

    // Column first, then row: muxing whole lines by row costs far more
    wire [7:0] c0 = line0[rcol*8 +: 8], c1 = line1[rcol*8 +: 8], c3 = line3[rcol*8 +: 8],
               c4 = line4[rcol*8 +: 8], c5 = line5[rcol*8 +: 8], c6 = line6[rcol*8 +: 8];
    wire [7:0] next_ch = row_q == 5'd0 ? c0 : row_q == 5'd1 && show_name ? c1 :
                      row_q == 5'd3 ? c3 : row_q == 5'd4 ? c4 :
                      row_q == 5'd5 ? c5 : row_q == 5'd6 ? c6 : " ";

    always @(posedge clk) begin
        if (pix_req) begin
            row_q <= pix_y[7:3];
            rcol <= 5'd29 - pix_x[7:3];
            gy1 <= pix_y[2:0];
            gx1 <= pix_x[2:0];
        end
        ch <= next_ch;
        gy2 <= gy1;
        gx2 <= gx1;
        font_row <= font[{ch[6:0], gy2}];
        gx3 <= gx2;
        pixel <= font_row[gx3] ? 16'hFFFF : 16'h0000;
    end

endmodule

`default_nettype wire
