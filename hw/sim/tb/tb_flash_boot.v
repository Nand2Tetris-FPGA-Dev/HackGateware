`timescale 1ns / 1ps

// flash_boot_system with spi_flash_model (flash.hex, slot 0) and
// psram_host_model, or with REAL_CTRL psram_ctrl + the W955D8MBYA chip model.
// Runs until +STEPS instructions, or 20000 cycles after a loader error.
// +PRESS=1 or 2 holds S1 or S2 for PRESS_LEN cycles. It goes down PRESS_DELAY
// cycles after instruction PRESS_AT, or with WAIT_FOR=1 after the next PSRAM
// read is taken, with WAIT_FOR=2 after the next load is taken, or with
// WAIT_FOR=3 in the next cycle with no PSRAM request out. For S2, flash2.hex
// replaces the flash contents first.
// trace.txt gets "pc instr a d" per instruction and "reset" each time the
// CPU goes into reset. Prints "STATE n" when boot_state changes and a
// RESULT line (name in decimal).
module tb_flash_boot;
    localparam real HALF_NS = 500_000_000.0 / 27_000_000;

    reg clk = 0, vclk = 0, por_n = 0, s1 = 0, s2 = 0;
    wire flash_clk, flash_cs_n, flash_mosi, flash_miso;
    wire req_valid, req_ready, req_we, rsp_valid, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;
    wire [15:0] vdata;
    wire busy, running, err_header, err_crc;
    wire [2:0] boot_state;
    wire [127:0] prog_name;
    wire [15:0] prog_words, dbg_instr, dbg_a, dbg_d, sp, sp_max;
    wire [14:0] dbg_pc, heap_hi;

    flash_boot_system dut (
        .clk(clk), .por_n(por_n), .s1(s1), .s2(s2), .keyboard(16'd0),
        .flash_clk(flash_clk), .flash_cs_n(flash_cs_n),
        .flash_mosi(flash_mosi), .flash_miso(flash_miso),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .vclk(vclk), .vaddr(13'd0), .vdata(vdata),
        .busy(busy), .running(running), .err_header(err_header), .err_crc(err_crc),
        .boot_state(boot_state), .prog_name(prog_name), .prog_words(prog_words),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_a(dbg_a), .dbg_d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(flash_cs_n), .clk(flash_clk), .mosi(flash_mosi), .miso(flash_miso)
    );

`ifdef REAL_CTRL
    wire [1:0] ck, ck_n, cs_n, reset_n, rwds;
    wire [15:0] dq;

    psram_ctrl #(.CLK_HZ(27_000_000)) mem (
        .clk(clk), .rst_n(por_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n),
        .O_psram_reset_n(reset_n), .IO_psram_dq(dq), .IO_psram_rwds(rwds)
    );

    w955d8mbya_model psram (
        .ck(ck), .ck_n(ck_n), .cs_n(cs_n), .reset_n(reset_n), .dq(dq), .rwds(rwds)
    );
`define MODEL_ERRORS psram.error_count
`else
    psram_host_model mem (
        .clk(clk), .rst_n(por_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done)
    );
