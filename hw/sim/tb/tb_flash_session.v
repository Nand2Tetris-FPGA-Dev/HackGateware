`timescale 1ns / 1ps

// flash_session with the real spi_flash_writer, spi_flash_reader and flash model.
// cmds.txt holds one command per line, "op a b" (a in hex):
//   1 BEGIN, 2 ERASE addr size, 4 PROGRAM addr len, 5 CRC addr len, 6 END:
//     wait for !req_busy, pulse req, print "RSP op status crc cycle session"
//     or "NORSP op" after 4M cycles;
//   3 DATA: pb[a % 256 + i] = data[a + i] for i < b, one byte per cycle;
//   7 IDLE: wait a cycles.
// Also prints "WR op addr len" / "RD addr" per writer / reader start, "RD_STOP cycle"
// and "SESSION_END cycle" per pulse (one cycle after it rises).
// The model's +DUMP shows memory.
module tb_flash_session;
    reg clk = 0, rst_n = 0;
    reg req = 0;
    reg [2:0] req_op = 0;
    reg [23:0] req_addr = 0, req_len = 0;
    reg pb_we = 0;
    reg [7:0] pb_addr = 0, pb_data = 0;
    wire req_busy, rsp, session, session_end;
    wire [1:0] rsp_status;
    wire [31:0] rsp_crc;

    wire wr_start, wr_done, rd_start, rd_stop, rd_valid, rd_ready;
    wire [1:0] wr_op;
    wire [23:0] wr_addr, rd_addr;
    wire [8:0] wr_len;
    wire [7:0] wr_buf_addr, wr_buf_data, rd_byte;
    wire wr_busy;

    wire wr_cs_n, wr_sck, wr_mosi, rd_cs_n, rd_sck, rd_mosi, miso;
    // as flash_boot_system will: the writer owns the pins while its CS# is low
    wire cs_n = wr_cs_n ? rd_cs_n : 1'b0;
    wire sck = wr_cs_n ? rd_sck : wr_sck;
    wire mosi = wr_cs_n ? rd_mosi : wr_mosi;

    integer cycle = 0, errors = 0, fd, n, o, a, b, i, wait_n;
    reg [7:0] data [0:4095];

`ifdef TIMEOUT
    localparam TIMEOUT_CYCLES = `TIMEOUT;
`else
    localparam TIMEOUT_CYCLES = 27_000_000;
`endif

    flash_session #(.SESSION_TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut (
        .clk(clk), .rst_n(rst_n),
        .req(req), .req_op(req_op), .req_addr(req_addr), .req_len(req_len),
        .pb_we(pb_we), .pb_addr(pb_addr), .pb_data(pb_data),
        .req_busy(req_busy), .rsp(rsp), .rsp_status(rsp_status), .rsp_crc(rsp_crc),
        .session(session), .session_end(session_end),
        .wr_start(wr_start), .wr_op(wr_op), .wr_addr(wr_addr), .wr_len(wr_len),
        .wr_buf_addr(wr_buf_addr), .wr_buf_data(wr_buf_data), .wr_done(wr_done),
        .rd_start(rd_start), .rd_addr(rd_addr), .rd_stop(rd_stop),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .rd_ready(rd_ready)
    );

    spi_flash_writer #(.HALF_PERIOD(2)) writer (
        .clk(clk), .rst_n(rst_n), .start(wr_start), .op(wr_op), .addr(wr_addr),
        .len(wr_len), .buf_addr(wr_buf_addr), .buf_data(wr_buf_data),
        .busy(wr_busy), .done(wr_done),
        .flash_cs_n(wr_cs_n), .flash_clk(wr_sck), .flash_mosi(wr_mosi), .flash_miso(miso)
    );

    spi_flash_reader #(.HALF_PERIOD(2)) reader (
        .clk(clk), .rst_n(rst_n), .start(rd_start), .addr(rd_addr), .stop(rd_stop),
        .out_valid(rd_valid), .out_byte(rd_byte), .out_ready(rd_ready),
        .flash_cs_n(rd_cs_n), .flash_clk(rd_sck), .flash_mosi(rd_mosi), .flash_miso(miso)
    );

    spi_flash_model #(.HEXFILE("flash.hex"), .SIZE(262144)) flash (
        .cs_n(cs_n), .clk(sck), .mosi(mosi), .miso(miso)
    );

    always #18.5 clk = ~clk;

    reg rsp_q = 0, end_q = 0;
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!wr_cs_n && !rd_cs_n) begin
            $display("FAIL writer and reader both selected");
            errors = errors + 1;
        end
        if (cs_n && sck) begin
            $display("FAIL sck high while cs_n high");
            errors = errors + 1;
        end
        if ((rsp && rsp_q) || (session_end && end_q)) begin
            $display("FAIL pulse longer than one cycle");
            errors = errors + 1;
        end
        rsp_q = rsp;
        end_q = session_end;
        if (wr_start) $display("WR %0d %06x %0d", wr_op, wr_addr, wr_len);
        if (rd_start) $display("RD %06x", rd_addr);
        if (rd_stop) $display("RD_STOP %0d", cycle);
        if (session_end) $display("SESSION_END %0d", cycle);
    end

    task request(input [2:0] op, input [23:0] addr, input [23:0] len);
        integer k;
        begin
            @(negedge clk);
            while (req_busy) @(negedge clk);
            req_op = op;
            req_addr = addr;
            req_len = len;
            req = 1;
            @(negedge clk);
            req = 0;
            req_op = 0;
            req_addr = 0;
            req_len = 0;
            k = 0;
            while (!rsp && k < 4000000) begin
                @(negedge clk);
                k = k + 1;
            end
            if (rsp) $display("RSP %0d %0d %08x %0d %0d", op, rsp_status, rsp_crc, cycle,
                              session);
            else $display("NORSP %0d", op);
        end
    endtask

    initial begin
        $readmemh("data.hex", data);
        repeat (3) @(negedge clk);
        rst_n = 1;
        fd = $fopen("cmds.txt", "r");
        n = $fscanf(fd, "%d %h %d\n", o, a, b);
        while (n == 3) begin
            if (o == 3) begin
                for (i = 0; i < b; i = i + 1) begin
                    @(negedge clk);
                    pb_we = 1;
                    pb_addr = (a + i) % 256;
                    pb_data = data[a + i];
                end
                @(negedge clk);
                pb_we = 0;
            end else if (o == 7) begin
                wait_n = a;
                repeat (wait_n) @(negedge clk);
            end else begin
                request(o, a, b);
            end
            n = $fscanf(fd, "%d %h %d\n", o, a, b);
        end
        $fclose(fd);
        wait (!flash.wip);
        if (errors == 0) $display("PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
