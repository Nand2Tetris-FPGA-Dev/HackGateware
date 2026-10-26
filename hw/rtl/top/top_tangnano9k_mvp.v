`default_nettype none

// Hack computer with its program in a 2K word block RAM ROM, Hack screen on HDMI.
// S1 resets the CPU (RAM and screen are kept). LED 0 blinks, LED 1 = running.
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    // Power-on reset: about 2.4 ms at 27 MHz
    reg [16:0] por_count = 0;
    wire por = ~por_count[16];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_pressed;
    reset_sync #(.DEBOUNCE(1)) s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_pressed));

    wire cpu_reset = por | s1_pressed;

    // Video clocks, held in reset until the PLL locks
    wire clk_pix, clk_ser, locked;
    clocks_gowin clocks (.clk27(clk), .clk_pix(clk_pix), .clk_ser(clk_ser), .locked(locked));

    reg [1:0] pix_rst_sync = 2'b11;
    always @(posedge clk_pix or negedge locked)
        if (!locked) pix_rst_sync <= 2'b11;
        else pix_rst_sync <= {pix_rst_sync[0], 1'b0};
    wire pix_rst = pix_rst_sync[1];

    // Computer and ROM
    wire pm_req, pm_ready;
    wire [14:0] pm_addr;
    wire [15:0] pm_data;
    wire [12:0] vaddr;
    wire [15:0] vdata;

    hack_computer computer (
        .clk(clk), .reset(cpu_reset),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(16'd0), .vclk(clk_pix), .vaddr(vaddr), .vdata(vdata),
        .dbg_pc(), .dbg_a(), .dbg_d(), .dbg_instr(), .dbg_exec()
    );

    progmem_rom #(.WORDS(2048)) rom (
        .clk(clk), .fetch_req(pm_req), .fetch_addr(pm_addr),
        .fetch_ready(pm_ready), .fetch_data(pm_data)
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

    // LEDs are active low
    reg [24:0] blink = 0;
    always @(posedge clk) blink <= blink + 1'b1;

    assign led = ~{4'b0000, ~cpu_reset, blink[24]};

endmodule

`default_nettype wire
