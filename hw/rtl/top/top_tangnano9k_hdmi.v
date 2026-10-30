`default_nettype none

// Hack computer with its program loaded from flash slot 0 into PSRAM, Hack
// screen on HDMI, status text on the 1.14" LCD. S1 resets the CPU, S2 loads
// the program again. The PC's keys and status requests come in over the
// BL702 UART (serial_link).
// LEDs: 0 = loader busy, 1 = running, 2 = bad header, 3 = bad CRC,
// 4 = PSRAM ready, 5 = 1 Hz heartbeat.
module top (
    input  wire        clk,
    input  wire        btn_s1,
    input  wire        btn_s2,
    output wire [5:0]  led,
    output wire        flash_clk,
    output wire        flash_cs_n,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    output wire        lcd_resetn,
    output wire        lcd_clk,
    output wire        lcd_cs,
    output wire        lcd_rs,
    output wire        lcd_data,
    input  wire        uart_rx,
    output wire        uart_tx
);

    // Power-on reset: about 2.4 ms at 27 MHz
    reg [16:0] por_count = 0;
    wire por = ~por_count[16];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_pressed, s2_pressed;
    reset_sync #(.DEBOUNCE(1)) s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_pressed));
    reset_sync #(.DEBOUNCE(1)) s2_sync (.clk(clk), .async_in(~btn_s2), .sync_out(s2_pressed));

    // PSRAM
    wire req_valid, req_ready, req_we, rsp_valid, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;

    psram_ctrl #(.CLK_HZ(27_000_000)) psram (
        .clk(clk), .rst_n(~por),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq(IO_psram_dq), .IO_psram_rwds(IO_psram_rwds)
    );

    // Video clocks, held in reset until the PLL locks
    wire clk_pix, clk_ser, locked;
    clocks_gowin clocks (.clk27(clk), .clk_pix(clk_pix), .clk_ser(clk_ser), .locked(locked));

    reg [1:0] pix_rst_sync = 2'b11;
    always @(posedge clk_pix or negedge locked)
        if (!locked) pix_rst_sync <= 2'b11;
        else pix_rst_sync <= {pix_rst_sync[0], 1'b0};
    wire pix_rst = pix_rst_sync[1];

    // Computer, loader and program memory
    wire [12:0] vaddr;
    wire [15:0] vdata;
    wire busy, running, err_header, err_crc;
    wire [2:0] boot_state;
    wire [127:0] prog_name;
    wire [15:0] prog_words, dbg_instr, dbg_a, dbg_d, sp, sp_max;
    wire [14:0] dbg_pc, heap_hi;
    wire [15:0] keyboard;

    flash_boot_system system (
        .clk(clk), .por_n(~por), .s1(s1_pressed), .s2(s2_pressed), .keyboard(keyboard),
        .flash_clk(flash_clk), .flash_cs_n(flash_cs_n),
        .flash_mosi(flash_mosi), .flash_miso(flash_miso),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .vclk(clk_pix), .vaddr(vaddr), .vdata(vdata),
        .busy(busy), .running(running), .err_header(err_header), .err_crc(err_crc),
        .boot_state(boot_state), .prog_name(prog_name), .prog_words(prog_words),
        .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_a(dbg_a), .dbg_d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

    // Serial link: keyboard in, status out
    serial_link link (
        .clk(clk), .rst(por), .uart_rx(uart_rx), .uart_tx(uart_tx), .keyboard(keyboard),
        .boot_state(boot_state), .pc(dbg_pc), .instr(dbg_instr), .a(dbg_a), .d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi), .prog_words(prog_words),
        .prog_name(prog_name)
    );

    // Status LCD. The loader always reads slot 0.
    wire frame_start, frame_ready, pix_req;
    wire [7:0] pix_x, pix_y;
    wire [15:0] pixel;

    debug_screen screen (
        .clk(clk), .rst(por), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .boot_state(boot_state), .slot(5'd0), .prog_name(prog_name),
        .prog_words(prog_words), .pc(dbg_pc), .instr(dbg_instr), .a(dbg_a), .d(dbg_d),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

    st7789_driver lcd (
        .clk(clk), .rst(por), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .lcd_resetn(lcd_resetn), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_rs(lcd_rs), .lcd_data(lcd_data)
    );

    // Video
    wire [9:0] x, y;
    wire hs, vs, de;
    video_timing_640x480 timing (
        .clk(clk_pix), .rst(pix_rst), .x(x), .y(y), .hsync(hs), .vsync(vs), .de(de)
    );

    wire [23:0] rgb;
    wire de_o, hs_o, vs_o;
    hack_fb_reader reader (
        .clk(clk_pix), .x(x), .y(y), .de(de), .hs(hs), .vs(vs),
        .vaddr(vaddr), .vdata(vdata),
        .rgb(rgb), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
    );

    wire [9:0] ch0, ch1, ch2;
    tmds_encoder enc_b (.clk(clk_pix), .d(rgb[7:0]),   .c({vs_o, hs_o}), .de(de_o), .q(ch0));
    tmds_encoder enc_g (.clk(clk_pix), .d(rgb[15:8]),  .c(2'b00),        .de(de_o), .q(ch1));
    tmds_encoder enc_r (.clk(clk_pix), .d(rgb[23:16]), .c(2'b00),        .de(de_o), .q(ch2));

    hdmi_phy_gowin phy (
        .clk_pix(clk_pix), .clk_ser(clk_ser), .rst(pix_rst),
        .ch0(ch0), .ch1(ch1), .ch2(ch2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // Heartbeat: toggles every 13.5M cycles
    reg [23:0] beat_count = 0;
    reg beat = 0;
    always @(posedge clk)
        if (beat_count == 24'd13_499_999) begin
            beat_count <= 0;
            beat <= ~beat;
        end else begin
            beat_count <= beat_count + 1'b1;
        end

    // LEDs are active low
    assign led = ~{beat, init_done, err_crc, err_header, running, busy};

endmodule

`default_nettype wire
