`timescale 1ns / 1ps

// psram_ctrl -> W955D8MBYA model (hw/third_party/psram_controller). The model
// checks PSRAM timing and protocol and counts violations in error_count.
// With HOST_MODEL defined, psram_host_model stands in for both.
// Runs ops.hex, one {op, addr, data, strb} per line (4+24+32+4 bits):
//   0 read, 1 write, 2 read then reset `data` cycles after it is accepted,
//   3 burst read, 4 burst read then reset as 2, f end.
// The first request is presented right after reset, before init_done (after
// init_done with HOST_MODEL, which doesn't allow a held request).
// After an accept the tb scrambles the request inputs (they must be captured),
// or with +PIPE=1 presents the next request at once (held while busy).
// Prints INIT, ACC, RSP and WORD lines and a RESULT line.
module tb_psram_ctrl;
`ifdef CLK_HZ
    localparam integer CLK_HZ = `CLK_HZ;
`else
    localparam integer CLK_HZ = 27_000_000;
`endif
    localparam real HALF_NS = 500_000_000.0 / CLK_HZ;

    reg clk = 0, rst_n = 0;
    reg req_valid = 0, req_we = 0, req_burst = 0;
    reg [23:0] req_addr = 0;
    reg [31:0] req_wdata = 0;
    reg [3:0] req_wstrb = 0;
    wire req_ready, rsp_valid, rsp_word, init_done;
    wire [31:0] rsp_rdata;
    wire [1:0] ck, ck_n, cs_n, reset_n, rwds;
    wire [15:0] dq;

`ifdef HOST_MODEL
    psram_host_model dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_burst(req_burst),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_word(rsp_word), .rsp_rdata(rsp_rdata),
        .init_done(init_done)
    );
    localparam integer MODEL_ERRORS = 0;
`else
    psram_ctrl #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_burst(req_burst),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_word(rsp_word), .rsp_rdata(rsp_rdata),
        .init_done(init_done),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n),
        .O_psram_reset_n(reset_n), .IO_psram_dq(dq), .IO_psram_rwds(rwds)
    );

    w955d8mbya_model psram (
        .ck(ck), .ck_n(ck_n), .cs_n(cs_n), .reset_n(reset_n), .dq(dq), .rwds(rwds)
    );
`endif

    always #(HALF_NS) clk = ~clk;

    reg [63:0] ops [0:4095];
    integer pipe = 0, errors = 0, cycle = 0, n_acc = 0, n_rsp = 0;
    integer i, k, acc_cycle = 0, init_cycles, seed = 7;
    reg busy = 0, acc_we = 0, acc_burst = 0;
    reg [23:0] acc_addr = 0;
    integer acc_n = 0, wk = 0;

    // Handshake rules, checked on every edge
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!rst_n) begin
            busy <= 0;
        end else begin
            if (req_ready && !init_done) begin
                $display("FAIL req_ready before init_done at %0d", cycle);
                errors = errors + 1;
            end
            if (rsp_valid) begin
                if (!busy) begin
                    $display("FAIL response with no request at %0d", cycle);
                    errors = errors + 1;
                end
                $display("RSP req=%0d we=%0d burst=%0d addr=%06h data=%08h lat=%0d",
                         acc_n, acc_we, acc_burst, acc_addr, rsp_rdata, cycle - acc_cycle);
                n_rsp = n_rsp + 1;
                busy <= 0;
            end
            if (rsp_word) begin
                if (!busy || !acc_burst || acc_we) begin
                    $display("FAIL word strobe outside a burst at %0d", cycle);
                    errors = errors + 1;
                end
                $display("WORD req=%0d k=%0d addr=%06h data=%08h lat=%0d", acc_n, wk,
                         {acc_addr[23:6], acc_addr[5:2] + wk[3:0], 2'b00}, rsp_rdata,
                         cycle - acc_cycle);
                wk = wk + 1;
            end
            if (req_valid && req_ready) begin
                if (busy && !rsp_valid) begin
                    $display("FAIL accepted while busy at %0d", cycle);
                    errors = errors + 1;
                end
                $display("ACC cycle=%0d", cycle);
                acc_cycle <= cycle;
                acc_we <= req_we;
                acc_burst <= req_burst && !req_we;
                acc_addr <= req_addr;
                acc_n <= n_acc;
                wk = 0;
                n_acc = n_acc + 1;
                busy <= 1;
            end
        end
    end

    task present(input [63:0] op);
        begin
            req_valid = 1;
            req_we = op[63:60] == 4'h1;
            req_burst = op[63:60] == 4'h3 || op[63:60] == 4'h4;
            req_addr = op[59:36];
            req_wdata = op[35:4];
            req_wstrb = op[3:0];
        end
    endtask

    initial begin
        if (!$value$plusargs("PIPE=%d", pipe)) pipe = 0;
        $readmemh("ops.hex", ops);
        repeat (4) @(negedge clk);
        rst_n = 1;
        init_cycles = 0;
        i = 0;
`ifdef HOST_MODEL
        while (!init_done) begin
            @(negedge clk);
            init_cycles = init_cycles + 1;
        end
`endif
        present(ops[0]);
        while (ops[i][63:60] != 4'hf) begin
            // wait for the accepting edge
            while (!req_ready) begin
                @(negedge clk);
                if (!init_done) init_cycles = init_cycles + 1;
            end
            @(negedge clk);
            if (i == 0) $display("INIT cycles=%0d", init_cycles);
            if (ops[i][63:60] == 4'h2 || ops[i][63:60] == 4'h4) begin
                req_valid = 0;
                repeat (ops[i][35:4] - 1) @(negedge clk);
                rst_n = 0;
                repeat (5) @(negedge clk);
                rst_n = 1;
                while (!init_done) @(negedge clk);
                i = i + 1;
                if (ops[i][63:60] != 4'hf) present(ops[i]);
            end else begin
                i = i + 1;
                if (pipe && ops[i][63:60] != 4'hf && ops[i][63:60] != 4'h2
                        && ops[i][63:60] != 4'h4) begin
                    present(ops[i]);
                end else begin
                    req_valid = 0;
                    req_we = $random(seed);
                    req_burst = $random(seed);
                    req_addr = $random(seed);
                    req_wdata = $random(seed);
                    req_wstrb = $random(seed);
                    while (busy) @(negedge clk);
                    if (ops[i][63:60] != 4'hf) present(ops[i]);
                end
            end
        end
        req_valid = 0;
        while (busy) @(negedge clk);
        repeat (8) @(negedge clk);
`ifdef HOST_MODEL
        $display("RESULT errors=%0d model_errors=%0d acc=%0d rsp=%0d",
                 errors, MODEL_ERRORS, n_acc, n_rsp);
`else
        $display("RESULT errors=%0d model_errors=%0d acc=%0d rsp=%0d",
                 errors, psram.error_count, n_acc, n_rsp);
`endif
        $finish;
    end

    initial begin
        #(HALF_NS * 2 * 2_000_000);
        $display("FAIL timeout");
        $finish;
    end
endmodule
