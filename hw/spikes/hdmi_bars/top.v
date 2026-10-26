`default_nettype none

// 8 vertical color bars over HDMI. LED 0 = PLL locked, LED 1 blinks on the pixel clock.
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

    wire clk_pix, clk_ser, locked;
    clocks_gowin clocks (.clk27(clk), .clk_pix(clk_pix), .clk_ser(clk_ser), .locked(locked));

    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk_pix or negedge locked)
        if (!locked) rst_sync <= 2'b11;
        else rst_sync <= {rst_sync[0], 1'b0};
    wire rst = rst_sync[1];

    wire [9:0] x, y;
    wire hsync, vsync, de;
    video_timing_640x480 timing (
        .clk(clk_pix), .rst(rst), .x(x), .y(y), .hsync(hsync), .vsync(vsync), .de(de)
    );

    reg [23:0] rgb;
    always @(*) begin
        if (x < 80)       rgb = 24'hffffff;
        else if (x < 160) rgb = 24'hffff00;
        else if (x < 240) rgb = 24'h00ffff;
        else if (x < 320) rgb = 24'h00ff00;
        else if (x < 400) rgb = 24'hff00ff;
        else if (x < 480) rgb = 24'hff0000;
        else if (x < 560) rgb = 24'h0000ff;
        else              rgb = 24'h000000;
    end

    wire [9:0] ch0, ch1, ch2;
    tmds_encoder enc_b (.clk(clk_pix), .d(rgb[7:0]),   .c({vsync, hsync}), .de(de), .q(ch0));
    tmds_encoder enc_g (.clk(clk_pix), .d(rgb[15:8]),  .c(2'b00),          .de(de), .q(ch1));
    tmds_encoder enc_r (.clk(clk_pix), .d(rgb[23:16]), .c(2'b00),          .de(de), .q(ch2));

    hdmi_phy_gowin phy (
        .clk_pix(clk_pix), .clk_ser(clk_ser), .rst(rst),
        .ch0(ch0), .ch1(ch1), .ch2(ch2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    reg [24:0] blink = 0;
    always @(posedge clk_pix) blink <= blink + 1'b1;

    assign led = ~{4'b0000, blink[24], locked};

endmodule

`default_nettype wire
