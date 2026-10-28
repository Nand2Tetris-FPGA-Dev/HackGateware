`default_nettype none

// Controller for the Tang Nano 9K's internal PSRAM: two W955D8MBYA x8 HyperBus
// dies in lockstep, one 32-bit word per access (16 bits in each die). Single
// word reads and writes of the memory space, CR0 left at its default.
//
// Ported from psram_controller v0.3.0 (rtl/psram_core.veryl, rtl/psram_phy.veryl),
// https://github.com/takayuki-nagata/psram_controller at a2c41bd
// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT (see hw/third_party/psram_controller/LICENSE)
//
// Host side (upstream docs/integration.md): a request is taken on
// req_valid && req_ready, one at a time, and inputs must hold until then.
// rsp_valid pulses 34 + R cycles after the accept for a read, 33 + R for a
// write, R = tRWR in cycles (1 up to 27.7 MHz); req_ready is high again in that
// cycle. req_addr is a 4-aligned byte address below 8 MB.
//
// CK runs at clk/2. It's registered on the falling edge of clk while CS#, DQ
// and RWDS change on the rising edge, so data is centered on CK.
module psram_ctrl #(
    parameter CLK_HZ = 27_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire [23:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output reg         rsp_valid,
    output reg  [31:0] rsp_rdata,
    output wire        init_done,
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds
);

    // W955D8MBYA datasheet sec. 11 / Table 14, with upstream's margins
    localparam [63:0] NS = 64'd1_000_000_000;
    localparam [63:0] RESET_CYCLES = (64'd400 * CLK_HZ + NS - 1) / NS;      // tRP >= 200 ns
    localparam [63:0] INIT_CYCLES = (64'd200_000 * CLK_HZ + NS - 1) / NS;   // tVCS >= 150 us
    localparam [63:0] RWR_CYCLES = (64'd36 * CLK_HZ + NS - 1) / NS;         // tRWR >= 36 ns

    // Fixed latency of 2 x 6 clocks (CR0 default, datasheet Table 8), two
    // cycles per clock. It counts from the third CA clock, so data is on
    // clock 15 (datasheet Figures 9 and 11).
    localparam LATENCY = 2 * 2 * 6;
    localparam PREAMBLE_T = LATENCY - 6;  // RWDS low a clock before write data
    localparam WRITE_T = LATENCY - 3;
    localparam READ_T = LATENCY - 4;

    localparam RESET_ASSERT = 3'd0, RESET_WAIT = 3'd1, IDLE = 3'd2, SEND_CA = 3'd3,
               WAIT_LATENCY = 3'd4, WRITE_DATA = 3'd5, READ_DATA = 3'd6, RECOVERY = 3'd7;

    reg [2:0] state;
    reg [15:0] timer;
    reg [39:0] ca;
    reg we;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg cs_n, reset_n, ck, ck_en, dq_oe, rwds_oe;
    reg [15:0] dq_out;
    reg [1:0] rwds_out;
    wire [15:0] dq_in = IO_psram_dq;

    assign req_ready = state == IDLE;
    assign init_done = state != RESET_ASSERT && state != RESET_WAIT;

    // Command-Address, datasheet sec. 7.1 Tables 3-5. Each die holds 16 bits
    // of a word, so the die word address A20..A0 is req_addr[22:2].
    wire [20:0] word_addr = req_addr[22:2];
    wire [47:0] ca_req = {
        ~req_we,          // CA[47] 1 = read
        2'b00,            // CA[46:45] memory space, wrapped burst
        11'b0,            // CA[44:34] reserved
        word_addr[20:9],  // CA[33:22] row
        word_addr[8:3],   // CA[21:16] upper column
        13'b0,            // CA[15:3] reserved
        word_addr[2:0]    // CA[2:0] lower column
    };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= RESET_ASSERT;
            timer <= 0;
            ca <= 0;
            we <= 0;
            wdata <= 0;
            wstrb <= 0;
            rsp_valid <= 0;
            rsp_rdata <= 0;
            cs_n <= 1;
            reset_n <= 0;
            ck <= 0;
            ck_en <= 0;
            dq_oe <= 0;
            dq_out <= 0;
            rwds_oe <= 0;
            rwds_out <= 0;
        end else begin
            rsp_valid <= 0;

            case (state)
                RESET_ASSERT:
                    if (timer >= RESET_CYCLES) begin
                        reset_n <= 1;
                        timer <= 0;
                        state <= RESET_WAIT;
                    end else begin
                        timer <= timer + 1'b1;
                    end

                RESET_WAIT:
                    if (timer >= INIT_CYCLES) begin
                        timer <= 0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 1'b1;
                    end

                // CS# low and CA byte 0 on DQ for the first CK rise
                IDLE: begin
                    timer <= 0;
                    if (req_valid) begin
                        we <= req_we;
                        wdata <= req_wdata;
                        wstrb <= req_wstrb;
                        ca <= ca_req[39:0];
                        cs_n <= 0;
                        ck_en <= 1;
                        dq_oe <= 1;
                        dq_out <= {2{ca_req[47:40]}};
                        state <= SEND_CA;
                    end
                end

                // CA bytes 1-5 on the next five CK edges (clocks 1-3)
                SEND_CA: begin
                    ck <= ~ck;
                    timer <= timer + 1'b1;
                    case (timer)
                        16'd1: dq_out <= {2{ca[39:32]}};
                        16'd2: dq_out <= {2{ca[31:24]}};
                        16'd3: dq_out <= {2{ca[23:16]}};
                        16'd4: dq_out <= {2{ca[15:8]}};
                        16'd5: dq_out <= {2{ca[7:0]}};
                        16'd6: begin
                            timer <= 0;
                            dq_oe <= 0;
                            dq_out <= 0;
                            state <= WAIT_LATENCY;
                        end
                        default: ;
                    endcase
                end

                WAIT_LATENCY: begin
                    ck <= ~ck;
                    timer <= timer + 1'b1;
                    if (we) begin
                        if (timer >= PREAMBLE_T) begin
                            rwds_oe <= 1;
                            rwds_out <= 2'b00;
                        end
                        if (timer >= WRITE_T) begin
                            timer <= 0;
                            dq_oe <= 1;
                            dq_out <= wdata[15:0];
                            rwds_out <= ~wstrb[1:0];  // RWDS high masks the byte
                            state <= WRITE_DATA;
                        end
                    end else if (timer >= READ_T) begin
                        timer <= 0;
                        state <= READ_DATA;
                    end
                end

                // timer 0: low half goes out on CK rise, high half loaded
                // timer 1: high half goes out on CK fall, then end
                WRITE_DATA: begin
                    ck <= ~ck;
                    timer <= timer + 1'b1;
                    if (!timer[0]) begin
                        dq_out <= wdata[31:16];
                        rwds_out <= ~wstrb[3:2];
                    end else begin
                        dq_oe <= 0;
                        rwds_oe <= 0;
                        cs_n <= 1;
                        ck_en <= 0;
                        ck <= 0;
                        timer <= 0;
                        state <= RECOVERY;
                    end
                end

                // timer 0: CK rises on clock 15 and the dies launch the low half
                // timer 1, 2: sample each half a cycle after its CK edge
                // timer 3: CS# high; held a cycle longer so the last half is
                // still driven when sampled (datasheet Table 14 note 3)
                READ_DATA: begin
                    ck <= ~ck;
                    timer <= timer + 1'b1;
                    case (timer)
                        16'd1: rsp_rdata[15:0] <= dq_in;
                        16'd2: begin
                            rsp_rdata[31:16] <= dq_in;
                            ck_en <= 0;
                            ck <= 0;
                        end
                        16'd3: begin
                            cs_n <= 1;
                            ck_en <= 0;
                            ck <= 0;
                            timer <= 0;
                            state <= RECOVERY;
                        end
                        default: ;
                    endcase
                end

                // CS# high for tRWR, then respond
                RECOVERY:
                    if (timer >= RWR_CYCLES) begin
                        rsp_valid <= 1;
                        timer <= 0;
                        state <= IDLE;
                    end else begin
                        timer <= timer + 1'b1;
                    end

                default: state <= IDLE;
            endcase
        end
    end

    reg ck_q;
    always @(negedge clk or negedge rst_n)
        if (!rst_n) ck_q <= 0;
        else ck_q <= ck_en ? ck : 1'b0;

    assign O_psram_ck = {2{ck_q}};
    assign O_psram_ck_n = {2{~ck_q}};
    assign O_psram_cs_n = {2{cs_n}};
    assign O_psram_reset_n = {2{reset_n}};
    assign IO_psram_dq = dq_oe ? dq_out : 16'bz;
    assign IO_psram_rwds = rwds_oe ? rwds_out : 2'bz;

endmodule

`default_nettype wire
