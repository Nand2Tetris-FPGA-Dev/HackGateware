`default_nettype none

// PSRAM spike: after power-on writes N_WORDS words through psram_ctrl, reads
// them back and compares. LED 0 = pass, LED 1 = done, LED 2 = fail.
// While S1 is held the LEDs show the first read's latency in cycles (max 63).
// LEDs are active low.
module top #(
    parameter N_WORDS = 32768
) (
    input  wire        clk,
    input  wire        btn_s1,
    input  wire        btn_s2,
    output wire [5:0]  led,
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds
);

    reg [7:0] por_count = 0;
    wire por = ~por_count[7];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_held;
    reset_sync s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_held));

    reg req_valid = 0, busy = 0, reading = 0, done = 0, bad = 0;
    reg [15:0] i = 0;
    reg [15:0] i_mul = 0;  // i * 16'h9E37 as a running sum (gowin_pack fails on DSPs)
    reg [5:0] latency = 0;
    reg [5:0] lat_count = 0;
    wire req_ready, rsp_valid, init_done;
    wire [31:0] rsp_rdata;
    wire [31:0] pattern = {i ^ 16'h5A5A, i_mul};

    psram_ctrl #(.CLK_HZ(27_000_000)) psram (
        .clk(clk), .rst_n(~por),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(~reading),
        .req_addr({6'b0, i, 2'b00}), .req_wdata(pattern), .req_wstrb(4'hf),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq(IO_psram_dq), .IO_psram_rwds(IO_psram_rwds)
    );

    always @(posedge clk) begin
        if (por) begin
            req_valid <= 0;
            busy <= 0;
            reading <= 0;
            done <= 0;
            bad <= 0;
            i <= 0;
            i_mul <= 0;
        end else begin
            if (init_done && !done && !busy && !req_valid)
                req_valid <= 1;

            if (req_valid && req_ready) begin
                req_valid <= 0;
                busy <= 1;
                lat_count <= 1;
            end else if (busy && lat_count != 6'd63) begin
                lat_count <= lat_count + 1'b1;
            end

            if (rsp_valid) begin
                busy <= 0;
                if (reading && rsp_rdata != pattern) bad <= 1;
                if (reading && i == 0) latency <= lat_count;
                if (i == N_WORDS - 1) begin
                    i <= 0;
                    i_mul <= 0;
                    if (reading) done <= 1;
                    reading <= 1;
                end else begin
                    i <= i + 1'b1;
                    i_mul <= i_mul + 16'h9E37;
                end
            end
        end
    end

    assign led = s1_held ? ~latency : ~{3'b000, done & bad, done, done & ~bad};

endmodule

`default_nettype wire
