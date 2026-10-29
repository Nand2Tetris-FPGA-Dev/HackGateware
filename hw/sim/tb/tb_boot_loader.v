`timescale 1ns / 1ps

// boot_loader -> spi_flash_reader -> spi_flash_model, with a capture memory on
// the load port that stalls load_ready at random. Loads slot 1 (0x20000).
// +RESET_AT=N resets the loader at the first pending write after N cycles,
// then starts it again.
// Extra start pulses mid-load and after finishing must be ignored.
// Runs until a flag is set, then writes captured.hex and prints a RESULT line.
// Unwritten capture words read back as xxxx.
module tb_boot_loader;
    reg clk = 0, rst_n = 0, start = 0;
    wire rd_start, rd_stop, rd_valid, rd_ready;
    wire [23:0] rd_addr;
    wire [7:0] rd_byte;
    wire load_valid;
    reg load_ready = 0;
    wire [14:0] load_addr;
    wire [31:0] load_data;
    wire [3:0] load_strb;
    wire busy, done, err_header, err_crc;
    wire [15:0] word_count;
    wire cs_n, sck, mosi, miso;

    reg [15:0] mem [0:32767];
    reg [3:0] last_strb = 0;
    integer errors = 0, writes = 0, seed = 11, cycles = 0, limit = 8000000, reset_at, i;
    reg [15:0] next_addr = 0;

    boot_loader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .slot_base(24'h020000),
        .rd_start(rd_start), .rd_addr(rd_addr), .rd_stop(rd_stop),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .rd_ready(rd_ready),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .busy(busy), .done(done), .err_header(err_header), .err_crc(err_crc),
        .word_count(word_count)
    );

    spi_flash_reader #(.HALF_PERIOD(2)) reader (
        // not reset with the loader: the loader's rd_stop must stop it
        .clk(clk), .rst_n(1'b1), .start(rd_start), .addr(rd_addr), .stop(rd_stop),
        .out_valid(rd_valid), .out_byte(rd_byte), .out_ready(rd_ready),
        .flash_cs_n(cs_n), .flash_clk(sck), .flash_mosi(mosi), .flash_miso(miso)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(cs_n), .clk(sck), .mosi(mosi), .miso(miso)
    );

    always #18.5 clk = ~clk;

    // Ready 1 cycle in 64: stalls outlast a flash byte (about 32 cycles), so
    // the next byte arrives while a write is still waiting
    always @(negedge clk) load_ready <= ($random(seed) & 63) == 0;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (load_valid && load_ready) begin
            if (load_addr !== next_addr[14:0] || next_addr > 16'd32766) begin
                $display("FAIL write to %0d, expected %0d", load_addr, next_addr);
                errors = errors + 1;
            end
            if (load_strb !== 4'b1111 && load_strb !== 4'b0011) begin
                $display("FAIL strobe %b", load_strb);
                errors = errors + 1;
            end
            if (load_strb[0]) mem[load_addr] = load_data[15:0];
            if (load_strb[2]) mem[load_addr + 1] = load_data[31:16];
            last_strb = load_strb;
            next_addr = next_addr + 2;
            writes = writes + 1;
        end
    end

    task pulse_start;
        begin
            start = 1;
            @(negedge clk);
            start = 0;
        end
    endtask

    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 16'bx;
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
        if (busy || done || err_header || err_crc || rd_start) begin
            $display("FAIL loader active before start");
            errors = errors + 1;
        end
        pulse_start;
        if ($value$plusargs("RESET_AT=%d", reset_at)) begin
            repeat (reset_at) @(negedge clk);
            while (!load_valid) @(negedge clk);  // reset with a write pending
            rst_n = 0;
            repeat (3) @(negedge clk);
            if (busy || done || err_header || err_crc || load_valid) begin
                $display("FAIL loader active in reset");
                errors = errors + 1;
            end
            for (i = 0; i < 32768; i = i + 1) mem[i] = 16'bx;
            next_addr = 0;
            writes = 0;
            rst_n = 1;
            @(negedge clk);
            pulse_start;
        end
        repeat (500) @(negedge clk);
        pulse_start;  // mid-header: ignored
        while (!(done || err_header || err_crc) && cycles < limit) @(negedge clk);
        // flags must hold, a new start is ignored, and nothing more is written
        i = writes;
        repeat (20) @(negedge clk);
        pulse_start;
        repeat (2000) @(negedge clk);
        if (!(done || err_header || err_crc)) begin
            $display("FAIL loader never finished");
            errors = errors + 1;
        end
        if (writes != i) begin
            $display("FAIL %0d writes after finishing", writes - i);
            errors = errors + 1;
        end
        if (busy || !cs_n) begin
            $display("FAIL busy=%0d cs_n=%0d after finishing", busy, cs_n);
            errors = errors + 1;
        end
        $writememh("captured.hex", mem);
        $display("RESULT done=%0d err_header=%0d err_crc=%0d busy=%0d count=%0d writes=%0d last_strb=%b errors=%0d",
                 done, err_header, err_crc, busy, word_count, writes, last_strb, errors);
        $finish;
    end
endmodule
