// Program ROM in block RAM, filled from `ROM_HEX at build time. Answers a fetch
// one cycle later; addresses past WORDS read 0.
// For synthesis, hacktools writes ROM_HEX into rom_path.vh (hw build --rom).
`ifdef SYNTHESIS
`include "rom_path.vh"
`endif

module progmem_rom #(
    parameter WORDS = 2048
) (
    input  wire        clk,
    input  wire        fetch_req,
    input  wire [14:0] fetch_addr,
    output reg         fetch_ready,
    output wire [15:0] fetch_data
);

    localparam AW = $clog2(WORDS);

    reg [15:0] mem [0:WORDS-1];
    reg [15:0] word = 16'd0;
    reg in_range = 1'b0;

    // Zero the unused words in simulation only. yosys drops the $readmemh data
    // if the same initial block also loops over mem; on the FPGA, words the file
    // doesn't set are already 0 ("init no_undef" in yosys techlibs/gowin/brams.txt).
    integer i;
    initial begin
`ifndef SYNTHESIS
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'd0;
`endif
`ifdef ROM_HEX
        $readmemh(`ROM_HEX, mem);
`endif
        fetch_ready = 1'b0;
    end

    always @(posedge clk) begin
        fetch_ready <= fetch_req;
        word <= mem[fetch_addr[AW-1:0]];
        in_range <= fetch_addr < WORDS;
    end

    assign fetch_data = in_range ? word : 16'd0;

endmodule
