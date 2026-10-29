`timescale 1ns / 1ps

// Simulation model of an SPI NOR flash that only answers READ (0x03), mode 0:
// it samples MOSI on SCK rising edges and shifts data out on falling edges.
// Contents come from HEXFILE, one byte per line; addresses wrap at SIZE.
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
    reg [31:0] cmd;
    reg [23:0] addr;
    reg [7:0] current;
    integer nbits, bitpos, i;

    initial begin
        for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'hff;
        if (HEXFILE != "") $readmemh(HEXFILE, mem);
        miso = 1'bz;
        nbits = 0;
    end

    always @(negedge cs_n) begin
        nbits = 0;
        bitpos = 0;
    end

    always @(posedge cs_n) miso = 1'bz;

    always @(posedge clk) begin
        if (!cs_n && nbits < 32) begin
            cmd = {cmd[30:0], mosi};
            nbits = nbits + 1;
            if (nbits == 32) begin
                if (cmd[31:24] != 8'h03) $display("ERROR flash model: command %02x", cmd[31:24]);
                addr = cmd[23:0];
            end
        end
    end

    always @(negedge clk) begin
        if (!cs_n && nbits >= 32) begin
            if (bitpos == 0) current = mem[addr % SIZE];
            miso = current[7 - bitpos];
            bitpos = bitpos + 1;
            if (bitpos == 8) begin
                bitpos = 0;
                addr = addr + 1;
            end
        end
    end

endmodule
