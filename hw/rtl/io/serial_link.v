`default_nettype none

// Serial link to the PC. KEY (0x01) frames set the Hack keyboard register;
// ECHO (0x02) and STATUS (0x03) get a 0x82 or 0x83 reply. One reply goes out at
// a time and a request that comes in meanwhile is dropped, but KEY frames are
// never held up by a reply. With no good frame for WATCHDOG_CYCLES the keyboard
// goes back to 0, so a key can't stay down when the PC side dies.
// Bad frames (crc, COBS, unknown type, wrong length) count up to BAD_MAX.
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
    input  wire [31:0]  fl_crc
);

    localparam KEY = 8'h01, ECHO = 8'h02, STATUS = 8'h03;
    localparam HELLO = 8'h10, BEGIN = 8'h11, ERASE = 8'h12, DATA = 8'h13;
    localparam PROGRAM = 8'h14, CRC = 8'h15, END = 8'h16;
    localparam VERSION = 8'd1;
    localparam STATUS_LEN = 37;            // reply payload bytes
    localparam ECHO_MAX = 16;

    wire [7:0] rx_byte;
    wire rx_valid, rx_err;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
        .clk(clk), .rst(rst), .rx(uart_rx),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_err)
    );

    wire frame_ok, frame_bad;
    wire [6:0] frame_len;
    wire [5:0] rd_addr;
    wire [7:0] rd_data;

    frame_rx u_frame_rx (
        .clk(clk), .rst(rst), .in_valid(rx_valid), .in_byte(rx_byte), .in_err(rx_err),
        .frame_ok(frame_ok), .frame_len(frame_len), .frame_bad(frame_bad),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // Reply payload in LUT RAM, byte 1 up; byte 0 is the type. ECHO copies its
    // payload out of frame_rx so the next frame can arrive while the reply goes
    // out. STATUS latches a snapshot in one cycle and shifts it in a byte at a
    // time: a 37-to-1 byte mux on the snapshot costs ~1100 LUTs in synth_gowin.
    reg  [7:0] reply [1:STATUS_LEN];
    reg        reply_status = 0;
    reg        tx_start = 0;
    reg  [6:0] tx_len = 0;
    wire       tx_busy;
    wire [5:0] src_addr;
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

    wire [7:0] src_data = reply_flash ? f_byte :
                          src_addr == 0 ? (reply_status ? 8'h83 : 8'h82) : reply[src_addr];

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
        bad_frames, name_le, prog_words, keyboard, {1'b0, heap_hi}, sp_max, sp, d, a,
        instr, {1'b0, pc}, {5'd0, boot_state}
    };

    reg [8*STATUS_LEN-1:0] snap = 0;

    // A KEY needs two reads of frame_rx's buffer (type, then payload), so it
    // lands two cycles after frame_ok. The next frame_ok is at least four
    // bytes (40 bit times) away, and frame_rx keeps the buffer until the next
    // frame's second byte: far longer than KEY_WR, the 37-byte COPY, the
    // 62-byte DATA copy or REQ.
    localparam IDLE = 3'd0, KEY_WR = 3'd1, COPY = 3'd2, DATA_WR = 3'd3, REQ = 3'd4;

    reg [2:0] state = IDLE;
    reg [5:0] idx = 0;
    reg [5:0] last = 0;         // last buffer byte for DATA_WR and REQ
    assign rd_addr = state == IDLE ? 6'd0 : idx;

    reg       fl_pending = 0;   // from a flash request until its reply is out
    reg       f_ready = 0;      // reply waiting for the transmitter
    reg       f_sent = 0;       // reply handed to frame_tx
    reg [7:0] pb_base = 0;      // offset - 2, so buffer byte idx lands at offset + idx - 2

    assign fl_op = f_op;
    assign pb_we = state == DATA_WR && idx != 1;
    assign pb_addr = pb_base + {2'b00, idx};
    assign pb_data = rd_data;

    wire is_key    = rd_data == KEY && frame_len == 2;
    wire is_echo   = rd_data == ECHO && frame_len <= ECHO_MAX + 1;
    wire is_status = rd_data == STATUS && frame_len == 1;
    wire is_hello  = rd_data == HELLO && frame_len == 1;
    wire is_data   = rd_data == DATA && frame_len >= 3;
    wire is_req    = ((rd_data == BEGIN || rd_data == END) && frame_len == 1)
                     || (rd_data == ERASE && frame_len == 5)
                     || (rd_data == PROGRAM && frame_len == 6)
                     || (rd_data == CRC && frame_len == 7);
    wire is_flash  = is_hello || is_data || is_req;
    wire replying  = tx_start || tx_busy;
    wire accepted  = frame_ok && state == IDLE && (is_key || is_echo || is_status || is_flash);
    wire take      = !fl_pending && !fl_busy;
    wire bad = frame_bad || (frame_ok && state == IDLE && !accepted);
    wire latch = state == IDLE && frame_ok && is_status && !replying;

    localparam QW = $clog2(WATCHDOG_CYCLES + 1);
    reg [QW-1:0] quiet = 0;     // cycles since the last accepted frame

    always @(posedge clk)
        if (rst || accepted)
            quiet <= 0;
        else if (quiet != WATCHDOG_CYCLES)
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

    always @(posedge clk)
        if (state == COPY)
            reply[idx] <= reply_status ? snap[7:0] : rd_data;

    always @(posedge clk) begin
        tx_start <= 0;
        fl_req <= 0;
        if (rst) begin
            state <= IDLE;
            keyboard <= 0;
            fl_pending <= 0;
            f_ready <= 0;
            f_sent <= 0;
        end else begin
            if (quiet == WATCHDOG_CYCLES)
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
            case (state)
                IDLE:
                    if (frame_ok) begin
                        idx <= 1;
                        last <= frame_len[5:0] - 1'b1;
                        if (is_key) begin
                            state <= KEY_WR;
                        end else if (latch) begin
                            reply_status <= 1;
                            reply_flash <= 0;
                            tx_len <= STATUS_LEN + 1;
                            state <= COPY;
                        end else if (is_echo && !replying) begin
                            reply_status <= 0;
                            reply_flash <= 0;
                            tx_len <= frame_len;
                            if (frame_len == 1)
                                tx_start <= 1;
                            else
                                state <= COPY;
                        end else if (is_hello && !fl_pending) begin
                            fl_pending <= 1;
                            f_op <= 0;
                            f_b1 <= VERSION;
                            f_ready <= 1;
                        end else if (is_data && !fl_pending) begin
                            state <= DATA_WR;
                        end else if (is_req && take) begin
                            fl_pending <= 1;
                            f_op <= rd_data[2:0];
                            fl_addr <= 0;
                            fl_len <= 0;
                            if (frame_len == 1)
                                fl_req <= 1;
                            else
                                state <= REQ;
                        end
                    end else if (f_ready && !replying) begin
                        f_ready <= 0;
                        f_sent <= 1;
                        reply_flash <= 1;
                        tx_len <= f_op == CRC[2:0] ? 7'd6 : 7'd2;
                        tx_start <= 1;
                    end
                KEY_WR: begin
                    keyboard <= {8'd0, rd_data};
                    state <= IDLE;
                end
                DATA_WR: begin
                    if (idx == 1)
                        pb_base <= rd_data - 8'd2;
                    if (idx == last)
                        state <= IDLE;
                    idx <= idx + 1'b1;
                end
                REQ: begin
                    case (idx)
                        1: fl_addr[7:0] <= rd_data;
                        2: fl_addr[15:8] <= rd_data;
                        3: fl_addr[23:16] <= rd_data;
                        4: fl_len[7:0] <= rd_data;
                        5: fl_len[15:8] <= rd_data;
                        default: fl_len[23:16] <= rd_data;
                    endcase
                    if (idx == last) begin
                        fl_req <= 1;
                        state <= IDLE;
                    end
                    idx <= idx + 1'b1;
                end
                default: begin  // COPY
                    if (idx == tx_len - 1'b1) begin
                        tx_start <= 1;
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
