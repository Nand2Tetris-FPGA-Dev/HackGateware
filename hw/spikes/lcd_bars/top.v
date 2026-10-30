`default_nettype none

// LCD spike: a 1-pixel white border, then red, green and blue bars left to
// right. S1 restarts the panel init. LED 0 toggles every 16 frames.
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,
    output wire       lcd_resetn,
    output wire       lcd_clk,
    output wire       lcd_cs,
    output wire       lcd_rs,
    output wire       lcd_data
);

    reg [16:0] por_count = 0;
    wire por = ~por_count[16];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_pressed;
    reset_sync #(.DEBOUNCE(1)) s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_pressed));

    wire frame_start, pix_req;
    wire [7:0] pix_x, pix_y;
    reg [15:0] pixel = 0;

    st7789_driver lcd (
        .clk(clk), .rst(por | s1_pressed),
        .frame_start(frame_start), .frame_ready(1'b1),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .lcd_resetn(lcd_resetn), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_rs(lcd_rs), .lcd_data(lcd_data)
    );

    // Registered, so the color is ready a cycle after the request
    always @(posedge clk)
        if (pix_req) begin
            if (pix_x == 0 || pix_x == 239 || pix_y == 0 || pix_y == 134)
                pixel <= 16'hFFFF;
            else if (pix_x < 80)
                pixel <= 16'hF800;
            else if (pix_x < 160)
                pixel <= 16'h07E0;
            else
                pixel <= 16'h001F;
        end

    reg [4:0] frames = 0;
    always @(posedge clk)
        if (frame_start) frames <= frames + 1'b1;

    assign led = ~{5'b00000, frames[4]};

endmodule

`default_nettype wire
