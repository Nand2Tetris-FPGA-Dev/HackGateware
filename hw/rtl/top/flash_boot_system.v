`default_nettype none

// The Hack computer running a program copied from SPI flash slot 0 into PSRAM.
// The board top adds psram_ctrl, clocks, video and pins.
//
// Once PSRAM is ready the loader copies the image, and the CPU stays in reset
// until the image checks out. s1 resets the CPU alone; the program in PSRAM
// and RAM are kept. s2 resets the loader, which drops done and so the CPU,
// and the loader starts again when s2 goes low. progmem_psram is reset by
// por_n only: a fetch waiting there must get its fetch_ready.
module flash_boot_system (
    input  wire        clk,
    input  wire        por_n,
    input  wire        s1,
    input  wire        s2,
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
    output wire [14:0] heap_hi
);

    wire done;
    wire cpu_reset = ~por_n | ~done | s1;
    assign running = ~cpu_reset;

    // 0 WAIT (no PSRAM yet), 1 LOAD (loading or S2 held), 2 RUN, 3 RESET (S1
    // held), 4 NO IMG, 5 BADCRC
    assign boot_state = err_header ? 3'd4 :
                        err_crc    ? 3'd5 :
                        done       ? (cpu_reset ? 3'd3 : 3'd2) :
                        init_done  ? 3'd1 : 3'd0;

    wire rd_start, rd_stop, rd_valid, rd_ready;
    wire [23:0] rd_addr;
    wire [7:0] rd_byte;
    wire load_valid, load_ready;
    wire [14:0] load_addr;
    wire [31:0] load_data;
    wire [3:0] load_strb;

    // start is a level: the loader only looks at it when idle after reset
    boot_loader loader (
        .clk(clk), .rst_n(por_n & ~s2), .start(init_done), .slot_base(24'd0),
        .rd_start(rd_start), .rd_addr(rd_addr), .rd_stop(rd_stop),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .rd_ready(rd_ready),
        .load_valid(load_valid), .load_ready(load_ready), .load_addr(load_addr),
        .load_data(load_data), .load_strb(load_strb),
        .busy(busy), .done(done), .err_header(err_header), .err_crc(err_crc),
        .word_count(prog_words), .name(prog_name)
    );

    spi_flash_reader reader (
        .clk(clk), .rst_n(por_n), .start(rd_start), .addr(rd_addr), .stop(rd_stop),
        .out_valid(rd_valid), .out_byte(rd_byte), .out_ready(rd_ready),
        .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi),
        .flash_miso(flash_miso)
    );

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
        .clk(clk), .reset(cpu_reset),
        .pm_req(pm_req), .pm_addr(pm_addr), .pm_ready(pm_ready), .pm_data(pm_data),
        .keyboard(16'd0), .vclk(vclk), .vaddr(vaddr), .vdata(vdata),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_d(dbg_d), .dbg_instr(dbg_instr), .dbg_exec(),
        .dbg_we(dbg_we), .dbg_waddr(dbg_waddr), .dbg_wdata(dbg_wdata)
    );

    hack_stats stats (
        .clk(clk), .clear(cpu_reset), .we(dbg_we), .addr(dbg_waddr), .wdata(dbg_wdata),
        .sp(sp), .sp_max(sp_max), .heap_hi(heap_hi)
    );

endmodule

`default_nettype wire
