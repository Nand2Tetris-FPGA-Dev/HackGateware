`default_nettype none

// LEDs count, S1 inverts them
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led
);
    reg [26:0] count = 27'd0;

    always @(posedge clk)
        count <= count + 27'd1;

    assign led = ~(count[26:21] ^ {6{~btn_s1}});
endmodule

`default_nettype wire
