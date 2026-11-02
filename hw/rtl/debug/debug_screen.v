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

    // Decimal fields as 6 right-aligned character codes each, char k of field f
    // (k = 0 rightmost) in fmt[{f, k}]: slot, words, pc, a, d, sp, max, heap.
    // Code 0-9 digit, 10 space, 11 minus. A copied flip-flop costs a LUT
    // too (nextpnr gowin.cc slice_valid: a LUT in an FF's slot must drive its
    // D), so the codes live in LUT RAM, which the async read below infers.
    localparam NF = 8;
    reg [3:0] fmt [0:NF*8-1];

    reg busy = 0;
    reg [2:0] fld = 0;
    reg [4:0] step = 0;   // 0 load, 1-16 shift, 17-22 store char step-17
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
    function [23:0] place(input [19:0] b, input minus);
        integer i, n;
        reg [23:0] w;
        begin
            w = {4'd0, b};
            n = b[19:16] != 0 ? 5 : b[15:12] != 0 ? 4 : b[11:8] != 0 ? 3 :
                b[7:4] != 0 ? 2 : 1;
            for (i = 0; i < 6; i = i + 1)
                if (i < n) place[i*4 +: 4] = w[i*4 +: 4];
                else if (i == n && minus) place[i*4 +: 4] = 4'd11;
                else place[i*4 +: 4] = 4'd10;
        end
    endfunction
    wire [23:0] codes = place(bcd, neg);
    wire [2:0] sk = step[2:0] - 3'd1;   // char stored in steps 17-22

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
            end else if (step < 5'd17) begin
                {bcd, bin} <= {add3(bcd), bin} << 1;
                step <= step + 1'b1;
            end else begin
                fmt[{fld, sk}] <= codes[sk*4 +: 4];
                step <= step == 5'd22 ? 5'd0 : step + 1'b1;
                if (step == 5'd22) begin
                    fld <= fld + 1'b1;
                    if (fld == NF - 1) begin
                        busy <= 1'b0;
                        frame_ready <= 1'b1;
                    end
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
            3'd6: state_name = "WRITE ";
            default: state_name = "PAUSE ";
        endcase
    endfunction
    wire [47:0] state_txt = state_name(state_q);

    wire show_name = state_q == 3'd2 || state_q == 3'd3 || state_q == 3'd7;

    // Fields are blank here and drawn from fmt at the cells in FROW/FCOL/FW
    wire [239:0] line0 = {"HACK  slot ", "  ", "           ", state_txt};
    wire [239:0] line1 = {name_q, " ", "     ", " words  "};
    wire [239:0] line3 = {"PC  ", "      ", " IR ", bits16(instr_q)};
    wire [239:0] line4 = {"A   ", "      ", " D   ", "      ", "         "};
    wire [239:0] line5 = {"SP  ", "      ", " max ", "      ", "         "};
    wire [239:0] line6 = {"heap", "      ", "                    "};

    // Field f: text row, column of its rightmost char (from the right), width
    localparam [NF*5-1:0] FROW = {5'd6, 5'd5, 5'd5, 5'd4, 5'd4, 5'd3, 5'd1, 5'd0};
    localparam [NF*5-1:0] FCOL = {5'd20, 5'd9, 5'd20, 5'd9, 5'd20, 5'd20, 5'd8, 5'd17};
    localparam [NF*3-1:0] FW   = {3'd6, 3'd6, 3'd6, 3'd6, 3'd6, 3'd6, 3'd5, 3'd2};

    // {hit, f, k} for the cell at text row r, column c. Equality compares
    // against constants, so no carry chains.
    function [6:0] field_at(input [4:0] r, input [4:0] c);
        integer f, k;
        begin
            field_at = 7'd0;
            for (f = 0; f < NF; f = f + 1)
                for (k = 0; k < 6; k = k + 1)
                    if (k < FW[f*3 +: 3] && r == FROW[f*5 +: 5] && c == FCOL[f*5 +: 5] + k)
                        field_at = {1'b1, f[2:0], k[2:0]};
        end
    endfunction

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
    wire [6:0] cell_fld = field_at(row_q, rcol);
    wire [3:0] code = fmt[cell_fld[5:0]];
    wire [7:0] fld_ch = code == 4'd10 ? " " : code == 4'd11 ? "-" : {4'h3, code};
    wire use_fld = cell_fld[6] && (row_q != 5'd1 || show_name);
    wire [7:0] next_ch = use_fld ? fld_ch : row_q == 5'd0 ? c0 : row_q == 5'd1 && show_name ? c1 :
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
