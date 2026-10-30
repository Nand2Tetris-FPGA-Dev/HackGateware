`timescale 1ns / 1ps

// frame_rx fed from in.hex (one byte per line, or ERR to pulse in_err), +GAP
// idle cycles between bytes. Prints "OK len b0 b1 ..." read through rd_addr,
// or BAD. +LATE reads the buffer only after the next frame's first byte.
// +TX: frame_tx sends each "len b0 b1 ..." line of src.hex with out_ready
// toggling at random; prints TX per byte taken.
module tb_frames;
    reg clk = 0, rst = 1;
    always #18.5185 clk = ~clk;

    reg in_valid = 0, in_err = 0;
    reg [7:0] in_byte = 0;
    reg [5:0] rd_addr = 0;
    wire [7:0] rd_data;
    wire frame_ok, frame_bad;
    wire [6:0] frame_len;

    frame_rx rx_dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_byte(in_byte), .in_err(in_err),
        .frame_ok(frame_ok), .frame_len(frame_len), .frame_bad(frame_bad),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    reg start = 0, out_ready = 0;
    reg [6:0] len = 0;
    reg [7:0] src [0:63];
    wire busy, out_valid;
    wire [5:0] src_addr;
    wire [7:0] out_byte;

    frame_tx tx_dut (
        .clk(clk), .rst(rst), .start(start), .len(len), .busy(busy),
        .src_addr(src_addr), .src_data(src[src_addr]),
        .out_valid(out_valid), .out_byte(out_byte), .out_ready(out_ready)
    );

    always @(posedge clk)
        if (out_valid && out_ready) $display("TX %02x", out_byte);

    always @(negedge clk)
        if (frame_bad) $display("BAD");

    integer k;
    always @(negedge clk)
        if (frame_ok) begin
            if ($test$plusargs("LATE")) begin
                @(posedge clk);
                while (!in_valid) @(posedge clk);
                @(negedge clk);
            end
            $write("OK %0d", frame_len);
            for (k = 0; k < frame_len; k = k + 1) begin
                rd_addr = k;
                #0.01;
                $write(" %02x", rd_data);
            end
            $display("");
        end

    integer gap, fd, n, b, seed, i;
    reg [8*16-1:0] line, word;

    initial begin
        if (!$value$plusargs("GAP=%d", gap)) gap = 4;
        seed = 7;
        repeat (4) @(negedge clk);
        rst = 0;
        if ($test$plusargs("TX")) begin
            fork
                forever @(negedge clk) out_ready = $random(seed);
            join_none
            fd = $fopen("src.hex", "r");
            while ($fscanf(fd, "%h", n) == 1) begin
                for (i = 0; i < n; i = i + 1) b = $fscanf(fd, "%h", src[i]);
                @(negedge clk);
                len = n;
                start = 1;
                @(negedge clk);
                start = 0;
                while (busy) @(negedge clk);
            end
        end else begin
            fd = $fopen("in.hex", "r");
            while ($fgets(line, fd)) begin
                @(negedge clk);
                n = $sscanf(line, "%s", word);
                if (word == "ERR")
                    in_err = 1;
                else begin
                    n = $sscanf(line, "%h", b);
                    in_byte = b;
                    in_valid = 1;
                end
                @(negedge clk);
                in_valid = 0;
                in_err = 0;
                repeat (gap) @(negedge clk);
            end
            repeat (8) @(negedge clk);
        end
        $display("DONE");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
