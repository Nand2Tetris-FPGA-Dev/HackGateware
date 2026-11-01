`timescale 1ns / 1ps

// serial_link with uart_rx bit-banged from rx.txt: one "<idle_bits> <hex byte>"
// or "<idle_bits> brk <bits>" line each. A second uart_rx decodes uart_tx.
// Prints SENT per rx byte (after its stop bit), END after the last, KBD on each
// keyboard change and TX per reply byte, all with the cycle count.
// Status inputs come from plusargs; +FLIP inverts them all right after each
// snapshot (dut.latch), so a late read shows up. +TAIL: cycles to run after END.
// A flash stub answers fl_req +FL_WAIT cycles later with +FL_STATUS and +FL_CRC
// (hex), busy until then; prints FLREQ per request and PB per page buffer write.
// A debug unit stub: cmd_done +DONE_WAIT cycles after dbg_cmd; a read gives
// word addr ^ 16'hA5A5 every +RD_SPACE cycles, or after +REFUSE=n words ends
// refused. paused, gap, step_seq, next_pc from plusargs. Prints DBG per
// command, CMDDONE, RD per read, RDEND, and LOST on each link_lost change.
`ifndef CLKS_PER_BIT
`define CLKS_PER_BIT 9
`endif
`ifndef WATCHDOG
`define WATCHDOG 20000
`endif
`ifndef BAD_MAX
`define BAD_MAX 65535
`endif
module tb_serial_link;
    localparam CPB = `CLKS_PER_BIT;

    reg clk = 0, rst = 1, rx = 1;
    always #18.5185 clk = ~clk;

    integer cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    reg [2:0] boot_state = 0;
    reg [14:0] pc = 0, heap_hi = 0;
    reg [15:0] instr = 0, a = 0, d = 0, sp = 0, sp_max = 0, prog_words = 0;
    reg [127:0] prog_name = 0;
    wire tx;
    wire [15:0] keyboard;
    wire fl_req, pb_we;
    wire [2:0] fl_op;
    wire [23:0] fl_addr, fl_len;
    wire [7:0] pb_addr, pb_data;
    reg fl_busy = 0, fl_rsp = 0;
    reg [1:0] fl_status = 0;
    reg [31:0] fl_crc = 0;
    integer fl_wait, fl_left = 0;

    reg paused = 0;
    reg [24:0] gap = 0;
    reg [7:0] step_seq = 0;
    reg [14:0] next_pc = 0;
    wire dbg_cmd, rd, rd_rom, link_lost;
    wire [2:0] dbg_op;
    wire [7:0] dbg_seq;
    wire [24:0] dbg_gap;
    wire [14:0] rd_addr;
    wire [6:0] rd_count;
    reg cmd_done = 0, rd_word_valid = 0, rd_end = 0, rd_refused = 0;
    reg [15:0] rd_word = 0;
    integer done_wait, done_left = -1, rd_space, refuse, rd_left = 0, rd_wait = 0, rd_n = 0;
    reg [14:0] rd_at = 0;
    reg [2:0] last_op = 0;
    reg [7:0] last_seq = 0;

    serial_link #(
        .CLKS_PER_BIT(CPB), .WATCHDOG_CYCLES(`WATCHDOG), .BAD_MAX(`BAD_MAX)
    ) dut (
        .clk(clk), .rst(rst), .uart_rx(rx), .uart_tx(tx), .keyboard(keyboard),
        .boot_state(boot_state), .pc(pc), .instr(instr), .a(a), .d(d), .sp(sp),
        .sp_max(sp_max), .heap_hi(heap_hi), .prog_words(prog_words), .prog_name(prog_name),
        .fl_req(fl_req), .fl_op(fl_op), .fl_addr(fl_addr), .fl_len(fl_len),
        .pb_we(pb_we), .pb_addr(pb_addr), .pb_data(pb_data),
        .fl_busy(fl_busy), .fl_rsp(fl_rsp), .fl_status(fl_status), .fl_crc(fl_crc),
        .dbg_cmd(dbg_cmd), .dbg_op(dbg_op), .dbg_seq(dbg_seq), .dbg_gap(dbg_gap),
        .rd(rd), .rd_rom(rd_rom), .rd_addr(rd_addr), .rd_count(rd_count),
        .link_lost(link_lost), .cmd_done(cmd_done), .rd_word_valid(rd_word_valid),
        .rd_word(rd_word), .rd_end(rd_end), .rd_refused(rd_refused),
        .paused(paused), .gap(gap), .step_seq(step_seq), .next_pc(next_pc)
    );

    always @(posedge clk) begin
        cmd_done <= 0;
        if (dbg_cmd) begin
            $display("DBG %0d %0d %0d %0d", dbg_op, dbg_seq, dbg_gap, cycle);
            if (done_left >= 0) $display("CMDBUSY %0d", cycle);
            done_left <= done_wait;
            last_op <= dbg_op;
            last_seq <= dbg_seq;
        end else if (done_left == 0) begin
            cmd_done <= 1;
            if (last_op == 2) step_seq <= last_seq;     // as debug_unit does on a STEP
            done_left <= -1;
            $display("CMDDONE %0d", cycle);
        end else if (done_left > 0) begin
            done_left <= done_left - 1;
        end
    end

    always @(posedge clk) begin
        rd_word_valid <= 0;
        rd_end <= 0;
        rd_refused <= 0;
        if (rd) begin
            $display("RD %0d %0d %0d %0d", rd_rom, rd_addr, rd_count, cycle);
            if (rd_left != 0) $display("RDBUSY %0d", cycle);
            rd_at <= rd_addr;
            rd_left <= rd_count;
            rd_n <= 0;
            rd_wait <= rd_space;
        end else if (rd_left > 0) begin
            if (rd_wait > 0) begin
                rd_wait <= rd_wait - 1;
            end else if (rd_n == refuse) begin
                rd_end <= 1;
                rd_refused <= 1;
                rd_left <= 0;
                $display("RDEND 1 %0d", cycle);
            end else begin
                rd_word <= {1'b0, rd_at} ^ 16'hA5A5;
                rd_word_valid <= 1;
                rd_at <= rd_at + 1;
                rd_n <= rd_n + 1;
                rd_left <= rd_left == 1 ? -1 : rd_left - 1;   // -1: end next cycle
                rd_wait <= rd_space;
            end
        end else if (rd_left == -1) begin
            rd_end <= 1;
            rd_left <= 0;
            $display("RDEND 0 %0d", cycle);
        end
    end

    reg lost_seen = 0;
    always @(negedge clk)
        if (link_lost !== lost_seen) begin
            $display("LOST %0d %0d", cycle, link_lost);
            lost_seen = link_lost;
        end

    always @(posedge clk) begin
        fl_rsp <= 0;
        if (pb_we) $display("PB %02x %02x %0d", pb_addr, pb_data, cycle);
        if (fl_req) begin
            $display("FLREQ %0d %06x %0d %0d", fl_op, fl_addr, fl_len, cycle);
            if (fl_busy) $display("FLREQBUSY %0d", cycle);
            fl_busy <= 1;
            fl_left <= fl_wait;
        end else if (fl_busy) begin
            if (fl_left == 0) begin
                fl_busy <= 0;
                fl_rsp <= 1;
            end else begin
                fl_left <= fl_left - 1;
            end
        end
    end

    wire [7:0] tx_byte;
    wire tx_valid, tx_err;
    uart_rx #(.CLKS_PER_BIT(CPB)) mon (
        .clk(clk), .rst(rst), .rx(tx), .data(tx_byte), .valid(tx_valid), .frame_err(tx_err)
    );

    always @(posedge clk) begin
        if (tx_valid) $display("TX %02x %0d", tx_byte, cycle);
        if (tx_err) $display("TXERR %0d", cycle);
    end

    reg [15:0] kbd_seen = 0;
    always @(negedge clk)
        if (keyboard !== kbd_seen) begin
            $display("KBD %0d %02x", cycle, keyboard);
            kbd_seen = keyboard;
        end

    reg latched = 0;
    always @(posedge clk)
        latched <= dut.latch;

    always @(negedge clk)
        if ($test$plusargs("FLIP") && latched) begin
            boot_state = ~boot_state;
            pc = ~pc;
            instr = ~instr;
            a = ~a;
            d = ~d;
            sp = ~sp;
            sp_max = ~sp_max;
            heap_hi = ~heap_hi;
            prog_words = ~prog_words;
            prog_name = ~prog_name;
            paused = ~paused;
            gap = ~gap;
            step_seq = ~step_seq;
            next_pc = ~next_pc;
        end

    task send_byte(input [7:0] value);
        integer i;
        begin
            rx = 0;
            repeat (CPB) @(negedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = value[i];
                repeat (CPB) @(negedge clk);
            end
            rx = 1;
            repeat (CPB) @(negedge clk);
        end
    endtask

    integer fd, n, idle, bits, b, tail;
    reg [8*16-1:0] line, word;

    initial begin
        if (!$value$plusargs("TAIL=%d", tail)) tail = 5000;
        if (!$value$plusargs("BOOT=%h", boot_state)) boot_state = 0;
        if (!$value$plusargs("PC=%h", pc)) pc = 0;
        if (!$value$plusargs("INSTR=%h", instr)) instr = 0;
        if (!$value$plusargs("A=%h", a)) a = 0;
        if (!$value$plusargs("D=%h", d)) d = 0;
        if (!$value$plusargs("SP=%h", sp)) sp = 0;
        if (!$value$plusargs("SPMAX=%h", sp_max)) sp_max = 0;
        if (!$value$plusargs("HEAP=%h", heap_hi)) heap_hi = 0;
        if (!$value$plusargs("WORDS=%h", prog_words)) prog_words = 0;
        if (!$value$plusargs("NAME=%h", prog_name)) prog_name = 0;
        if (!$value$plusargs("FL_WAIT=%d", fl_wait)) fl_wait = 0;
        if (!$value$plusargs("FL_STATUS=%h", fl_status)) fl_status = 0;
        if (!$value$plusargs("FL_CRC=%h", fl_crc)) fl_crc = 0;
        if (!$value$plusargs("PAUSED=%h", paused)) paused = 0;
        if (!$value$plusargs("GAP=%h", gap)) gap = 0;
        if (!$value$plusargs("SEQ=%h", step_seq)) step_seq = 0;
        if (!$value$plusargs("NEXT_PC=%h", next_pc)) next_pc = 0;
        if (!$value$plusargs("DONE_WAIT=%d", done_wait)) done_wait = 0;
        if (!$value$plusargs("RD_SPACE=%d", rd_space)) rd_space = 0;
        if (!$value$plusargs("REFUSE=%d", refuse)) refuse = -1;
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (4 * CPB) @(negedge clk);
        fd = $fopen("rx.txt", "r");
        while ($fgets(line, fd)) begin
            n = $sscanf(line, "%d %s %d", idle, word, bits);
            repeat (idle * CPB) @(negedge clk);
            if (word == "brk") begin
                rx = 0;
                repeat (bits * CPB) @(negedge clk);
                rx = 1;
            end else begin
                n = $sscanf(line, "%d %h", idle, b);
                send_byte(b);
                $display("SENT %0d", cycle);
            end
        end
        $display("END %0d", cycle);
        repeat (tail) @(negedge clk);
        $display("DONE");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
