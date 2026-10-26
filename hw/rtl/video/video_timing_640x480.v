// 640x480 @ 60 Hz with a 25.2 MHz pixel clock. Both syncs are active low.
module video_timing_640x480 (
    input  wire       clk,
    input  wire       rst,
    output reg  [9:0] x,
    output reg  [9:0] y,
    output wire       hsync,
    output wire       vsync,
    output wire       de
);

    initial begin
        x = 10'd0;
        y = 10'd0;
    end

    always @(posedge clk) begin
        if (rst) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (x == 10'd799) begin
            x <= 10'd0;
            y <= (y == 10'd524) ? 10'd0 : y + 10'd1;
        end else begin
            x <= x + 10'd1;
        end
    end

    assign de = (x < 10'd640) && (y < 10'd480);
    assign hsync = ~((x >= 10'd656) && (x < 10'd752));
    assign vsync = ~((y >= 10'd490) && (y < 10'd492));

endmodule
