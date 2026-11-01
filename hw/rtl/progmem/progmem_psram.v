`default_nettype none

// Program memory in PSRAM, on psram_ctrl's host port. Each 32-bit word holds
// two instructions: 2k in bits [15:0], 2k+1 in [31:16], at byte address 4k.
//
// A buffer in LUT RAM keeps BLOCKS blocks of 32 instructions (16 words), tagged
// by fetch_addr[14:5]. A miss reads its block with a burst into the next slot,
// round-robin. The burst starts at the missed word and wraps within the block
// (psram_ctrl), so word w of a filling slot is in once (w - start) mod 16 < count.
//
// Costs at 27 MHz, counted from fetch_req: a buffered word is answered in the
// same cycle, a miss in 33 (the cycle after its word arrives), and a word still
// on its way as soon as it lands. A miss to another block waits for the burst on
// the bus to end (65 cycles from its request).
//
// Fetch port as progmem_sim, except fetch_ready can come in the cycle of
// fetch_req. It's high for one cycle per fetch. Load port as boot_loader drives
// it; load_ready comes with the controller's write response, so the word is in
// PSRAM by then. A missed fetch goes to the controller before a load, even in
// the same cycle. Any load clears every slot. One request at a time, and
// req_valid is only raised with req_ready.
//
// rst_n goes with psram_ctrl's power-on reset only. A fetch waiting here when
// rst_n falls never gets fetch_ready, so the CPU's own reset (S1) must not
// reset this module.
module progmem_psram #(
    parameter BLOCKS = 8        // power of two, 2-16; 16 overfills the GW1NR-9 LUTs
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        fetch_req,
    input  wire [14:0] fetch_addr,
    output wire        fetch_ready,
    output wire [15:0] fetch_data,
    input  wire        load_valid,
    output wire        load_ready,
    input  wire [14:0] load_addr,
    input  wire [31:0] load_data,
    input  wire [3:0]  load_strb,
    output wire        req_valid,
    input  wire        req_ready,
    output wire        req_we,
    output wire        req_burst,
    output wire [23:0] req_addr,
    output wire [31:0] req_wdata,
    output wire [3:0]  req_wstrb,
    input  wire        rsp_valid,
    input  wire        rsp_word,
    input  wire [31:0] rsp_rdata
);

    localparam SW = $clog2(BLOCKS);

    reg busy = 0;      // a request is with the controller
    reg busy_we = 0;
    reg pending = 0;   // a fetch waits for its word
    reg [14:0] pend_addr = 0;

    reg [BLOCKS-1:0] valid = 0;
    reg [10*BLOCKS-1:0] tags = 0;
    reg [SW-1:0] next_slot = 0;
    reg [SW-1:0] fill_slot = 0;
    reg [3:0] fill_start = 0;
    reg [4:0] fill_count = 0;

    reg [31:0] buf_mem [0:BLOCKS*16-1];

    wire active = fetch_req || pending;
    wire [14:0] addr = pending ? pend_addr : fetch_addr;

    wire [BLOCKS-1:0] match;
    genvar g;
    generate
        for (g = 0; g < BLOCKS; g = g + 1) begin : tag_cmp
            assign match[g] = valid[g] && tags[10*g +: 10] == addr[14:5];
        end
    endgenerate

    // Tags are unique, so at most one bit of m is set
    function [SW-1:0] encode(input [BLOCKS-1:0] m);
        integer k;
        begin
            encode = 0;
            for (k = 0; k < BLOCKS; k = k + 1)
                if (m[k]) encode = encode | k[SW-1:0];
        end
    endfunction

    wire in_buf = |match;
    wire [SW-1:0] slot = encode(match);

    wire [3:0] since_start = addr[4:1] - fill_start;
    wire arrived = slot != fill_slot || {1'b0, since_start} < fill_count;
    wire [31:0] word = buf_mem[{slot, addr[4:1]}];

    assign fetch_ready = rst_n && active && in_buf && arrived;
    assign fetch_data = addr[0] ? word[31:16] : word[15:0];

    // A fetch that waits for a word of the filling slot needs no request. The
    // address and req_we go by active, so a load in the same cycle as a hit
    // waits a cycle.
    wire read = active && !in_buf;
    assign req_valid = rst_n && req_ready && !busy && (read || (load_valid && !active));
    assign req_we = !active;
    assign req_burst = active;
    assign req_addr = {8'b0, active ? addr[14:1] : load_addr[14:1], 2'b00};
    assign req_wdata = load_data;
    assign req_wstrb = load_strb;
    assign load_ready = rsp_valid && busy && busy_we;

    wire fill = rst_n && rsp_word && busy && !busy_we;

    always @(posedge clk)
        if (fill) buf_mem[{fill_slot, fill_start + fill_count[3:0]}] <= rsp_rdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            pending <= 1'b0;
            valid <= 0;
        end else begin
            if (fetch_ready) begin
                pending <= 1'b0;
            end else if (fetch_req) begin
                pending <= 1'b1;
                pend_addr <= fetch_addr;
            end
            if (fill) fill_count <= fill_count + 1'b1;
            if (req_valid) begin
                busy <= 1'b1;
                busy_we <= req_we;
                if (req_we) begin
                    valid <= 0;
                end else begin
                    valid[next_slot] <= 1'b1;
                    tags[10*next_slot +: 10] <= addr[14:5];
                    fill_slot <= next_slot;
                    fill_start <= addr[4:1];
                    fill_count <= 0;
                    next_slot <= next_slot + 1'b1;
                end
            end
            if (rsp_valid && busy) busy <= 1'b0;
        end
    end

endmodule

`default_nettype wire
