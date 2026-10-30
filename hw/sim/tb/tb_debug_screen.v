`timescale 1ns / 1ps

// debug_screen behind st7789_driver (short delays) into st7789_model.
// Field values come from plusargs: STATE SLOT NAME (32 hex digits, byte 12 of
// the header first) WORDS PC INSTR A D SP SPMAX HEAP, all unsigned.
// +CHANGE_AT=n switches every field to its second value (STATE2, A2, ...) at
// cycle n. +FRAMES=n stops after n frames; frame k is saved as frame<k>.hex.
// Prints RAMWR at the first RAMWR's cycle and ERRORS (the model's count).
module tb_debug_screen;
    reg clk = 0, rst = 1;
    wire frame_start, frame_ready, pix_req;
    wire [7:0] pix_x, pix_y;
    wire [15:0] pixel;
    wire lcd_resetn, lcd_clk, lcd_cs, lcd_rs, lcd_data;

    reg [2:0] state, state2;
    reg [4:0] slot, slot2;
    reg [127:0] name, name2;
    reg [15:0] words, words2, instr, instr2, a, a2, d, d2, sp, sp2, spmax, spmax2;
    reg [14:0] pc, pc2, heap, heap2;
    integer frames, change_at, cycle = 0, n, i, f;

    st7789_driver #(.RESET_CYCLES(50), .WAKE_CYCLES(70), .SLEEP_CYCLES(90)) drv (
        .clk(clk), .rst(rst), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .lcd_resetn(lcd_resetn), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_rs(lcd_rs), .lcd_data(lcd_data)
    );

    debug_screen dut (
        .clk(clk), .rst(rst), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .boot_state(state), .slot(slot), .prog_name(name), .prog_words(words),
        .pc(pc), .instr(instr), .a(a), .d(d), .sp(sp), .sp_max(spmax), .heap_hi(heap)
    );

    st7789_model lcd (
        .resetn(lcd_resetn), .scl(lcd_clk), .cs(lcd_cs), .dc(lcd_rs), .sda(lcd_data)
    );

    always #18.5 clk = ~clk;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (cycle == change_at) begin
            state <= state2;
            slot <= slot2;
            name <= name2;
            words <= words2;
            pc <= pc2;
            instr <= instr2;
            a <= a2;
            d <= d2;
            sp <= sp2;
            spmax <= spmax2;
            heap <= heap2;
        end
    end

    reg ramwr_seen = 0;
    always @(posedge clk) if (!ramwr_seen && drv.state == drv.S_FRAME) begin
        ramwr_seen <= 1;
        $display("RAMWR %0d", cycle);
    end

    initial begin
        if (!$value$plusargs("FRAMES=%d", frames)) frames = 1;
        if (!$value$plusargs("CHANGE_AT=%d", change_at)) change_at = -1;
        if (!$value$plusargs("STATE=%d", state)) state = 0;
        if (!$value$plusargs("SLOT=%d", slot)) slot = 0;
        if (!$value$plusargs("NAME=%h", name)) name = 0;
        if (!$value$plusargs("WORDS=%d", words)) words = 0;
        if (!$value$plusargs("PC=%d", pc)) pc = 0;
        if (!$value$plusargs("INSTR=%d", instr)) instr = 0;
        if (!$value$plusargs("A=%d", a)) a = 0;
        if (!$value$plusargs("D=%d", d)) d = 0;
        if (!$value$plusargs("SP=%d", sp)) sp = 0;
        if (!$value$plusargs("SPMAX=%d", spmax)) spmax = 0;
        if (!$value$plusargs("HEAP=%d", heap)) heap = 0;
        if (!$value$plusargs("STATE2=%d", state2)) state2 = state;
        if (!$value$plusargs("SLOT2=%d", slot2)) slot2 = slot;
        if (!$value$plusargs("NAME2=%h", name2)) name2 = name;
        if (!$value$plusargs("WORDS2=%d", words2)) words2 = words;
        if (!$value$plusargs("PC2=%d", pc2)) pc2 = pc;
        if (!$value$plusargs("INSTR2=%d", instr2)) instr2 = instr;
        if (!$value$plusargs("A2=%d", a2)) a2 = a;
        if (!$value$plusargs("D2=%d", d2)) d2 = d;
        if (!$value$plusargs("SP2=%d", sp2)) sp2 = sp;
        if (!$value$plusargs("SPMAX2=%d", spmax2)) spmax2 = spmax;
        if (!$value$plusargs("HEAP2=%d", heap2)) heap2 = heap;
        repeat (3) @(negedge clk);
        rst = 0;
        for (n = 1; n <= frames; n = n + 1) begin
            wait (lcd.frames_done == n);
            f = $fopen($sformatf("frame%0d.hex", n), "w");
            for (i = 0; i < 240 * 135; i = i + 1) $fdisplay(f, "%04h", lcd.fb[i]);
            $fclose(f);
        end
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
