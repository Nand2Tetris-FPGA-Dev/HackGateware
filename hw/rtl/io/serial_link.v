`default_nettype none

// Serial link to the PC. KEY (0x01) frames set the Hack keyboard register;
// ECHO (0x02) and STATUS (0x03) get a 0x82 or 0x83 reply. One reply goes out at
// a time and a request that comes in meanwhile is dropped, but KEY frames are
// never held up by a reply. With no good frame for WATCHDOG_CYCLES the keyboard
// goes back to 0 and link_lost goes high until the next one, so a key can't
// stay down and the CPU can't stay paused when the PC side dies.
// Bad frames (crc, COBS, unknown type, wrong length, bad field) count up to
// BAD_MAX.
//
// Debug frames go to debug_unit one at a time. DEBUG (0x04: op, seq, gap)
// goes out on dbg_cmd; its 0x84 reply is the STATUS payload, latched after
// cmd_done. READ RAM / READ ROM (0x05 / 0x06: addr, count) go out on rd; the
// words are kept as they come and the reply (addr, count, words) goes out
// after rd_end, with count 0 if refused. Requests that come in before that
// reply has gone out are dropped.
//
// Flash frames: HELLO (0x10) is answered here with the protocol version. DATA
// (0x13: offset, bytes) goes straight to the page buffer on pb_*. BEGIN, ERASE,
// PROGRAM, CRC and END (0x11-0x16) go out on fl_req, one at a time; fl_rsp's
// status (and CRC's crc32) goes back as type | 0x80. Flash frames that come in
// before that reply has gone out are ignored.
module serial_link #(
    parameter CLKS_PER_BIT    = 18,          // 1.5 Mbaud at 27 MHz
    parameter WATCHDOG_CYCLES = 13_500_000,  // 0.5 s at 27 MHz
    parameter BAD_MAX         = 65535
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         uart_rx,
    output wire         uart_tx,
    output reg  [15:0]  keyboard = 0,
    input  wire [2:0]   boot_state,
    input  wire [14:0]  pc,
    input  wire [15:0]  instr,
    input  wire [15:0]  a,
    input  wire [15:0]  d,
    input  wire [15:0]  sp,
    input  wire [15:0]  sp_max,
    input  wire [14:0]  heap_hi,
    input  wire [15:0]  prog_words,
    input  wire [127:0] prog_name,       // header byte 12 in [127:120]
    output reg          fl_req = 0,      // 1-cycle pulse
    output wire [2:0]   fl_op,           // type - 0x10
    output reg  [23:0]  fl_addr = 0,
    output reg  [23:0]  fl_len = 0,      // ERASE: size code; PROGRAM, CRC: length
    output wire         pb_we,
    output wire [7:0]   pb_addr,
    output wire [7:0]   pb_data,
    input  wire         fl_busy,
    input  wire         fl_rsp,          // 1-cycle pulse
    input  wire [1:0]   fl_status,
    input  wire [31:0]  fl_crc,
    output reg          dbg_cmd = 0,     // 1-cycle pulse
    output reg  [2:0]   dbg_op = 0,
    output reg  [7:0]   dbg_seq = 0,
    output reg  [24:0]  dbg_gap = 0,
    output reg          rd = 0,          // 1-cycle pulse
    output reg          rd_rom = 0,
    output reg  [14:0]  rd_addr = 0,
    output reg  [6:0]   rd_count = 0,    // 1-64
    output wire         link_lost,
    input  wire         cmd_done,        // 1-cycle pulse
    input  wire         rd_word_valid,
    input  wire [15:0]  rd_word,
    input  wire         rd_end,          // 1-cycle pulse
    input  wire         rd_refused,
    input  wire         paused,
    input  wire [24:0]  gap,
    input  wire [7:0]   step_seq,
    input  wire [14:0]  next_pc
);

    localparam KEY = 8'h01, ECHO = 8'h02, STATUS = 8'h03;
    localparam DEBUG = 8'h04, READ_RAM = 8'h05, READ_ROM = 8'h06;
    localparam HELLO = 8'h10, BEGIN = 8'h11, ERASE = 8'h12, DATA = 8'h13;
    localparam PROGRAM = 8'h14, CRC = 8'h15, END = 8'h16;
    localparam VERSION = 8'd1;
    localparam STATUS_LEN = 45;            // reply payload bytes
    localparam ECHO_MAX = 16;

    wire [7:0] rx_byte;
    wire rx_valid, rx_err;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_err)
    );

    wire frame_ok, frame_bad;
    wire [6:0] frame_len;
    wire [5:0] fb_addr;
    wire [7:0] fb_data;

    frame_rx u_frame_rx (
        .clk(clk), .rst(rst), .in_valid(rx_valid), .in_byte(rx_byte), .in_err(rx_err),
        .frame_ok(frame_ok), .frame_len(frame_len), .frame_bad(frame_bad),
        .rd_addr(fb_addr), .rd_data(fb_data)
    );

    // Reply payload in LUT RAM, byte 1 up; byte 0 is the type. ECHO copies its
    // payload out of frame_rx so the next frame can arrive while the reply goes
    // out. STATUS latches a snapshot in one cycle and shifts it in a byte at a
    // time: a 37-to-1 byte mux on the snapshot costs ~1100 LUTs in synth_gowin.
    // Even and odd bytes are two RAMs so a read word (bytes 4 + 2k, 5 + 2k)
    // goes in one cycle; debug_unit can give one every cycle. A READ reply's
    // addr and count come from rd_addr and r_cnt.
    reg  [7:0] reply_e [1:65];
    reg  [7:0] reply_o [0:65];
    reg  [7:0] r_type = 0;
    reg        reply_snap = 0;      // COPY takes the snapshot, not frame_rx
    reg        reply_read = 0;
    reg  [6:0] r_cnt = 0;
    reg        tx_start = 0;
    reg  [7:0] tx_len = 0;
    wire       tx_busy;
    wire [7:0] src_addr;
    wire [7:0] tx_byte;
    wire       tx_valid, tx_ready;

    // Flash replies: type, status (version for HELLO), then CRC's crc32. They
    // stay put until the reply is out, as frame_tx reads each byte twice.
    reg        reply_flash = 0;
    reg  [2:0] f_op = 0;
    reg  [7:0] f_b1 = 0;
    reg [31:0] f_crc = 0;
    wire [2:0] fa = src_addr[2:0];
    wire [7:0] f_byte = fa == 0 ? {5'b10010, f_op} :
                        fa == 1 ? f_b1 :
                        fa == 2 ? f_crc[7:0] :
                        fa == 3 ? f_crc[15:8] :
                        fa == 4 ? f_crc[23:16] : f_crc[31:24];

    wire [7:0] r_head = src_addr[1:0] == 1 ? rd_addr[7:0] :
                        src_addr[1:0] == 2 ? {1'b0, rd_addr[14:8]} : {1'b0, r_cnt};
    wire [7:0] r_byte = src_addr[0] ? reply_o[src_addr[7:1]] : reply_e[src_addr[7:1]];
    wire [7:0] src_data = reply_flash ? f_byte :
                          src_addr == 0 ? r_type :
                          reply_read && src_addr < 4 ? r_head : r_byte;

    frame_tx u_frame_tx (
        .clk(clk), .rst(rst), .start(tx_start), .len(tx_len), .busy(tx_busy),
        .src_addr(src_addr), .src_data(src_data),
        .out_valid(tx_valid), .out_byte(tx_byte), .out_ready(tx_ready)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
        .clk(clk), .rst(rst), .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    reg [15:0] bad_frames = 0;

    // prog_name goes out in header order.
    wire [127:0] name_le;
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : name_bytes
            assign name_le[8*i +: 8] = prog_name[127-8*i -: 8];
        end
    endgenerate

    // STATUS payload, little-endian, byte 0 in the low bits.
    wire [8*STATUS_LEN-1:0] status = {
        step_seq, {1'b0, next_pc}, {7'd0, gap}, {7'd0, paused},
        bad_frames, name_le, prog_words, keyboard, {1'b0, heap_hi}, sp_max, sp, d, a,
        instr, {1'b0, pc}, {5'd0, boot_state}
    };

    reg [8*STATUS_LEN-1:0] snap = 0;

    // A KEY needs two reads of frame_rx's buffer (type, then payload), so it
    // lands two cycles after frame_ok. The next frame_ok is at least four
    // bytes (40 bit times) away, and frame_rx keeps the buffer until the next
    // frame's second byte: far longer than KEY_WR, the 45-byte COPY, the
    // 62-byte DATA copy, REQ or FIELDS.
    localparam IDLE = 3'd0, KEY_WR = 3'd1, COPY = 3'd2, DATA_WR = 3'd3, REQ = 3'd4;
    localparam FIELDS = 3'd5, CHECK = 3'd6;

    reg [2:0] state = IDLE;
    reg [5:0] idx = 0;
    reg [5:0] last = 0;         // last buffer byte for DATA_WR, REQ and FIELDS
    assign fb_addr = state == IDLE ? 6'd0 : idx;

    reg       fl_pending = 0;   // from a flash request until its reply is out
    reg       f_ready = 0;      // reply waiting for the transmitter
    reg       f_sent = 0;       // reply handed to frame_tx
    reg [7:0] pb_base = 0;      // offset - 2, so buffer byte idx lands at offset + idx - 2

    // Debug frames: payload bytes p1-p6, then CHECK. d_busy runs from dbg_cmd
    // or rd until the reply starts; d_done and r_done hold its turn to go out.
    reg [7:0] p1 = 0, p2 = 0, p3 = 0, p4 = 0, p5 = 0, p6 = 0;
    reg       p_read = 0, p_rom = 0;
    reg       d_busy = 0, d_done = 0, r_done = 0;
    reg [6:0] wk = 0;           // read words kept

    assign fl_op = f_op;
    assign pb_we = state == DATA_WR && idx != 1;
    assign pb_addr = pb_base + {2'b00, idx};
    assign pb_data = fb_data;

    wire is_key    = fb_data == KEY && frame_len == 2;
    wire is_echo   = fb_data == ECHO && frame_len <= ECHO_MAX + 1;
    wire is_status = fb_data == STATUS && frame_len == 1;
    wire is_debug  = fb_data == DEBUG && frame_len == 7;
    wire is_read   = (fb_data == READ_RAM || fb_data == READ_ROM) && frame_len == 4;
    wire is_hello  = fb_data == HELLO && frame_len == 1;
    wire is_data   = fb_data == DATA && frame_len >= 3;
    wire is_req    = ((fb_data == BEGIN || fb_data == END) && frame_len == 1)
                     || (fb_data == ERASE && frame_len == 5)
                     || (fb_data == PROGRAM && frame_len == 6)
                     || (fb_data == CRC && frame_len == 7);
    wire is_flash  = is_hello || is_data || is_req;
    wire replying  = tx_start || tx_busy;
    wire busy      = replying || d_busy;
    wire in_idle   = frame_ok && state == IDLE;
    wire accepted  = in_idle && (is_key || is_echo || is_status || is_flash);
    wire to_fields = in_idle && (is_debug || is_read);
    // READ: count 1-64 and addr + count <= 32768; DEBUG: op 0-4
    wire [16:0] r_top = {1'b0, p2, p1} + p3;
    wire p_ok = p_read ? p3 != 0 && p3 <= 64 && r_top <= 17'd32768 : p1 <= 4;
    wire good = accepted || (state == CHECK && p_ok);
    wire take = !fl_pending && !fl_busy;
    wire bad = frame_bad || (in_idle && !accepted && !to_fields) || (state == CHECK && !p_ok);
    wire d_snap = !frame_ok && d_done && !replying;
    wire latch = state == IDLE && ((frame_ok && is_status && !busy) || d_snap);

    localparam QW = $clog2(WATCHDOG_CYCLES + 1);
    reg [QW-1:0] quiet = 0;     // cycles since the last good frame
    assign link_lost = quiet == WATCHDOG_CYCLES;

    always @(posedge clk)
        if (rst || good)
            quiet <= 0;
        else if (!link_lost)
            quiet <= quiet + 1'b1;

    always @(posedge clk)
        if (rst)
            bad_frames <= 0;
        else if (bad && bad_frames != BAD_MAX)
            bad_frames <= bad_frames + 1'b1;

    always @(posedge clk)
        if (latch)
            snap <= status;
        else if (state == COPY)
            snap <= snap >> 8;

    // Only one writer at a time: a read only runs while d_busy, and nothing
    // goes to COPY then but a DEBUG reply.
    wire [7:0] w_byte = reply_snap ? snap[7:0] : fb_data;

    always @(posedge clk)
        if (rd_word_valid)
            reply_e[wk + 2'd2] <= rd_word[7:0];
        else if (state == COPY && !idx[0])
            reply_e[idx[5:1]] <= w_byte;

    always @(posedge clk)
        if (rd_word_valid)
            reply_o[wk + 2'd2] <= rd_word[15:8];
        else if (state == COPY && idx[0])
            reply_o[idx[5:1]] <= w_byte;

    always @(posedge clk) begin
        tx_start <= 0;
        fl_req <= 0;
        dbg_cmd <= 0;
        rd <= 0;
        if (rst) begin
            state <= IDLE;
            keyboard <= 0;
            fl_pending <= 0;
            f_ready <= 0;
            f_sent <= 0;
            d_busy <= 0;
            d_done <= 0;
            r_done <= 0;
        end else begin
            if (link_lost)
                keyboard <= 0;
            if (fl_rsp) begin
                f_b1 <= {6'd0, fl_status};
                f_crc <= fl_crc;
                f_ready <= 1;
            end
            if (f_sent && !replying) begin
                fl_pending <= 0;
                f_sent <= 0;
            end
            if (cmd_done)
                d_done <= 1;
            if (rd_word_valid)
                wk <= wk + 1'b1;
            if (rd_end) begin
                r_done <= 1;
                r_cnt <= rd_refused ? 7'd0 : rd_count;
            end
            case (state)
                IDLE:
                    if (frame_ok) begin
                        idx <= 1;
                        last <= frame_len[5:0] - 1'b1;
                        if (is_key) begin
                            state <= KEY_WR;
                        end else if (latch) begin
                            r_type <= 8'h83;
                            reply_snap <= 1;
                            reply_read <= 0;
                            reply_flash <= 0;
                            tx_len <= STATUS_LEN + 1;
                            state <= COPY;
                        end else if (is_echo && !busy) begin
                            r_type <= 8'h82;
                            reply_snap <= 0;
                            reply_read <= 0;
                            reply_flash <= 0;
                            tx_len <= {1'b0, frame_len};
                            if (frame_len == 1)
                                tx_start <= 1;
                            else
                                state <= COPY;
                        end else if (to_fields) begin
                            p_read <= fb_data != DEBUG;
                            p_rom <= fb_data == READ_ROM;
                            state <= FIELDS;
                        end else if (is_hello && !fl_pending) begin
                            fl_pending <= 1;
                            f_op <= 0;
                            f_b1 <= VERSION;
                            f_ready <= 1;
                        end else if (is_data && !fl_pending) begin
                            state <= DATA_WR;
                        end else if (is_req && take) begin
                            fl_pending <= 1;
                            f_op <= fb_data[2:0];
                            fl_addr <= 0;
                            fl_len <= 0;
                            if (frame_len == 1)
                                fl_req <= 1;
                            else
                                state <= REQ;
                        end
                    end else if (d_snap) begin
                        d_done <= 0;
                        idx <= 1;
                        r_type <= 8'h84;
                        reply_snap <= 1;
                        reply_read <= 0;
                        reply_flash <= 0;
                        tx_len <= STATUS_LEN + 1;
                        state <= COPY;
                    end else if (r_done && !replying) begin
                        r_done <= 0;
                        d_busy <= 0;
                        r_type <= rd_rom ? 8'h86 : 8'h85;
                        reply_read <= 1;
                        reply_flash <= 0;
                        tx_len <= 8'd4 + {r_cnt, 1'b0};
                        tx_start <= 1;
                    end else if (f_ready && !replying) begin
                        f_ready <= 0;
                        f_sent <= 1;
                        reply_flash <= 1;
                        tx_len <= f_op == CRC[2:0] ? 8'd6 : 8'd2;
                        tx_start <= 1;
                    end
                KEY_WR: begin
                    keyboard <= {8'd0, fb_data};
                    state <= IDLE;
                end
                DATA_WR: begin
                    if (idx == 1)
                        pb_base <= fb_data - 8'd2;
                    if (idx == last)
                        state <= IDLE;
                    idx <= idx + 1'b1;
                end
                REQ: begin
                    case (idx)
                        1: fl_addr[7:0] <= fb_data;
                        2: fl_addr[15:8] <= fb_data;
                        3: fl_addr[23:16] <= fb_data;
                        4: fl_len[7:0] <= fb_data;
                        5: fl_len[15:8] <= fb_data;
                        default: fl_len[23:16] <= fb_data;
                    endcase
                    if (idx == last) begin
                        fl_req <= 1;
                        state <= IDLE;
                    end
                    idx <= idx + 1'b1;
                end
                FIELDS: begin
                    case (idx[2:0])
                        1: p1 <= fb_data;
                        2: p2 <= fb_data;
                        3: p3 <= fb_data;
                        4: p4 <= fb_data;
                        5: p5 <= fb_data;
                        default: p6 <= fb_data;
                    endcase
                    if (idx == last)
                        state <= CHECK;
                    idx <= idx + 1'b1;
                end
                CHECK: begin
                    // gap is 25 bits; the top 7 bits of its 4th byte are dropped
                    if (p_ok && !busy) begin
                        d_busy <= 1;
                        if (p_read) begin
                            rd <= 1;
                            rd_rom <= p_rom;
                            rd_addr <= {p2[6:0], p1};
                            rd_count <= p3[6:0];
                            wk <= 0;
                        end else begin
                            dbg_cmd <= 1;
                            dbg_op <= p1[2:0];
                            dbg_seq <= p2;
                            dbg_gap <= {p6[0], p5, p4, p3};
                        end
                    end
                    state <= IDLE;
                end
                default: begin  // COPY
                    if (idx == tx_len - 1'b1) begin
                        tx_start <= 1;
                        d_busy <= 0;
                        state <= IDLE;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
