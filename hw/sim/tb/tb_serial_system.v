`timescale 1ns / 1ps

// flash_boot_system (spi_flash_model with flash.hex, psram_host_model) with
// serial_link on its keyboard input, wired as in top_tangnano9k_hdmi.
// Once the CPU runs, rx.txt is bit-banged into uart_rx as in tb_serial_link
// ("<idle_bits> <hex byte>" per line); prints SENT per byte and END after the
// last. +PRESS_AT=n holds S1 for 3 cycles from n cycles after END.
// Prints W per CPU RAM write, KBD on each keyboard change and TX per reply
// byte, all with the cycle count, and "reset" when the CPU goes into reset.
// trace.txt gets "pc instr a d" per instruction. +TAIL: cycles to run after
// END; +STEPS=n stops after n instructions instead.
`ifndef CLKS_PER_BIT
`define CLKS_PER_BIT 9
`endif
`ifndef WATCHDOG
`define WATCHDOG 100000
`endif
module tb_serial_system;
    localparam real HALF_NS = 500_000_000.0 / 27_000_000;
    localparam CPB = `CLKS_PER_BIT;

    reg clk = 0, vclk = 0, por_n = 0, s1 = 0, rx = 1;
    wire flash_clk, flash_cs_n, flash_mosi, flash_miso;
    wire req_valid, req_ready, req_we, rsp_valid, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;
    wire [15:0] vdata, keyboard;
    wire busy, running, err_header, err_crc, tx;
    wire [2:0] boot_state;
    wire [127:0] prog_name;
    wire [15:0] prog_words, dbg_instr, dbg_a, dbg_d, sp, sp_max;
    wire [14:0] dbg_pc, heap_hi;

    flash_boot_system dut (
        .clk(clk), .por_n(por_n), .s1(s1), .s2(1'b0), .keyboard(keyboard),
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

    serial_link #(.CLKS_PER_BIT(CPB), .WATCHDOG_CYCLES(`WATCHDOG)) link (
        .clk(clk), .rst(~por_n), .uart_rx(rx), .uart_tx(tx), .keyboard(keyboard),
        .boot_state(boot_state), .pc(dbg_pc), .instr(dbg_instr), .a(dbg_a), .d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi), .prog_words(prog_words),
        .prog_name(prog_name)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(flash_cs_n), .clk(flash_clk), .mosi(flash_mosi), .miso(flash_miso)
    );

    psram_host_model mem (
        .clk(clk), .rst_n(por_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done)
    );

    wire [7:0] tx_byte;
    wire tx_valid, tx_err;
    uart_rx #(.CLKS_PER_BIT(CPB)) mon (
        .clk(clk), .rst(~por_n), .rx(tx), .data(tx_byte), .valid(tx_valid), .frame_err(tx_err)
    );

    always #(HALF_NS) clk = ~clk;
    always #20 vclk = ~vclk;

    integer cycle = 0, executed = 0, steps, trace_fd;
    reg was_reset = 1;
    reg [14:0] pc_before;
    reg [15:0] instr;
    reg [15:0] kbd_seen = 0;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (tx_valid) $display("TX %02x %0d", tx_byte, cycle);
        if (tx_err) $display("TXERR %0d", cycle);
        if (dut.dbg_we) $display("W %0d %0d %04x", cycle, dut.dbg_waddr, dut.dbg_wdata);
        if (dut.cpu_reset && !was_reset) begin
            $display("reset %0d", cycle);
            $fdisplay(trace_fd, "reset");
        end
        was_reset = dut.cpu_reset;
        if (dut.computer.dbg_exec) begin
            pc_before = dbg_pc;
            instr = dbg_instr;
            #1;
            $fdisplay(trace_fd, "%04x %04x %04x %04x", pc_before, instr, dbg_a, dbg_d);
            executed = executed + 1;
            if (executed == steps) begin
                $display("DONE");
                $finish;
            end
        end
    end

    always @(negedge clk)
        if (por_n && keyboard !== kbd_seen) begin
            $display("KBD %0d %02x", cycle, keyboard);
            kbd_seen = keyboard;
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

    integer fd, n, idle, b, tail, press_at;
    reg [8*16-1:0] line;

    initial begin
        if (!$value$plusargs("STEPS=%d", steps)) steps = -1;
        if (!$value$plusargs("TAIL=%d", tail)) tail = 5000;
        if (!$value$plusargs("PRESS_AT=%d", press_at)) press_at = -1;
        trace_fd = $fopen("trace.txt", "w");
        repeat (4) @(posedge clk);
        #1 por_n = 1;
        wait (running);
        repeat (4 * CPB) @(negedge clk);
        fd = $fopen("rx.txt", "r");
        while ($fgets(line, fd)) begin
            n = $sscanf(line, "%d %h", idle, b);
            repeat (idle * CPB) @(negedge clk);
            send_byte(b);
            $display("SENT %0d", cycle);
        end
        $display("END %0d", cycle);
        if (press_at >= 0) begin
            repeat (press_at) @(negedge clk);
            $display("PRESS %0d", cycle);
            s1 = 1;
            repeat (3) @(negedge clk);
            s1 = 0;
        end
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
