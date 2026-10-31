`timescale 1ns / 1ps

// Stand-in for psram_ctrl's host port. A request is taken on req_valid &&
// req_ready; the edge READ_LAT or WRITE_LAT cycles after that one sees
// rsp_valid, and req_ready is high again in that cycle, as psram_ctrl does at
// 27 MHz (tb_psram_ctrl counts latency the same way). Writes reach mem
// only at the response. Holds DEPTH 32-bit words from byte address 0.
// A burst read (req_burst) gives the 16 words of the 64-byte group holding
// req_addr in wrap order, word k's rsp_word BURST_FIRST + 2k cycles after the
// accept, then rsp_valid at BURST_FIRST + 33, as psram_ctrl does at 27 MHz.
// Unlike psram_ctrl, raising req_valid while req_ready is low is an error.
module psram_host_model #(
    parameter READ_LAT = 35,
    parameter WRITE_LAT = 34,
    parameter BURST_FIRST = 32,
    parameter DEPTH = 16384
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire        req_burst,
    input  wire [23:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output reg         rsp_valid,
    output reg         rsp_word,
    output reg  [31:0] rsp_rdata,
    output wire        init_done
);

    reg [31:0] mem [0:DEPTH-1];
    reg [7:0] init_count = 0;
    integer busy = 0, i;
    reg we, burst;
    integer elapsed = 0, k;
    reg [23:0] addr;
    reg [31:0] wdata;
    reg [3:0] wstrb;

    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'd0;
        rsp_valid = 0;
        rsp_word = 0;
        rsp_rdata = 0;
    end

    assign init_done = init_count == 100;
    assign req_ready = init_done && busy == 0;

    always @(posedge clk) begin
        rsp_valid <= 1'b0;
        rsp_word <= 1'b0;
        if (!rst_n) begin
            init_count <= 0;
            busy <= 0;
        end else begin
            if (!init_done) init_count <= init_count + 1'b1;
            if (req_valid && !req_ready)
                $error("psram_host_model: req_valid while req_ready is low");
            if (req_valid && req_ready) begin
                if (req_addr[1:0] != 0 || req_addr / 4 >= DEPTH)
                    $error("psram_host_model: bad address %h", req_addr);
                we <= req_we;
                burst <= req_burst && !req_we;
                elapsed <= 0;
                addr <= req_addr;
                wdata <= req_wdata;
                wstrb <= req_wstrb;
                busy <= (req_we ? WRITE_LAT : req_burst ? BURST_FIRST + 33 : READ_LAT) - 1;
            end else if (busy != 0) begin
                busy <= busy - 1;
                elapsed <= elapsed + 1;
                k = (elapsed - (BURST_FIRST - 2)) / 2;
                if (burst && elapsed >= BURST_FIRST - 2 && k < 16
                        && (elapsed - (BURST_FIRST - 2)) % 2 == 0) begin
                    rsp_word <= 1'b1;
                    rsp_rdata <= mem[{addr[23:6], addr[5:2] + k[3:0]}];
                end
                if (busy == 1) begin
                    rsp_valid <= 1'b1;
                    if (we) begin
                        for (i = 0; i < 4; i = i + 1)
                            if (wstrb[i]) mem[addr[23:2]][8*i +: 8] <= wdata[8*i +: 8];
                    end else if (!burst) begin
                        rsp_rdata <= mem[addr[23:2]];
                    end
                end
            end
        end
    end

endmodule
