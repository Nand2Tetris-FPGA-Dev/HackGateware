`timescale 1ns / 1ps

`ifndef PM_LATENCY
`define PM_LATENCY 1
`endif

// Runs a program from rom.hex for +STEPS instructions. Writes one trace line
// per instruction (pc before, A after, D after) and dumps RAM and screen.
// +CLEAR pulses clear after the last instruction (reset stays low) and prints
// "CLEARED n" with the cycles until clearing drops.
//
// +DEBUG_ITEMS=n reads n lines of "kind at a b" from debug.txt, sorted by at:
// kind 0 holds fetch_en low for a cycles after instruction at; 1 and 2 queue a
// RAM or ROM read of b words from a. Reads run one at a time in queue order and
// print "READ n m|p at addr word" per word. +GAP=n keeps fetch_starts n cycles
// apart and prints "START cycle" for each.
module tb_computer;
    reg clk = 0, vclk = 0, reset = 1, clear = 0;
    wire clearing;
    reg [15:0] keyboard = 0;
    wire pm_req, pm_ready, dbg_exec;
    wire [14:0] pm_addr, dbg_pc;
    wire [15:0] pm_data, vdata, dbg_a, dbg_d, dbg_instr;
    reg fetch_en = 1, dbg_mreq = 0, dbg_preq = 0;
    reg [14:0] dbg_maddr = 0, dbg_paddr = 0;
    wire dbg_mgnt, dbg_pready, fetch_start, idle;
    wire [15:0] dbg_mdata, dbg_pdata;
    wire [14:0] next_pc;

    hack_computer dut (
        .clk(clk), .reset(reset), .clear(clear), .clearing(clearing),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(keyboard), .vclk(vclk), .vaddr(13'd0), .vdata(vdata),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_d(dbg_d), .dbg_instr(dbg_instr),
        .dbg_exec(dbg_exec),
        .fetch_en(fetch_en),
        .dbg_mreq(dbg_mreq), .dbg_maddr(dbg_maddr), .dbg_mgnt(dbg_mgnt), .dbg_mdata(dbg_mdata),
        .dbg_preq(dbg_preq), .dbg_paddr(dbg_paddr), .dbg_pready(dbg_pready),
        .dbg_pdata(dbg_pdata),
        .fetch_start(fetch_start), .idle(idle), .next_pc(next_pc)
    );

`ifdef PROGMEM_ROM
    // The board's ROM; it loads rom.hex itself through ROM_HEX
    progmem_rom #(.WORDS(2048)) pm (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
    );
`elsif USE_PSRAM_MODEL
    // The CPU stays in reset while rom.hex goes in through the load port
    reg load_valid = 0;
    reg [14:0] load_addr = 0;
    reg [31:0] load_data = 0;
    reg [3:0] load_strb = 0;
    wire load_ready, req_valid, req_ready, req_we, req_burst, rsp_valid, rsp_word, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;
    reg [15:0] image [0:32767];

    progmem_psram pm (
        .clk(clk), .rst_n(1'b1),
        .fetch_req(pm_req), .fetch_addr(pm_addr), .fetch_ready(pm_ready), .fetch_data(pm_data),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_burst(req_burst),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_word(rsp_word), .rsp_rdata(rsp_rdata)
    );

    psram_host_model psram (
        .clk(clk), .rst_n(1'b1),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_burst(req_burst),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_word(rsp_word), .rsp_rdata(rsp_rdata), .init_done(init_done)
    );
`else
    progmem_sim #(.LATENCY(`PM_LATENCY)) pm (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
    );
`endif

`ifdef USE_PSRAM_MODEL
    localparam STEP_CYCLES = 110;  // worst case: a miss behind a burst, 65 + 33 + 3
`else
    localparam STEP_CYCLES = `PM_LATENCY + 4;
`endif

    always #5 clk = ~clk;
    always #6 vclk = ~vclk;

    integer steps, rom_words, kbd_at = -1, kbd_val = 0, reset_at = -1;
    integer reset_delay = 0, reset_len = 2;
    integer executed = 0, cycles = 0, load_cycles = 0, trace_fd = 0, fd, i;
    reg loaded = 0, stopping = 0;
    reg [14:0] pc_before;

    localparam MAX_ITEMS = 8192;
    integer it_kind [0:MAX_ITEMS-1], it_at [0:MAX_ITEMS-1];
    integer it_a [0:MAX_ITEMS-1], it_b [0:MAX_ITEMS-1];
    integer n_items = 0, item = 0, gap = 0, extra = 0, since = 1 << 30, pause_left = 0;
    integer rd_item = 0, rd_n = 0, rd_left = 0, pend_n, pend_at, pend_addr, dfd, j;
    reg rd_active = 0, m_pend = 0;
    reg s_exec, s_fs, s_idle, s_mgnt, s_pready;
    reg [15:0] s_mdata, s_pdata;

    initial begin
        if (!$value$plusargs("STEPS=%d", steps)) steps = 0;
        if (!$value$plusargs("ROM_WORDS=%d", rom_words)) rom_words = 0;
        if (!$value$plusargs("KBD_AT=%d", kbd_at)) kbd_at = -1;
        if (!$value$plusargs("KBD_VAL=%d", kbd_val)) kbd_val = 0;
        if (!$value$plusargs("RESET_AT=%d", reset_at)) reset_at = -1;
        if (!$value$plusargs("RESET_DELAY=%d", reset_delay)) reset_delay = 0;
        if (!$value$plusargs("RESET_LEN=%d", reset_len)) reset_len = 2;
        if (!$value$plusargs("GAP=%d", gap)) gap = 0;
        if (!$value$plusargs("EXTRA_CYCLES=%d", extra)) extra = 0;
        if ($value$plusargs("DEBUG_ITEMS=%d", n_items)) begin
            dfd = $fopen("debug.txt", "r");
            for (j = 0; j < n_items; j = j + 1)
                if ($fscanf(dfd, "%d %d %d %d", it_kind[j], it_at[j], it_a[j], it_b[j]) != 4)
                    $display("FAIL debug.txt line %0d", j);
            $fclose(dfd);
        end
`ifdef USE_PSRAM_MODEL
        if (rom_words > 0) $readmemh("rom.hex", image, 0, rom_words - 1);
`elsif PROGMEM_ROM
`else
        if (rom_words > 0) $readmemh("rom.hex", pm.mem, 0, rom_words - 1);
`endif
        if ($test$plusargs("RAMINIT")) $readmemh("ram_init.hex", dut.u_mem.u_ram.mem);
        if ($test$plusargs("TRACE")) trace_fd = $fopen("trace.txt", "w");
        if (kbd_at == 0) keyboard = kbd_val;
        repeat (2) @(posedge clk);
`ifdef USE_PSRAM_MODEL
        // Two words per load like boot_loader, strobe 0011 for an odd last word
        #1;
        for (i = 0; i < rom_words; i = i + 2) begin
            load_valid = 1;
            load_addr = i;
            load_data = i + 1 < rom_words ? {image[i + 1], image[i]} : {16'd0, image[i]};
            load_strb = i + 1 < rom_words ? 4'b1111 : 4'b0011;
            while (!load_ready) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            #1 load_valid = 0;
        end
        load_cycles = cycles;
        loaded = 1;
`else
        loaded = 1;
`endif
        #1 reset = 0;
    end

    // Reset RESET_DELAY cycles after instruction RESET_AT, for RESET_LEN cycles, so
    // a test can land it in the fetch or execute phase. Its own process, so
    // instructions run during the delay are still traced; RESET executed= is how
    // many ran before the reset.
    event reset_go;
    always @(reset_go) begin
        repeat (reset_delay) @(posedge clk);
        #1 reset = 1;
`ifdef USE_PSRAM_MODEL
        #1 $display("RESET executed=%0d read_in_flight=%0d", executed, pm.busy && !pm.busy_we);
`else
        #1 $display("RESET executed=%0d", executed);
`endif
        repeat (reset_len) @(posedge clk);
        #1 reset = 0;
    end

    // Values from before the edge are sampled first; the rest runs 1 ns after it
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (loaded ? cycles > load_cycles + steps * STEP_CYCLES + extra + 1000
                   : cycles > rom_words * 40 + 1000) begin
            $display("TIMEOUT after %0d instructions", executed);
            $finish;
        end
        s_exec = dbg_exec;
        s_fs = fetch_start;
        s_idle = idle;
        s_mgnt = dbg_mgnt;
        s_pready = dbg_pready;
        s_mdata = dbg_mdata;
        s_pdata = dbg_pdata;
        pc_before = dbg_pc;
        if (s_mgnt && !(s_idle && dbg_mreq)) $display("FAIL dbg_mgnt at cycle %0d", cycles);
        if (s_pready && !dbg_preq) $display("FAIL dbg_pready at cycle %0d", cycles);
        if (s_fs && gap > 0) $display("START %0d", cycles);
        #1;
        if (s_exec) begin
            if (trace_fd) $fdisplay(trace_fd, "%04x %04x %04x", pc_before, dbg_a, dbg_d);
            executed = executed + 1;
            if (executed == kbd_at) keyboard = kbd_val;
            if (executed == reset_at) -> reset_go;
            if (executed == steps) stopping = 1;
            for (; item < n_items && it_at[item] <= executed; item = item + 1)
                if (it_kind[item] == 0 && it_at[item] == executed && it_a[item] >= pause_left)
                    pause_left = it_a[item] + 1;
        end
        read_step;
        if (pause_left > 0) pause_left = pause_left - 1;
        since = s_fs ? 1 : since < (1 << 30) ? since + 1 : since;
        fetch_en = !stopping && pause_left == 0 && since >= gap;
        if (stopping && !rd_active && !m_pend) begin
            if ($test$plusargs("CLEAR")) clear_run;
            else finish_run;
        end
    end

    // A granted RAM word is in dbg_mdata the cycle after the grant
    task read_step;
        begin
            if (m_pend) $display("READ %0d m %0d %0d %04x", pend_n, pend_at, pend_addr, s_mdata);
            m_pend = s_mgnt;
            if (s_mgnt) begin
                {pend_n, pend_at, pend_addr} = {rd_n, it_at[rd_item], it_a[rd_item]};
                dbg_maddr = dbg_maddr + 1'b1;
            end
            if (s_pready) begin
                $display("READ %0d p %0d %0d %04x", rd_n, it_at[rd_item], it_a[rd_item], s_pdata);
                dbg_paddr = dbg_paddr + 1'b1;
            end
            if (s_mgnt || s_pready) rd_left = rd_left - 1;
            if (rd_active && rd_left == 0) begin
                rd_active = 0;
                rd_item = rd_item + 1;
                rd_n = rd_n + 1;
            end
            while (rd_item < n_items && it_kind[rd_item] == 0) rd_item = rd_item + 1;
            if (!rd_active && rd_item < n_items && it_at[rd_item] <= executed) begin
                rd_active = 1;
                rd_left = it_b[rd_item];
                if (it_kind[rd_item] == 1) dbg_maddr = it_a[rd_item];
                else dbg_paddr = it_a[rd_item];
            end
            dbg_mreq = rd_active && it_kind[rd_item] == 1;
            dbg_preq = rd_active && it_kind[rd_item] == 2;
        end
    endtask

    task clear_run;
        integer n;
        begin
            @(negedge clk) clear = 1;
            @(negedge clk) clear = 0;
            n = 1;
            while (clearing) begin
                if (dbg_exec || pm_req) $display("FAIL CPU active while clearing");
                @(negedge clk);
                n = n + 1;
            end
            $display("CLEARED %0d", n);
            finish_run;
        end
    endtask

    task finish_run;
        begin
            if (trace_fd) $fclose(trace_fd);
            fd = $fopen("ram.txt", "w");
            for (i = 0; i < 16384; i = i + 1) $fdisplay(fd, "%04x", dut.u_mem.u_ram.mem[i]);
            $fclose(fd);
            fd = $fopen("screen.txt", "w");
            for (i = 0; i < 8192; i = i + 1) $fdisplay(fd, "%04x", dut.u_mem.u_screen.mem[i]);
            $fclose(fd);
            $display("DONE %0d instructions in %0d cycles", executed, cycles - load_cycles);
            $finish;
        end
    endtask
endmodule
