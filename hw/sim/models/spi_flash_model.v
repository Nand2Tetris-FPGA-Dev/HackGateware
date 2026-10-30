`timescale 1ns / 1ps

// Simulation model of the board's SPI NOR flash (PUYA P25Q32H, datasheet Ver1.3),
// SPI mode 0: it samples MOSI on SCK rising edges and shifts data out on falling
// edges. Commands: READ 03h (s10.10), WREN 06h (s10.2), RDSR 05h (s10.5, S0 WIP,
// S1 WEL), sector erase 20h (s10.28), 64 KB block erase D8h (s10.30), page
// program 02h (s10.32, data wraps within the page). Erase and program need WEL,
// clear it when done, and hold WIP for +ERASE_US / +PROG_US. Without WEL the
// command prints "IGNORED xx"; anything but RDSR while WIP prints "BUSY xx".
// Contents come from HEXFILE, one byte per line; addresses wrap at SIZE.
// +DUMP=addr,len (hex) prints that range at the end of the run.
module spi_flash_model #(
    parameter HEXFILE = "",
    parameter SIZE = 262144
) (
    input  wire cs_n,
    input  wire clk,
    input  wire mosi,
    output reg  miso
);

    reg [7:0] mem [0:SIZE-1];
    reg [7:0] page [0:255];
    reg [255:0] page_set;
    reg [7:0] shift_in, op, current;
    reg [23:0] addr;
    reg wip, wel, busy_cmd;
    integer nbits, bitpos, i, erase_us, prog_us, wip_ns, rdsr_count;
    integer dump_addr, dump_len, r;
    reg [8*40:1] dump_arg;
    event wip_start;

    initial begin
        for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'hff;
        if (HEXFILE != "") $readmemh(HEXFILE, mem);
        miso = 1'bz;
        nbits = 0;
        busy_cmd = 0;
        wip = 0;
        wel = 0;
        rdsr_count = 0;
        if (!$value$plusargs("ERASE_US=%d", erase_us)) erase_us = 20;
        if (!$value$plusargs("PROG_US=%d", prog_us)) prog_us = 5;
    end

    always @(negedge cs_n) begin
        nbits = 0;
        bitpos = 0;
        page_set = 0;
        busy_cmd = 0;
    end

    always @(posedge clk) begin
        if (!cs_n) begin
            shift_in = {shift_in[6:0], mosi};
            nbits = nbits + 1;
            if (nbits == 8) begin
                op = shift_in;
                if (op == 8'h05) begin
                    rdsr_count = rdsr_count + 1;
                end else if (wip) begin
                    $display("BUSY %02x", op);
                    busy_cmd = 1;
                end else if (op != 8'h03 && op != 8'h06 && op != 8'h20 && op != 8'hd8
                             && op != 8'h02) begin
                    $display("ERROR flash model: command %02x", op);
                end
            end else if (nbits <= 32 && nbits % 8 == 0) begin
                addr = {addr[15:0], shift_in};
            end else if (nbits % 8 == 0 && op == 8'h02) begin
                page[(addr[7:0] + nbits / 8 - 5) % 256] = shift_in;
                page_set[(addr[7:0] + nbits / 8 - 5) % 256] = 1'b1;
            end
        end
    end

    always @(negedge clk) begin
        if (!cs_n && !busy_cmd) begin
            if (op == 8'h05 && nbits >= 8) begin
                if (bitpos == 0) current = {6'b0, wel, wip};
                miso = current[7 - bitpos];
                bitpos = (bitpos + 1) % 8;
            end else if (op == 8'h03 && nbits >= 32) begin
                if (bitpos == 0) current = mem[addr % SIZE];
                miso = current[7 - bitpos];
                bitpos = bitpos + 1;
                if (bitpos == 8) begin
                    bitpos = 0;
                    addr = addr + 1;
                end
            end
        end
    end

    // Writes start when CS# goes high, and only on a byte boundary
    always @(posedge cs_n) begin
        miso = 1'bz;
        if (nbits > 0 && !busy_cmd && (op == 8'h06 || op == 8'h20 || op == 8'hd8
                                        || op == 8'h02)) begin
            if (nbits % 8 != 0 || (op == 8'h06 && nbits != 8)
                    || ((op == 8'h20 || op == 8'hd8) && nbits != 32)
                    || (op == 8'h02 && nbits < 40)) begin
                $display("REJECTED %02x after %0d bits", op, nbits);
            end else if (op == 8'h06) begin
                wel = 1;
            end else if (!wel) begin
                $display("IGNORED %02x", op);
            end else begin
                if (op == 8'h20)
                    for (i = 0; i < 4096; i = i + 1)
                        mem[({addr[23:12], 12'h000} + i) % SIZE] = 8'hff;
                else if (op == 8'hd8)
                    for (i = 0; i < 65536; i = i + 1)
                        mem[({addr[23:16], 16'h0000} + i) % SIZE] = 8'hff;
                else
                    for (i = 0; i < 256; i = i + 1)
                        if (page_set[i])
                            mem[({addr[23:8], 8'h00} + i) % SIZE] =
                                mem[({addr[23:8], 8'h00} + i) % SIZE] & page[i];
                wip = 1;
                wip_ns = (op == 8'h02 ? prog_us : erase_us) * 1000;
                -> wip_start;
            end
        end
        nbits = 0;
    end

    always @(wip_start) begin
        #(wip_ns);
        wip = 0;
        wel = 0;
    end

    final begin
        if ($value$plusargs("DUMP=%s", dump_arg)) begin
            r = $sscanf(dump_arg, "%h,%h", dump_addr, dump_len);
            for (i = 0; i < dump_len; i = i + 1) begin
                if (i % 32 == 0) $write("DUMP %06x ", dump_addr + i);
                $write("%02x", mem[(dump_addr + i) % SIZE]);
                if (i % 32 == 31 || i == dump_len - 1) $write("\n");
            end
        end
    end

endmodule
