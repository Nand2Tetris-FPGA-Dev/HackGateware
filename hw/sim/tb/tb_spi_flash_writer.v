`timescale 1ns / 1ps

// spi_flash_writer against spi_flash_model. ops.txt holds one op per line,
// "op addr len" (addr in hex): 0 erase 4 KB, 1 erase 64 KB, 2 program len bytes
// from buf.hex, 9 = raw page program from the tb with no WREN first.
// Prints "DONE op addr rdsr=N" per op; the model's +DUMP shows the result.
module tb_spi_flash_writer;
    reg clk = 0, rst_n = 0, start = 0;
    reg [1:0] op = 0;
    reg [23:0] addr = 0;
    reg [8:0] len = 0;
    wire [7:0] buf_addr;
    reg [7:0] buf_data = 0;
    wire busy, done;
    wire dut_cs_n, dut_sck, dut_mosi, miso;
    integer errors = 0, fd, n, o, a, l, i, rdsr_before;

    reg [7:0] bufmem [0:255];
    always @(posedge clk) buf_data <= bufmem[buf_addr];

    // the tb takes the bus for raw transfers
    reg raw = 0, raw_cs_n = 1, raw_sck = 0, raw_mosi = 0;
    wire cs_n = raw ? raw_cs_n : dut_cs_n;
    wire sck = raw ? raw_sck : dut_sck;
    wire mosi = raw ? raw_mosi : dut_mosi;

    spi_flash_writer #(.HALF_PERIOD(2)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .op(op), .addr(addr), .len(len),
        .buf_addr(buf_addr), .buf_data(buf_data), .busy(busy), .done(done),
        .flash_cs_n(dut_cs_n), .flash_clk(dut_sck), .flash_mosi(dut_mosi),
        .flash_miso(miso)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(cs_n), .clk(sck), .mosi(mosi), .miso(miso)
    );

    always #18.5 clk = ~clk;

    always @(posedge clk) begin
        if (cs_n && sck) begin
            $display("FAIL sck high while cs_n high");
            errors = errors + 1;
        end
        if (done && flash.wip) begin
            $display("FAIL done while WIP is 1");
            errors = errors + 1;
        end
    end

    task raw_byte(input [7:0] b);
        integer k;
        for (k = 7; k >= 0; k = k - 1) begin
            raw_mosi = b[k];
            #100 raw_sck = 1;
            #100 raw_sck = 0;
        end
    endtask

    task raw_program(input [23:0] a, input integer n);
        integer k;
        begin
            raw = 1;
            #100 raw_cs_n = 0;
            raw_byte(8'h02);
            raw_byte(a[23:16]);
            raw_byte(a[15:8]);
            raw_byte(a[7:0]);
            for (k = 0; k < n; k = k + 1) raw_byte(bufmem[k]);
            #100 raw_cs_n = 1;
            #100 raw = 0;
        end
    endtask

    task run_op(input [1:0] o, input [23:0] a, input [8:0] l);
        integer cycles, pulses;
        begin
            rdsr_before = flash.rdsr_count;
            @(negedge clk);
            if (busy) begin
                $display("FAIL busy before start");
                errors = errors + 1;
            end
            op = o;
            addr = a;
            len = l;
            start = 1;
            @(negedge clk);
            start = 0;
            op = 0;
            addr = 0;
            len = 0;
            if (!busy) begin
                $display("FAIL busy low after start");
                errors = errors + 1;
            end
            cycles = 0;
            while (!done && cycles < 2000000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("FAIL no done for op %0d at %06x", o, a);
                errors = errors + 1;
            end
            pulses = 0;
            while (done) begin
                @(negedge clk);
                pulses = pulses + 1;
            end
            if (pulses != 1) begin
                $display("FAIL done high for %0d cycles", pulses);
                errors = errors + 1;
            end
            $display("DONE %0d %06x rdsr=%0d", o, a, flash.rdsr_count - rdsr_before);
        end
    endtask

    initial begin
        $readmemh("buf.hex", bufmem);
        repeat (3) @(negedge clk);
        rst_n = 1;
        fd = $fopen("ops.txt", "r");
        n = $fscanf(fd, "%d %h %d\n", o, a, l);
        while (n == 3) begin
            if (o == 9) raw_program(a, l);
            else run_op(o, a, l);
            n = $fscanf(fd, "%d %h %d\n", o, a, l);
        end
        $fclose(fd);
        // let a raw op's WIP finish before the dump
        wait (!flash.wip);
        if (errors == 0) $display("PASS");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
