`timescale 1ns / 1ps

// st7789_driver with short delays into st7789_model. The pixel source returns
// {x, y} through 4 register stages, and DEAD when no request is due, so a
// driver sampling on the wrong cycle draws the wrong colors.
// +FRAMES=n: stop after n frames; 0 stops at the first RAMWR.
// +READY_DELAY=n: hold frame_ready low n cycles after each frame_start.
// +RERESET=1: then pulse rst with CS high and run until the next RAMWR is logged.
// Prints TIMES (cycle numbers of rst release, resetn rise, the first and last
// SCL rise of SLPOUT, the first SCL rise of the next byte), READY_WAIT
// (cycles from the first frame_start to the first SCL rise of RAMWR) and
// ERRORS (the model's count).
module tb_st7789;
    reg clk = 0, rst = 1, frame_ready = 1;
    wire frame_start, pix_req;
    wire [7:0] pix_x, pix_y;
    wire lcd_resetn, lcd_clk, lcd_cs, lcd_rs, lcd_data;
    reg [16:0] d1 = 0, d2 = 0, d3 = 0, d4 = 0;
    wire [15:0] pixel = d4[16] ? d4[15:0] : 16'hDEAD;
    integer frames, ready_delay, rereset, ready_cnt = 0, edges = 0;
    real t_rst, t_resetn, t_c11_first, t_c11_last, t_c36_first, t_fs = -1;
    event ramwr_seen;

    // RAMWR is the 71st byte: SLPOUT, 69 init bytes, then 0x2C
    localparam RAMWR_EDGE = 70 * 8 + 1;

    st7789_driver #(.RESET_CYCLES(50), .WAKE_CYCLES(70), .SLEEP_CYCLES(90)) dut (
        .clk(clk), .rst(rst), .frame_start(frame_start), .frame_ready(frame_ready),
        .pix_req(pix_req), .pix_x(pix_x), .pix_y(pix_y), .pixel(pixel),
        .lcd_resetn(lcd_resetn), .lcd_clk(lcd_clk), .lcd_cs(lcd_cs),
        .lcd_rs(lcd_rs), .lcd_data(lcd_data)
    );

    st7789_model lcd (
        .resetn(lcd_resetn), .scl(lcd_clk), .cs(lcd_cs), .dc(lcd_rs), .sda(lcd_data)
    );

    always #18.5 clk = ~clk;

    function integer cyc(input real t);
        cyc = $rtoi((t - 18.5) / 37.0 + 0.5);
    endfunction

    always @(posedge clk) begin
        d1 <= {pix_req, pix_x, pix_y};
        d2 <= d1;
        d3 <= d2;
        d4 <= d3;
        if (frame_start) begin
            frame_ready <= 1'b0;
            ready_cnt <= ready_delay;
        end else if (ready_cnt > 0) begin
            ready_cnt <= ready_cnt - 1;
        end else begin
            frame_ready <= 1'b1;
        end
    end

    always @(posedge frame_start) if (t_fs < 0) t_fs = $realtime;
    always @(posedge lcd_resetn) t_resetn = $realtime;

    always @(posedge lcd_clk) if (!lcd_cs) begin
        edges = edges + 1;
        case (edges)
            1: t_c11_first = $realtime;
            8: t_c11_last = $realtime;
            9: t_c36_first = $realtime;
            RAMWR_EDGE: begin
                $display("READY_WAIT %0d", cyc($realtime) - cyc(t_fs));
                -> ramwr_seen;
            end
            default: ;
        endcase
    end

    initial begin
        if (!$value$plusargs("FRAMES=%d", frames)) frames = 1;
        if (!$value$plusargs("READY_DELAY=%d", ready_delay)) ready_delay = 0;
        if (!$value$plusargs("RERESET=%d", rereset)) rereset = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        @(posedge clk);
        t_rst = $realtime;
        if (frames == 0) @(ramwr_seen);
        else wait (lcd.frames_done == frames);
        if (rereset) begin
            wait (lcd_cs);
            @(negedge clk) rst = 1;
            repeat (3) @(negedge clk);
            rst = 0;
            edges = 0;
            @(ramwr_seen);
            wait (lcd.writing);
        end
        $display("TIMES rst=%0d resetn=%0d c11_first=%0d c11_last=%0d c36_first=%0d",
                 cyc(t_rst), cyc(t_resetn), cyc(t_c11_first), cyc(t_c11_last), cyc(t_c36_first));
        $display("ERRORS %0d", lcd.errors);
        $finish;
    end

    initial begin
        #1;
        #(37.0 * (1200000.0 * (frames + 1) + 4.0 * ready_delay));
        $display("TIMEOUT");
        $finish;
    end
endmodule
