`timescale 1ns / 1ps

// uart_rx driven by a bit-banged line, or uart_tx looped into a second uart_rx.
// rx.hex: one "byte stop" line per byte (stop 0 sends a bad stop bit).
// +BIT_PS: bit time in ps. +GAP_BITS: idle bits between bytes.
// +BREAK_BITS: rx held low this long before the bytes. +LOOP: send 0-255
// through uart_tx instead. Prints RX/ERR (driven) or LB (loopback) lines.
`ifndef CLKS_PER_BIT
`define CLKS_PER_BIT 9
`endif
module tb_uart;
    reg clk = 0, rst = 1, rx = 1;
    wire [7:0] data, lb_data;
    wire valid, frame_err, lb_valid, lb_err, tx, tx_ready;
    reg [7:0] tx_data = 0;
    reg tx_valid = 0;

    uart_rx #(.CLKS_PER_BIT(`CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .rx(rx), .data(data), .valid(valid), .frame_err(frame_err)
    );
    uart_tx #(.CLKS_PER_BIT(`CLKS_PER_BIT)) tx_dut (
        .clk(clk), .rst(rst), .data(tx_data), .valid(tx_valid), .ready(tx_ready), .tx(tx)
    );
    uart_rx #(.CLKS_PER_BIT(`CLKS_PER_BIT)) lb_rx (
        .clk(clk), .rst(rst), .rx(tx), .data(lb_data), .valid(lb_valid), .frame_err(lb_err)
    );

    // 27 MHz
    always #18.5185 clk = ~clk;

    always @(posedge clk) begin
        if (valid) $display("RX %02x", data);
        if (frame_err) $display("ERR");
        if (lb_valid) $display("LB %02x", lb_data);
        if (lb_err) $display("LBERR");
    end

    integer bit_ps, gap_bits, break_bits, fd, n, b, s, i;
    real bit_ns;

    task send_byte(input [7:0] value, input stop);
        begin
            rx = 0;
            #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin
                rx = value[i];
                #(bit_ns);
            end
            rx = stop;
            #(bit_ns);
            rx = 1;
            #(bit_ns * gap_bits);
        end
    endtask

    initial begin
        if (!$value$plusargs("BIT_PS=%d", bit_ps)) bit_ps = 333333;
        if (!$value$plusargs("GAP_BITS=%d", gap_bits)) gap_bits = 2;
        if (!$value$plusargs("BREAK_BITS=%d", break_bits)) break_bits = 0;
        bit_ns = bit_ps / 1000.0;
        repeat (4) @(posedge clk);
        rst = 0;
        #(bit_ns * 3);
        if ($test$plusargs("LOOP")) begin
            for (b = 0; b < 256; b = b + 1) begin
                @(negedge clk);
                tx_data = b;
                tx_valid = 1;
                @(posedge clk);
                while (!tx_ready) @(posedge clk);
                @(negedge clk);
                tx_valid = 0;
            end
            while (!tx_ready) @(posedge clk);
            #(bit_ns * 12);
            $display("IDLE %b", tx);
        end else begin
            if (break_bits > 0) begin
                rx = 0;
                #(bit_ns * break_bits);
                rx = 1;
                #(bit_ns * 2);
            end
            fd = $fopen("rx.hex", "r");
            n = $fscanf(fd, "%h %h", b, s);
            while (n == 2) begin
                send_byte(b, s);
                n = $fscanf(fd, "%h %h", b, s);
            end
            #(bit_ns * 4);
        end
        $display("DONE");
        $finish;
    end
endmodule
