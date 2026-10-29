`default_nettype none

// Program memory in PSRAM, on psram_ctrl's host port. Each 32-bit word holds
// two instructions: 2k in bits [15:0], 2k+1 in [31:16], at byte address 4k.
// A one-line buffer keeps the last word read, so a fetch from the same line
// answers in one cycle; a miss costs a PSRAM read (35 cycles at 27 MHz).
//
// Fetch port as progmem_sim. Load port as boot_loader drives it; load_ready
// comes with the controller's write response, so the word is in PSRAM by then.
// A missed fetch goes to the controller before a load, even in the same cycle.
// Any load clears the buffer. One request at a time, and req_valid is only
// raised with req_ready.
//
// rst_n goes with psram_ctrl's power-on reset only. A fetch waiting here when
// rst_n falls never gets fetch_ready, so the CPU's own reset (S1) must not
// reset this module.
module progmem_psram (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        fetch_req,
    input  wire [14:0] fetch_addr,
    output reg         fetch_ready,
    output wire [15:0] fetch_data,
    input  wire        load_valid,
    output wire        load_ready,
    input  wire [14:0] load_addr,
    input  wire [31:0] load_data,
    input  wire [3:0]  load_strb,
    output wire        req_valid,
    input  wire        req_ready,
    output wire        req_we,
    output wire [23:0] req_addr,
    output wire [31:0] req_wdata,
    output wire [3:0]  req_wstrb,
    input  wire        rsp_valid,
    input  wire [31:0] rsp_rdata
);

    reg busy = 0;      // a request is with the controller
    reg busy_we = 0;
    reg pending = 0;   // a missed fetch waits for its read
    reg [14:0] pend_addr = 0;
    reg line_valid = 0;
    reg [13:0] line_tag = 0;
    reg [31:0] line_data = 0;
    reg upper = 0;     // fetch_data is the high half of line_data

    initial fetch_ready = 0;

    // Read out of the buffer for hits and misses alike, so the tag compare
    // stays off the data path
    assign fetch_data = upper ? line_data[31:16] : line_data[15:0];

    wire hit = line_valid && line_tag == fetch_addr[14:1];
    wire miss = fetch_req && !hit;
    // hit only reaches req_valid; the address and req_we go by fetch_req, so a
    // load in the same cycle as a hit waits a cycle
    wire sel_read = pending || fetch_req;
    wire [14:0] read_addr = pending ? pend_addr : fetch_addr;

    assign req_valid = rst_n && req_ready && !busy && (pending || miss || (load_valid && !fetch_req));
    assign req_we = !sel_read;
    assign req_addr = {8'b0, sel_read ? read_addr[14:1] : load_addr[14:1], 2'b00};
    assign req_wdata = load_data;
    assign req_wstrb = load_strb;
    assign load_ready = rsp_valid && busy && busy_we;

    always @(posedge clk) begin
        fetch_ready <= 1'b0;
        if (!rst_n) begin
            busy <= 1'b0;
            pending <= 1'b0;
            line_valid <= 1'b0;
        end else begin
            if (fetch_req && hit) begin
                fetch_ready <= 1'b1;
                upper <= fetch_addr[0];
            end
            if (miss) begin
                pending <= 1'b1;
                pend_addr <= fetch_addr;
            end
            if (req_valid) begin
                busy <= 1'b1;
                busy_we <= req_we;
                if (req_we) line_valid <= 1'b0;
            end
            if (rsp_valid && busy) begin
                busy <= 1'b0;
                if (!busy_we) begin
                    pending <= 1'b0;
                    line_valid <= 1'b1;
                    line_tag <= pend_addr[14:1];
                    line_data <= rsp_rdata;
                    fetch_ready <= 1'b1;
                    upper <= pend_addr[0];
                end
            end
        end
    end

endmodule

`default_nettype wire
