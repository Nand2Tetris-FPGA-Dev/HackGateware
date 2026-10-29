`timescale 1ns / 1ps

// hack_stats driven from stim.txt, one "clear we addr wdata" line (hex) per
// cycle. out.txt gets "sp sp_max heap_hi" after each cycle.
module tb_hack_stats;
    reg clk = 0, clear = 0, we = 0;
    reg [14:0] addr = 0;
    reg [15:0] wdata = 0;
    wire [15:0] sp, sp_max;
    wire [14:0] heap_hi;

    hack_stats dut (
        .clk(clk), .clear(clear), .we(we), .addr(addr), .wdata(wdata),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

    always #18.5 clk = ~clk;

    integer in_fd, out_fd, n, c, w, a, d;

    initial begin
        in_fd = $fopen("stim.txt", "r");
        out_fd = $fopen("out.txt", "w");
        n = $fscanf(in_fd, "%h %h %h %h", c, w, a, d);
        while (n == 4) begin
            @(negedge clk);
            clear = c;
            we = w;
            addr = a;
            wdata = d;
            @(posedge clk);
            #1 $fdisplay(out_fd, "%0d %0d %0d", sp, sp_max, heap_hi);
            n = $fscanf(in_fd, "%h %h %h %h", c, w, a, d);
        end
        $fclose(out_fd);
        $display("DONE");
        $finish;
    end
endmodule
