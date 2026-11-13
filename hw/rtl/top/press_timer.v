`default_nettype none

// Splits a debounced button level into a short and a long press, each a
// 1-cycle pulse. long_press fires once when the hold reaches LONG_CYCLES;
// short_press fires on a release before that. A release after a long press
// gives nothing. cancel drops the press under way: nothing fires until the
// button is released and pressed again.
module press_timer #(
    parameter LONG_CYCLES = 27_000_000
) (
    input  wire clk,
    input  wire btn,
    input  wire cancel,
    output reg  short_press,
    output reg  long_press
);

    // saturates at LONG_CYCLES
    reg [$clog2(LONG_CYCLES + 1)-1:0] held = 0;

    initial begin
        short_press = 1'b0;
        long_press = 1'b0;
    end

    always @(posedge clk) begin
        short_press <= 1'b0;
        long_press <= 1'b0;
        if (cancel) begin
            held <= LONG_CYCLES;
        end else if (btn) begin
            if (held != LONG_CYCLES) held <= held + 1'b1;
            if (held == LONG_CYCLES - 1) long_press <= 1'b1;
        end else begin
            if (held != 0 && held != LONG_CYCLES) short_press <= 1'b1;
            held <= 0;
        end
    end

endmodule

`default_nettype wire
