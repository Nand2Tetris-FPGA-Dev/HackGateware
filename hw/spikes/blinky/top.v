`default_nettype none

// Board check: the 6 LEDs show bits 26..21 of a counter on the 27 MHz clock.
// led[0] blinks about 6 times a second, and each next LED is half as fast.
// Holding S1 inverts all six. LEDs and buttons are active low (0 = lit / pressed).
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led
);
    reg [26:0] count = 27'd0;

    always @(posedge clk)
        count <= count + 27'd1;

    wire [5:0] pattern = count[26:21] ^ {6{~btn_s1}};

    assign led = ~pattern;
endmodule

`default_nettype wire
