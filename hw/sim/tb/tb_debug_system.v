`timescale 1ns / 1ps

// The hdmi build's debug screen path: flash_boot_system (spi_flash_model with
// flash.hex, psram_host_model) feeding debug_screen, st7789_driver (short
// delays) and st7789_model, wired as in top_tangnano9k_hdmi.
// +FRAMES=n stops after n frames; frame k is saved as frame<k>.hex.
// +S1_FRAME=k holds S1 from 1000 cycles after frame k-1 starts until 100
// cycles after frame k starts, so frame k's snapshot is taken in reset.
// trace.txt gets "pc instr a d" per instruction and "reset" each time the
// CPU goes into reset. Prints ERRORS (the panel model's count).
module tb_debug_system;
    localparam real HALF_NS = 500_000_000.0 / 27_000_000;

    reg clk = 0, vclk = 0, por_n = 0, s1 = 0;
    wire por = ~por_n;
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
        .clk(clk), .por_n(por_n), .s1(s1), .s2(1'b0), .keyboard(16'd0),
        .flash_clk(flash_clk), .flash_cs_n(flash_cs_n),
        .flash_mosi(flash_mosi), .flash_miso(flash_miso),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .vclk(vclk), .vaddr(13'd0), .vdata(vdata),
        .busy(busy), .running(running), .err_header(err_header), .err_crc(err_crc),
        .boot_state(boot_state), .prog_name(prog_name), .prog_words(prog_words),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_a(dbg_a), .dbg_d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi),
        // no flash requests here
        .fl_req(1'b0), .fl_op(3'd0), .fl_addr(24'd0), .fl_len(24'd0),
        .pb_we(1'b0), .pb_addr(8'd0), .pb_data(8'd0),
        .fl_busy(), .fl_rsp(), .fl_status(), .fl_crc()
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

    wire frame_start, frame_ready, pix_req;
    wire [7:0] pix_x, pix_y;
    wire [15:0] pixel;
    wire lcd_resetn, lcd_clk, lcd_cs, lcd_rs, lcd_data;

    debug_screen screen (
        .clk(clk), .rst(por), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .boot_state(boot_state), .slot(5'd0), .prog_name(prog_name),
        .prog_words(prog_words), .pc(dbg_pc), .instr(dbg_instr), .a(dbg_a), .d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

    st7789_driver #(.RESET_CYCLES(50), .WAKE_CYCLES(70), .SLEEP_CYCLES(90)) drv (
        .clk(clk), .rst(por), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .lcd_resetn(lcd_resetn), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_rs(lcd_rs), .lcd_data(lcd_data)
    );

    st7789_model lcd (
        .resetn(lcd_resetn), .scl(lcd_clk), .cs(lcd_cs), .dc(lcd_rs), .sda(lcd_data)
    );

    always #(HALF_NS) clk = ~clk;
    always #20 vclk = ~vclk;

    integer frames, s1_frame, starts = 0, trace_fd, n, i, f;
    reg was_reset = 1;
    reg [14:0] pc_before;
    reg [15:0] instr;

    // Same trace format as tb_flash_boot: A and D after the instruction
    always @(posedge clk) begin
        if (frame_start) starts = starts + 1;
        if (dut.cpu_reset && !was_reset) $fdisplay(trace_fd, "reset");
        was_reset = dut.cpu_reset;
        if (dut.computer.dbg_exec) begin
            pc_before = dbg_pc;
            instr = dbg_instr;
            #1;
            $fdisplay(trace_fd, "%04x %04x %04x %04x", pc_before, instr, dbg_a, dbg_d);
        end
    end

    initial begin
        if (!$value$plusargs("FRAMES=%d", frames)) frames = 1;
        if (!$value$plusargs("S1_FRAME=%d", s1_frame)) s1_frame = 0;
        trace_fd = $fopen("trace.txt", "w");
        repeat (4) @(posedge clk);
        #1 por_n = 1;
        if (s1_frame > 1) begin
            wait (starts == s1_frame - 1);
            repeat (1000) @(posedge clk);
            #1 s1 = 1;
            wait (starts == s1_frame);
            repeat (100) @(posedge clk);
            #1 s1 = 0;
        end
    end

    initial begin
        for (n = 1; n <= frames; n = n + 1) begin
            wait (lcd.frames_done == n);
            f = $fopen($sformatf("frame%0d.hex", n), "w");
            for (i = 0; i < 240 * 135; i = i + 1) $fdisplay(f, "%04h", lcd.fb[i]);
            $fclose(f);
        end
        $fclose(trace_fd);
        $display("ERRORS %0d", lcd.errors);
        $finish;
    end

    initial begin
        #1;
        #(37.0 * 1200000.0 * (frames + 1));
        $display("TIMEOUT");
        $finish;
    end
endmodule
