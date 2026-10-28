`timescale 1ns / 1ps

// progmem_psram -> psram_host_model, or with REAL_CTRL psram_ctrl -> the
// W955D8MBYA chip model. Runs ops.hex, one {op, delay, faddr, laddr, data, strb}
// per line (4+4+16+16+32+4 bits):
//   0 fetch faddr
//   1 load {laddr, data, strb}, held until load_ready like boot_loader
//   2 load, plus a fetch of faddr `delay` cycles after load_valid goes up
//   3 fetch faddr, then reset progmem_psram alone for a cycle `delay` cycles
//     later; the next op starts while that read is still out
//   4 idle for faddr cycles
//   5 load, with progmem_psram held in reset for its first `delay` cycles
//   f end
// The first op starts right after reset, before init_done.
// Prints FETCH, LOAD and ORDER lines and a RESULT line.
module tb_progmem_psram;
    localparam real HALF_NS = 500_000_000.0 / 27_000_000;

    reg clk = 0, rst_n = 0, pm_rst_n = 1;
    reg fetch_req = 0;
    reg [14:0] fetch_addr = 0;
    wire fetch_ready;
    wire [15:0] fetch_data;
    reg load_valid = 0;
    reg [14:0] load_addr = 0;
    reg [31:0] load_data = 0;
    reg [3:0] load_strb = 0;
    wire load_ready;
    wire req_valid, req_ready, req_we, rsp_valid, init_done;
    wire [23:0] req_addr;
    wire [31:0] req_wdata, rsp_rdata;
    wire [3:0] req_wstrb;

    progmem_psram dut (
        .clk(clk), .rst_n(rst_n & pm_rst_n),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr),
        .fetch_ready(fetch_ready), .fetch_data(fetch_data),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
    );

`ifdef REAL_CTRL
    wire [1:0] ck, ck_n, cs_n, reset_n, rwds;
    wire [15:0] dq;

    psram_ctrl #(.CLK_HZ(27_000_000)) mem (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n),
        .O_psram_reset_n(reset_n), .IO_psram_dq(dq), .IO_psram_rwds(rwds)
    );

    w955d8mbya_model psram (
        .ck(ck), .ck_n(ck_n), .cs_n(cs_n), .reset_n(reset_n), .dq(dq), .rwds(rwds)
    );
`define MODEL_ERRORS psram.error_count
`else
    psram_host_model mem (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .init_done(init_done)
    );
`define MODEL_ERRORS 0
`endif

    always #(HALF_NS) clk = ~clk;

    reg [75:0] ops [0:4095];
    integer cycle = 0, fetches = 0, readies = 0, i, t_fetch = 0, t_load = 0;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (fetch_ready) readies <= readies + 1;
        if (!pm_rst_n && req_valid) $display("FAIL request during reset at %0d", cycle);
        if (cycle > 2_000_000) begin
            $display("TIMEOUT");
            $finish;
        end
    end

    // Each task starts just after a clock edge and returns just after one.
    // Inputs are scrambled once taken, so the DUT has to capture them.
    task fetch(input [14:0] a);
        integer lat;
        begin
            fetch_req = 1;
            fetch_addr = a;
            @(posedge clk);
            #1 fetch_req = 0;
            fetch_addr = ~a;
            fetches = fetches + 1;
            lat = 1;
            while (!fetch_ready) begin
                @(posedge clk);
                #1 lat = lat + 1;
            end
            t_fetch = cycle;
            $display("FETCH addr=%h data=%h lat=%0d", a, fetch_data, lat);
            @(posedge clk);
            #1;
        end
    endtask

    task load(input [14:0] a, input [31:0] d, input [3:0] s);
        integer lat;
        begin
            load_valid = 1;
            load_addr = a;
            load_data = d;
            load_strb = s;
            lat = 0;
            while (!load_ready) begin
                @(posedge clk);
                #1 lat = lat + 1;
            end
            t_load = cycle;
`ifdef REAL_CTRL
            $display("LOAD addr=%h lat=%0d", a, lat);
`else
            // What the memory holds as load_ready is seen
            $display("LOAD addr=%h lat=%0d word=%h", a, lat, mem.mem[a >> 1]);
`endif
            @(posedge clk);
            #1 load_valid = 0;
            load_addr = ~a;
            load_data = ~d;
            load_strb = 0;
        end
    endtask

    task fetch_then_reset(input [14:0] a, input [3:0] delay);
        begin
            fetch_req = 1;
            fetch_addr = a;
            @(posedge clk);
            #1 fetch_req = 0;
            repeat (delay) @(posedge clk);
            #1 pm_rst_n = 0;
            @(posedge clk);
            #1 pm_rst_n = 1;
        end
    endtask

    initial begin
        $readmemh("ops.hex", ops);
        repeat (2) @(posedge clk);
        #1 rst_n = 1;
        for (i = 0; ops[i][75:72] != 4'hf; i = i + 1) begin
            case (ops[i][75:72])
                4'h0: fetch(ops[i][66:52]);
                4'h1: load(ops[i][50:36], ops[i][35:4], ops[i][3:0]);
                4'h2: begin
                    fork
                        load(ops[i][50:36], ops[i][35:4], ops[i][3:0]);
                        begin
                            repeat (ops[i][71:68]) @(posedge clk);
                            if (ops[i][71:68] != 0) #1;
                            fetch(ops[i][66:52]);
                        end
                    join
                    $display("ORDER fetch=%0d load=%0d", t_fetch, t_load);
                end
                4'h3: fetch_then_reset(ops[i][66:52], ops[i][71:68]);
                4'h4: begin
                    repeat (ops[i][67:52]) @(posedge clk);
                    #1;
                end
                4'h5: begin
                    pm_rst_n = 0;
                    fork
                        load(ops[i][50:36], ops[i][35:4], ops[i][3:0]);
                        begin
                            repeat (ops[i][71:68]) @(posedge clk);
                            #1 pm_rst_n = 1;
                        end
                    join
                end
                default: ;
            endcase
        end
        repeat (5) @(posedge clk);
        $display("RESULT model_errors=%0d fetches=%0d readies=%0d",
                 `MODEL_ERRORS, fetches, readies);
        $finish;
    end
endmodule
