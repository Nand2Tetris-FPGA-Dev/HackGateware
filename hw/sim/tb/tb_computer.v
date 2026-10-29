`timescale 1ns / 1ps

`ifndef PM_LATENCY
`define PM_LATENCY 1
`endif

// Runs a program from rom.hex for +STEPS instructions. Writes one trace line
// per instruction (pc before, A after, D after) and dumps RAM and screen.
module tb_computer;
    reg clk = 0, vclk = 0, reset = 1;
    reg [15:0] keyboard = 0;
    wire pm_req, pm_ready, dbg_exec;
    wire [14:0] pm_addr, dbg_pc;
    wire [15:0] pm_data, vdata, dbg_a, dbg_d, dbg_instr;

    hack_computer dut (
        .clk(clk), .reset(reset),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(keyboard), .vclk(vclk), .vaddr(13'd0), .vdata(vdata),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_d(dbg_d), .dbg_instr(dbg_instr),
        .dbg_exec(dbg_exec)
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
    wire load_ready, req_valid, req_ready, req_we, rsp_valid, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;
    reg [15:0] image [0:32767];

    progmem_psram pm (
        .clk(clk), .rst_n(1'b1),
        .fetch_req(pm_req), .fetch_addr(pm_addr), .fetch_ready(pm_ready), .fetch_data(pm_data),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
    );

    psram_host_model psram (
        .clk(clk), .rst_n(1'b1),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done)
    );
`else
    progmem_sim #(.LATENCY(`PM_LATENCY)) pm (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
    );
`endif

`ifdef USE_PSRAM_MODEL
    localparam STEP_CYCLES = 45;  // worst case: a line miss every instruction
`else
    localparam STEP_CYCLES = `PM_LATENCY + 4;
`endif

    always #5 clk = ~clk;
    always #6 vclk = ~vclk;

    integer steps, rom_words, kbd_at = -1, kbd_val = 0, reset_at = -1;
    integer reset_delay = 0, reset_len = 2;
    integer executed = 0, cycles = 0, load_cycles = 0, trace_fd = 0, fd, i;
    reg loaded = 0;
    reg [14:0] pc_before;

    initial begin
        if (!$value$plusargs("STEPS=%d", steps)) steps = 0;
        if (!$value$plusargs("ROM_WORDS=%d", rom_words)) rom_words = 0;
        if (!$value$plusargs("KBD_AT=%d", kbd_at)) kbd_at = -1;
        if (!$value$plusargs("KBD_VAL=%d", kbd_val)) kbd_val = 0;
        if (!$value$plusargs("RESET_AT=%d", reset_at)) reset_at = -1;
        if (!$value$plusargs("RESET_DELAY=%d", reset_delay)) reset_delay = 0;
        if (!$value$plusargs("RESET_LEN=%d", reset_len)) reset_len = 2;
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

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (loaded ? cycles > load_cycles + steps * STEP_CYCLES + 1000
                   : cycles > rom_words * 40 + 1000) begin
            $display("TIMEOUT after %0d instructions", executed);
            $finish;
        end
        if (dbg_exec) begin
            pc_before = dbg_pc;
            #1;
            if (trace_fd) $fdisplay(trace_fd, "%04x %04x %04x", pc_before, dbg_a, dbg_d);
            executed = executed + 1;
            if (executed == kbd_at) keyboard = kbd_val;
            // Reset RESET_DELAY cycles after this instruction, for RESET_LEN cycles,
            // so a test can land it in the fetch or execute phase
            if (executed == reset_at) begin
                repeat (reset_delay) @(posedge clk);
                #1 reset = 1;
                repeat (reset_len) @(posedge clk);
                #1 reset = 0;
            end
            if (executed == steps) finish_run;
        end
    end

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
