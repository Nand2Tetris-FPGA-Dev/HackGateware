`default_nettype none

// Stack and heap figures from the CPU's RAM writes, for the debug screen.
// RAM[0] is SP and 2048-16383 is the heap (book ch. 7, VM memory map). sp_max is an
// unsigned max, so a stack run past 32767 still shows. heap_hi is the highest
// heap address written, 0 if none. clear is held while the CPU is in reset.
module hack_stats (
    input  wire        clk,
    input  wire        clear,
    input  wire        we,
    input  wire [14:0] addr,
    input  wire [15:0] wdata,
    output reg  [15:0] sp,
    output reg  [15:0] sp_max,
    output reg  [14:0] heap_hi
);

    initial begin
        sp = 0;
        sp_max = 0;
        heap_hi = 0;
    end

    wire in_heap = addr >= 15'd2048 && !addr[14];

    always @(posedge clk) begin
        if (clear) begin
            sp <= 0;
            sp_max <= 0;
            heap_hi <= 0;
        end else if (we) begin
            if (addr == 0) begin
                sp <= wdata;
                if (wdata > sp_max) sp_max <= wdata;
            end
            if (in_heap && addr > heap_hi) heap_hi <= addr;
        end
    end

endmodule

`default_nettype wire
