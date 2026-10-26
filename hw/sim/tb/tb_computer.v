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
`else
    progmem_sim #(.LATENCY(`PM_LATENCY)) pm (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
    );
`endif

    always #5 clk = ~clk;
    always #6 vclk = ~vclk;

    integer steps, rom_words, kbd_at = -1, kbd_val = 0, reset_at = -1;
    integer executed = 0, cycles = 0, trace_fd = 0, fd, i;
    reg [14:0] pc_before;

    initial begin
        if (!$value$plusargs("STEPS=%d", steps)) steps = 0;
        if (!$value$plusargs("ROM_WORDS=%d", rom_words)) rom_words = 0;
        if (!$value$plusargs("KBD_AT=%d", kbd_at)) kbd_at = -1;
        if (!$value$plusargs("KBD_VAL=%d", kbd_val)) kbd_val = 0;
        if (!$value$plusargs("RESET_AT=%d", reset_at)) reset_at = -1;
`ifndef PROGMEM_ROM
        if (rom_words > 0) $readmemh("rom.hex", pm.mem, 0, rom_words - 1);
`endif
        if ($test$plusargs("RAMINIT")) $readmemh("ram_init.hex", dut.u_mem.u_ram.mem);
        if ($test$plusargs("TRACE")) trace_fd = $fopen("trace.txt", "w");
        if (kbd_at == 0) keyboard = kbd_val;
        repeat (2) @(posedge clk);
        #1 reset = 0;
    end

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > steps * (`PM_LATENCY + 4) + 1000) begin
            $display("TIMEOUT after %0d instructions", executed);
            $finish;
        end
        if (dbg_exec) begin
            pc_before = dbg_pc;
            #1;
            if (trace_fd) $fdisplay(trace_fd, "%04x %04x %04x", pc_before, dbg_a, dbg_d);
            executed = executed + 1;
            if (executed == kbd_at) keyboard = kbd_val;
            if (executed == reset_at) begin
                reset = 1;
                repeat (2) @(posedge clk);
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
            $display("DONE %0d instructions in %0d cycles", executed, cycles);
            $finish;
        end
    endtask
endmodule
