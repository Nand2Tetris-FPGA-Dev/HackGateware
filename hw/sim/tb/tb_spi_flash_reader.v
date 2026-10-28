`timescale 1ns / 1ps

// Flash holds byte[a] = (a*7+3) & 0xff. Reads 300 bytes at 0x20000 with random
// back-pressure, stops, then reads 4 bytes at 0x10.
module tb_spi_flash_reader;
    reg clk = 0, rst_n = 0, start = 0, stop = 0, out_ready = 0;
    reg [23:0] addr = 0;
    wire out_valid;
    wire [7:0] out_byte;
    wire cs_n, sck, mosi, miso;
    integer errors = 0, count, seed = 5;
    reg [23:0] expect_addr;

    spi_flash_reader #(.HALF_PERIOD(2)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .addr(addr), .stop(stop),
        .out_valid(out_valid), .out_byte(out_byte), .out_ready(out_ready),
        .flash_cs_n(cs_n), .flash_clk(sck), .flash_mosi(mosi), .flash_miso(miso)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(cs_n), .clk(sck), .mosi(mosi), .miso(miso)
    );

    always #18.5 clk = ~clk;

    // SCK must idle low whenever the chip is deselected
    always @(posedge clk)
        if (cs_n && sck) begin
            $display("FAIL sck high while cs_n high");
            errors = errors + 1;
        end

    task read_bytes(input [23:0] a, input integer n, input random_ready);
        begin
            @(negedge clk);
            addr = a;
            start = 1;
            @(negedge clk);
            start = 0;
            expect_addr = a;
            count = 0;
            while (count < n) begin
                @(negedge clk);
                // Ready 1 cycle in 64: stalls are longer than a byte takes, so
                // a reader that doesn't pause SCK would lose bytes
                out_ready = random_ready ? (($random(seed) & 63) == 0) : 1'b1;
                @(posedge clk);
                if (out_valid && out_ready) begin
                    if (out_byte !== ((expect_addr * 7 + 3) & 8'hff)) begin
                        $display("FAIL byte at %06x: got %02x", expect_addr, out_byte);
                        errors = errors + 1;
                    end
                    expect_addr = expect_addr + 1;
                    count = count + 1;
                end
            end
            @(negedge clk);
            out_ready = 0;
            stop = 1;
            @(negedge clk);
            stop = 0;
            repeat (4) @(negedge clk);
            if (cs_n !== 1'b1) begin
                $display("FAIL cs_n not high after stop");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        if (cs_n !== 1'b1 || sck !== 1'b0) begin
            $display("FAIL idle state");
            errors = errors + 1;
        end
        read_bytes(24'h020000, 300, 1);
        read_bytes(24'h000010, 4, 0);
        if (errors == 0) $display("PASS");
        $finish;
    end

    initial begin
        #10000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
