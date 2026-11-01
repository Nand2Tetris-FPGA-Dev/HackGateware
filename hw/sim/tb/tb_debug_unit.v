`timescale 1ns / 1ps

`ifndef PM_LATENCY
`define PM_LATENCY 1
`endif

// debug_unit on hack_computer and progmem_sim, running rom.hex for +CYCLES
// cycles. +ITEMS=n reads n lines of "kind at a b c" from items.txt. Items are
// taken in order, each once cycle `at` is reached:
//   0 command op a, seq b, gap c
//   1, 2 RAM or ROM read of b words from a
//   3 hold (CPU reset) level a
//   4 go_run level a
//   5 wait until the current read has given a words
//   6 wait a cycles
// Commands and reads wait for the one before to end, as serial_link does.
// Prints CMD/DONE per command, RD/WORD/END per read, START per fetch_start and
// FINAL at the end, and writes trace.txt (pc before, A after, D after).
module tb_debug_unit;
    reg clk = 0, vclk = 0, rst = 1, init = 1, hold = 0, go_run = 0;
    reg cmd = 0, rd = 0, rd_rom = 0;
    reg [2:0] cmd_op = 0;
    reg [7:0] cmd_seq = 0;
    reg [24:0] cmd_gap = 0;
    reg [14:0] rd_addr = 0;
    reg [6:0] rd_count = 0;
    wire cmd_done, rd_word_valid, rd_end, rd_refused, paused, reset_cpu, fetch_en;
    wire [15:0] rd_word;
    wire [24:0] gap;
    wire [7:0] step_seq;
    wire dbg_exec, fetch_start, idle, dbg_mreq, dbg_mgnt, dbg_preq, dbg_pready;
    wire [14:0] dbg_maddr, dbg_paddr, next_pc, dbg_pc, pm_addr;
    wire [15:0] dbg_mdata, dbg_pdata, dbg_a, dbg_d, dbg_instr, pm_data, vdata;
    wire pm_req, pm_ready, clearing, dbg_we;
    wire [14:0] dbg_waddr;
    wire [15:0] dbg_wdata;

    // reset_cpu is ORed into the CPU reset, as in the system
    wire cpu_reset = init | hold | reset_cpu;

    debug_unit dut (
        .clk(clk), .rst(rst), .go_run(go_run),
        .cmd(cmd), .cmd_op(cmd_op), .cmd_seq(cmd_seq), .cmd_gap(cmd_gap), .cmd_done(cmd_done),
        .rd(rd), .rd_rom(rd_rom), .rd_addr(rd_addr), .rd_count(rd_count),
        .rd_word_valid(rd_word_valid), .rd_word(rd_word), .rd_end(rd_end),
        .rd_refused(rd_refused),
        .paused(paused), .gap(gap), .step_seq(step_seq), .reset_cpu(reset_cpu),
        .cpu_hold(cpu_reset), .exec(dbg_exec), .fetch_start(fetch_start), .idle(idle),
        .fetch_en(fetch_en),
        .dbg_mreq(dbg_mreq), .dbg_maddr(dbg_maddr), .dbg_mgnt(dbg_mgnt), .dbg_mdata(dbg_mdata),
        .dbg_preq(dbg_preq), .dbg_paddr(dbg_paddr), .dbg_pready(dbg_pready),
        .dbg_pdata(dbg_pdata)
    );

    hack_computer u_comp (
        .clk(clk), .reset(cpu_reset), .clear(1'b0), .clearing(clearing),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(16'd0), .vclk(vclk), .vaddr(13'd0), .vdata(vdata),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_d(dbg_d), .dbg_instr(dbg_instr),
        .dbg_exec(dbg_exec), .dbg_we(dbg_we), .dbg_waddr(dbg_waddr), .dbg_wdata(dbg_wdata),
        .fetch_en(fetch_en),
        .dbg_mreq(dbg_mreq), .dbg_maddr(dbg_maddr), .dbg_mgnt(dbg_mgnt), .dbg_mdata(dbg_mdata),
        .dbg_preq(dbg_preq), .dbg_paddr(dbg_paddr), .dbg_pready(dbg_pready),
        .dbg_pdata(dbg_pdata),
        .fetch_start(fetch_start), .idle(idle), .next_pc(next_pc)
    );

    progmem_sim #(.LATENCY(`PM_LATENCY)) pm (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
    );

    always #5 clk = ~clk;
    always #6 vclk = ~vclk;

    localparam MAX_ITEMS = 1024;
    integer it_kind [0:MAX_ITEMS-1], it_at [0:MAX_ITEMS-1];
    integer it_a [0:MAX_ITEMS-1], it_b [0:MAX_ITEMS-1], it_c [0:MAX_ITEMS-1];
    integer total, rom_words, n_items = 0, item = 0, cycles = 0, executed = 0;
    integer trace_fd, fd, j, n_rd = -1, words = 0, wait_until = 0, last_op = 0;
    reg busy = 0, ready = 0;
    reg s_exec, s_fs, s_done, s_valid, s_end, s_ref, s_idle, s_paused;
    reg s_mgnt, s_mreq, s_pready, s_preq;
    reg [15:0] s_word;
    reg [14:0] s_npc, pc_before;
    reg [24:0] s_gap;
    reg [7:0] s_seq;

    initial begin
        if (!$value$plusargs("CYCLES=%d", total)) total = 1000;
        if (!$value$plusargs("ROM_WORDS=%d", rom_words)) rom_words = 0;
        if ($value$plusargs("ITEMS=%d", n_items)) begin
            fd = $fopen("items.txt", "r");
            for (j = 0; j < n_items; j = j + 1)
                if ($fscanf(fd, "%d %d %d %d %d", it_kind[j], it_at[j], it_a[j], it_b[j],
                            it_c[j]) != 5)
                    $display("FAIL items.txt line %0d", j);
            $fclose(fd);
        end
        if (rom_words > 0) $readmemh("rom.hex", pm.mem, 0, rom_words - 1);
        trace_fd = $fopen("trace.txt", "w");
        repeat (3) @(posedge clk);
        #1;
        rst = 0;
        init = 0;
    end

    // Values from before the edge are sampled first; the rest runs 1 ns after it
    always @(posedge clk) begin
        cycles = cycles + 1;
        s_exec = dbg_exec;
        s_fs = fetch_start;
        s_done = cmd_done;
        s_valid = rd_word_valid;
        s_word = rd_word;
        s_end = rd_end;
        s_ref = rd_refused;
        s_idle = idle;
        s_npc = next_pc;
        s_paused = paused;
        s_gap = gap;
        s_seq = step_seq;
        s_mgnt = dbg_mgnt;
        s_mreq = dbg_mreq;
        s_pready = dbg_pready;
        s_preq = dbg_preq;
        pc_before = dbg_pc;
        if (s_mgnt && !(s_idle && s_mreq)) $display("FAIL dbg_mgnt at cycle %0d", cycles);
        if (s_pready && !s_preq) $display("FAIL dbg_pready at cycle %0d", cycles);
        if (s_fs) $display("START %0d", cycles);
        if (s_done) begin
            if (!busy || last_op < 0) $display("FAIL cmd_done unasked %0d", cycles);
            $display("DONE %0d %0d %0d %0d %0d %0d %0d %0d", last_op, cycles, executed, s_npc,
                     s_paused, s_seq, s_gap, s_idle);
            busy = 0;
        end
        if (s_valid) begin
            $display("WORD %0d %04x", n_rd, s_word);
            words = words + 1;
        end
        if (s_end) begin
            $display("END %0d %0d %0d %0d", n_rd, s_ref, cycles, executed);
            busy = 0;
        end
        #1;
        if (s_exec) begin
            $fdisplay(trace_fd, "%04x %04x %04x", pc_before, dbg_a, dbg_d);
            executed = executed + 1;
        end
        cmd = 0;
        rd = 0;
        ready = 1;
        while (ready && item < n_items && cycles >= it_at[item]) begin
            case (it_kind[item])
                0, 1, 2: ready = !busy;
                5: ready = words >= it_a[item];
                6: begin
                    if (wait_until == 0) wait_until = cycles + it_a[item];
                    ready = cycles >= wait_until;
                end
                default: ready = 1;
            endcase
            if (ready) begin
                take(item);
                item = item + 1;
            end
        end
        if (cycles >= total) begin
            $display("FINAL %0d %0d %0d %0d %0d %0d %0d %0d", cycles, executed, next_pc, paused,
                     gap, step_seq, n_items - item, busy);
            $fclose(trace_fd);
            $finish;
        end
    end

    // The command or read goes out for the cycle after this edge
    task take(input integer k);
        begin
            case (it_kind[k])
                0: begin
                    cmd = 1;
                    cmd_op = it_a[k];
                    cmd_seq = it_b[k];
                    cmd_gap = it_c[k];
                    last_op = it_a[k];
                    busy = 1;
                    $display("CMD %0d %0d %0d", it_a[k], it_b[k], cycles + 1);
                end
                1, 2: begin
                    rd = 1;
                    rd_rom = it_kind[k] == 2;
                    rd_addr = it_a[k];
                    rd_count = it_b[k];
                    n_rd = n_rd + 1;
                    words = 0;
                    last_op = -1;
                    busy = 1;
                    $display("RD %0d %0d %0d %0d %0d %0d", n_rd, it_kind[k] == 2, it_a[k],
                             it_b[k], cycles + 1, executed);
                end
                3: hold = it_a[k] != 0;
                4: go_run = it_a[k] != 0;
                6: wait_until = 0;
                default: ;
            endcase
        end
    endtask
endmodule