`define MODEL_ERRORS 0
`endif

    always #(HALF_NS) clk = ~clk;
    always #20 vclk = ~vclk;

    integer steps, limit, press = 0, press_at = 0, wait_for = 0, press_delay = 0, press_len = 2;
    integer executed = 0, cycles = 0, fetches = 0, loads = 0, errors = 0, err_at = -1;
    integer trace_fd, fd, i;
    reg was_reset = 1, pressed = 0;
    reg [2:0] last_state = 3'bx;
    reg [14:0] pc_before;
    reg [15:0] instr;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (dut.computer.pm_req) fetches = fetches + 1;
        if (dut.load_valid && dut.load_ready) loads = loads + 1;
        if (dut.computer.pm_req && busy) begin
            $display("FAIL fetch while loading at %0d", cycles);
            errors = errors + 1;
        end
        // done drops a cycle after s2, so check from the second cycle of a press
        if (pressed && (s1 || s2) && running) begin
            $display("FAIL running while a button is held at %0d", cycles);
            errors = errors + 1;
        end
        pressed = s1 || s2;
        if (dut.cpu_reset && !was_reset) $fdisplay(trace_fd, "reset");
        was_reset = dut.cpu_reset;
        if ((err_header || err_crc) && err_at < 0) err_at = cycles;
        if (err_at >= 0 && cycles == err_at + 20000) finish_run;
        if (cycles > limit) begin
            $display("TIMEOUT after %0d instructions", executed);
            $finish;
        end
        // psram_ctrl's state is x until por_n has reset it
        if (por_n && boot_state !== last_state) begin
            $display("STATE %0d", boot_state);
            last_state = boot_state;
        end
        if (dut.computer.dbg_exec) begin
            pc_before = dbg_pc;
            instr = dbg_instr;
            #1;
            $fdisplay(trace_fd, "%04x %04x %04x %04x", pc_before, instr, dbg_a, dbg_d);
            executed = executed + 1;
            if (executed == steps) finish_run;
        end
    end

    initial begin
        if (!$value$plusargs("STEPS=%d", steps)) steps = 0;
        if (!$value$plusargs("LIMIT=%d", limit)) limit = 1_000_000;
        if (!$value$plusargs("PRESS=%d", press)) press = 0;
        if (!$value$plusargs("PRESS_AT=%d", press_at)) press_at = 0;
        if (!$value$plusargs("WAIT_FOR=%d", wait_for)) wait_for = 0;
        if (!$value$plusargs("PRESS_DELAY=%d", press_delay)) press_delay = 0;
        if (!$value$plusargs("PRESS_LEN=%d", press_len)) press_len = 2;
        trace_fd = $fopen("trace.txt", "w");
        repeat (4) @(posedge clk);
        #1 por_n = 1;
        if (press != 0) begin
            while (executed < press_at) @(posedge clk);
            if (wait_for == 1) begin
                @(posedge clk);
                while (!(req_valid && req_ready && !req_we)) @(posedge clk);
            end
            if (wait_for == 2) begin
                @(posedge clk);
                while (!(dut.load_valid && dut.load_ready)) @(posedge clk);
            end
            if (wait_for == 3) begin
                @(posedge clk);
                #1;
                while (dut.pm.busy) begin
                    @(posedge clk);
                    #1;
                end
            end
            repeat (press_delay) @(posedge clk);
            if (press == 2) $readmemh("flash2.hex", flash.mem);
            #1 s1 = press == 1;
            s2 = press == 2;
            $display("PRESS cycle=%0d read_in_flight=%0d", cycles, dut.pm.busy && !dut.pm.busy_we);
            repeat (press_len) @(posedge clk);
            #1 $display("RELEASE sp=%0d sp_max=%0d heap_hi=%0d", sp, sp_max, heap_hi);
            s1 = 0;
            s2 = 0;
        end
    end

    task finish_run;
        begin
            $fclose(trace_fd);
            fd = $fopen("ram.txt", "w");
            for (i = 0; i < 16384; i = i + 1) $fdisplay(fd, "%04x", dut.computer.u_mem.u_ram.mem[i]);
            $fclose(fd);
            fd = $fopen("screen.txt", "w");
            for (i = 0; i < 8192; i = i + 1) $fdisplay(fd, "%04x", dut.computer.u_mem.u_screen.mem[i]);
            $fclose(fd);
            $display("RESULT running=%0d busy=%0d err_header=%0d err_crc=%0d executed=%0d ",
                     running, busy, err_header, err_crc, executed,
                     "fetches=%0d loads=%0d errors=%0d model_errors=%0d words=%0d ",
                     fetches, loads, errors, `MODEL_ERRORS, prog_words,
                     "name=%0d sp=%0d sp_max=%0d heap_hi=%0d", prog_name, sp, sp_max, heap_hi);
            $finish;
        end
    endtask
endmodule
