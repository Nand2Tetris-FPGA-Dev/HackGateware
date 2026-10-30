`default_nettype none

// The Hack computer running a program copied from SPI flash slot 0 into PSRAM.
// The board top adds psram_ctrl, clocks, video and pins.
//
// Once PSRAM is ready the loader copies the image, and the CPU stays in reset
// until the image checks out. s1 resets the CPU alone; the program in PSRAM
// and RAM are kept. s2 resets the loader, which drops done and so the CPU,
// and the loader starts again when s2 goes low. progmem_psram is reset by
// por_n only: a fetch waiting there must get its fetch_ready.
//
// fl_* and pb_* carry the serial link's flash requests to flash_session. A
// session holds the loader and CPU (s1 and s2 do nothing more until it ends);
// when it ends, RAM and screen are cleared while the loader reloads slot 0.
module flash_boot_system #(
    parameter SESSION_TIMEOUT_CYCLES = 27_000_000
) (
    input  wire        clk,
    input  wire        por_n,
    input  wire        s1,
    input  wire        s2,
    input  wire [15:0] keyboard,
    output wire        flash_clk,
    output wire        flash_cs_n,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        req_valid,
    input  wire        req_ready,
    output wire        req_we,
    output wire [23:0] req_addr,
    output wire [31:0] req_wdata,
    output wire [3:0]  req_wstrb,
    input  wire        rsp_valid,
    input  wire [31:0] rsp_rdata,
    input  wire        init_done,
    input  wire        vclk,
    input  wire [12:0] vaddr,
    output wire [15:0] vdata,
    output wire        busy,
    output wire        running,
    output wire        err_header,
    output wire        err_crc,
    output wire [2:0]  boot_state,
    output wire [127:0] prog_name,
    output wire [15:0] prog_words,
    output wire [14:0] dbg_pc,
    output wire [15:0] dbg_instr,
    output wire [15:0] dbg_a,
    output wire [15:0] dbg_d,
    output wire [15:0] sp,
    output wire [15:0] sp_max,
    output wire [14:0] heap_hi,
    input  wire        fl_req,
    input  wire [2:0]  fl_op,
    input  wire [23:0] fl_addr,
    input  wire [23:0] fl_len,
    input  wire        pb_we,
    input  wire [7:0]  pb_addr,
    input  wire [7:0]  pb_data,
    output wire        fl_busy,
    output wire        fl_rsp,
    output wire [1:0]  fl_status,
    output wire [31:0] fl_crc
);

    wire done, session, session_end, clearing;
    wire cpu_reset = ~por_n | ~done | s1 | session | clearing;
    assign running = ~cpu_reset;

    // 0 WAIT (no PSRAM yet), 1 LOAD (loading or S2 held), 2 RUN, 3 RESET (S1
    // held), 4 NO IMG, 5 BADCRC, 6 WRITE (flash session)
    assign boot_state = session    ? 3'd6 :
                        err_header ? 3'd4 :
                        err_crc    ? 3'd5 :
                        done       ? (cpu_reset ? 3'd3 : 3'd2) :
                        init_done  ? 3'd1 : 3'd0;

    // the loader's and the session's reader requests; the session's win while it's open
    wire ld_rd_start, ld_rd_stop, ld_rd_ready, fs_rd_start, fs_rd_stop, fs_rd_ready;
    wire [23:0] ld_rd_addr, fs_rd_addr;
    wire rd_valid;
    wire [7:0] rd_byte;
    wire load_valid, load_ready;
    wire [14:0] load_addr;
    wire [31:0] load_data;
    wire [3:0] load_strb;

    // start is a level: the loader only looks at it when idle after reset
    boot_loader loader (
        .clk(clk), .rst_n(por_n & ~s2 & ~session), .start(init_done), .slot_base(24'd0),
        .rd_start(ld_rd_start), .rd_addr(ld_rd_addr), .rd_stop(ld_rd_stop),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .rd_ready(ld_rd_ready),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .busy(busy), .done(done), .err_header(err_header), .err_crc(err_crc),
        .word_count(prog_words), .name(prog_name)
    );

    wire rd_cs_n, rd_clk, rd_mosi;

    spi_flash_reader reader (
        .clk(clk), .rst_n(por_n),
        .start(session ? fs_rd_start : ld_rd_start),
        .addr(session ? fs_rd_addr : ld_rd_addr),
        .stop(session ? fs_rd_stop : ld_rd_stop),
        .out_valid(rd_valid), .out_byte(rd_byte),
        .out_ready(session ? fs_rd_ready : ld_rd_ready),
        .flash_cs_n(rd_cs_n), .flash_clk(rd_clk), .flash_mosi(rd_mosi),
        .flash_miso(flash_miso)
    );

    wire wr_start, wr_done, wr_cs_n, wr_clk, wr_mosi;
    wire [1:0] wr_op;
    wire [23:0] wr_addr;
    wire [8:0] wr_len;
    wire [7:0] wr_buf_addr, wr_buf_data;

    flash_session #(.SESSION_TIMEOUT_CYCLES(SESSION_TIMEOUT_CYCLES)) fsession (
        .clk(clk), .rst_n(por_n),
        .req(fl_req), .req_op(fl_op), .req_addr(fl_addr), .req_len(fl_len),
        .pb_we(pb_we), .pb_addr(pb_addr), .pb_data(pb_data),
        .req_busy(fl_busy), .rsp(fl_rsp), .rsp_status(fl_status), .rsp_crc(fl_crc),
        .session(session), .session_end(session_end),
        .wr_start(wr_start), .wr_op(wr_op), .wr_addr(wr_addr), .wr_len(wr_len),
        .wr_buf_addr(wr_buf_addr), .wr_buf_data(wr_buf_data), .wr_done(wr_done),
        .rd_start(fs_rd_start), .rd_addr(fs_rd_addr), .rd_stop(fs_rd_stop),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .rd_ready(fs_rd_ready)
    );

    spi_flash_writer writer (
        .clk(clk), .rst_n(por_n), .start(wr_start), .op(wr_op), .addr(wr_addr),
        .len(wr_len), .buf_addr(wr_buf_addr), .buf_data(wr_buf_data),
        .busy(), .done(wr_done),
        .flash_cs_n(wr_cs_n), .flash_clk(wr_clk), .flash_mosi(wr_mosi),
        .flash_miso(flash_miso)
    );

    // The writer owns the pins while its CS# is low. The session never runs
    // the reader and writer at once, and BEGIN stops a read the loader left open.
    assign flash_cs_n = wr_cs_n & rd_cs_n;
    assign flash_clk = wr_cs_n ? rd_clk : wr_clk;
    assign flash_mosi = wr_cs_n ? rd_mosi : wr_mosi;

    wire pm_req, pm_ready;
    wire [14:0] pm_addr;
    wire [15:0] pm_data;
    wire dbg_we;
    wire [14:0] dbg_waddr;
    wire [15:0] dbg_wdata;

    progmem_psram pm (
        .clk(clk), .rst_n(por_n),
        .fetch_req(pm_req), .fetch_addr(pm_addr), .fetch_ready(pm_ready), .fetch_data(pm_data),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata)
    );

    hack_computer computer (
        .clk(clk), .reset(cpu_reset), .clear(session_end), .clearing(clearing),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(keyboard), .vclk(vclk), .vaddr(vaddr), .vdata(vdata),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_d(dbg_d), .dbg_instr(dbg_instr), .dbg_exec(),
        .dbg_we(dbg_we), .dbg_waddr(dbg_waddr), .dbg_wdata(dbg_wdata)
    );

    hack_stats stats (
        .clk(clk), .clear(cpu_reset), .we(dbg_we), .addr(dbg_waddr), .wdata(dbg_wdata),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

endmodule

`default_nettype wire
