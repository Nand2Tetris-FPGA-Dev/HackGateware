// Runs the serial link's flash requests on spi_flash_writer and spi_flash_reader.
// BEGIN opens a session (CPU and loader held), END or SESSION_TIMEOUT_CYCLES of
// silence closes it. DATA bytes fill a 256-byte page buffer; PROGRAM writes
// buffer[0..len-1] at addr. Checks only what keeps one request safe: erase
// alignment, PROGRAM inside one page (P25Q32H s10.32 wraps within the page),
// everything inside the 4 MB flash, and the DATA byte count, which catches a
// lost DATA frame. CRC replies with zlib's CRC-32 of the flash bytes.
// Status: 0 OK, 1 NO_SESSION, 2 BAD_ARG, 3 DATA_COUNT.
module flash_session #(
    parameter SESSION_TIMEOUT_CYCLES = 27_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,            // 1-cycle pulse, taken when !req_busy
    input  wire [2:0]  req_op,         // 1 BEGIN, 2 ERASE, 4 PROGRAM, 5 CRC, 6 END (type - 0x10)
    input  wire [23:0] req_addr,
    input  wire [23:0] req_len,        // ERASE: 0 = 4 KB, 1 = 64 KB; PROGRAM/CRC: length
    input  wire        pb_we,          // DATA bytes
    input  wire [7:0]  pb_addr,
    input  wire [7:0]  pb_data,
    output wire        req_busy,
    output reg         rsp,            // 1-cycle pulse: reply ready
    output reg  [1:0]  rsp_status,
    output reg  [31:0] rsp_crc,
    output reg         session,        // CPU and loader held while high
    output reg         session_end,    // 1-cycle pulse after END's reply or the timeout
    output reg         wr_start,
    output reg  [1:0]  wr_op,
    output reg  [23:0] wr_addr,
    output reg  [8:0]  wr_len,
    input  wire [7:0]  wr_buf_addr,
    output wire [7:0]  wr_buf_data,
    input  wire        wr_done,
    output reg         rd_start,
    output reg  [23:0] rd_addr,
    output reg         rd_stop,
    input  wire        rd_valid,
    input  wire [7:0]  rd_byte,
    output wire        rd_ready
);

`include "crc32.vh"

    localparam BEGIN = 3'd1, ERASE = 3'd2, PROGRAM = 3'd4, CRC = 3'd5, END = 3'd6;
    localparam OK = 2'd0, NO_SESSION = 2'd1, BAD_ARG = 2'd2, DATA_COUNT = 2'd3;
    localparam IDLE = 2'd0, WRITE = 2'd1, READ = 2'd2, ENDING = 2'd3;

    reg [1:0] state = IDLE;
    reg [8:0] count = 0;    // DATA bytes since BEGIN or PROGRAM, stops at 511
    reg [23:0] left = 0;
    reg [31:0] crc = 0;
    reg [$clog2(SESSION_TIMEOUT_CYCLES)-1:0] timer = 0;

    reg [7:0] page [0:255];
    reg [7:0] page_q = 0;

    initial begin
        rsp = 0;
        rsp_status = 0;
        rsp_crc = 0;
        session = 0;
        session_end = 0;
        wr_start = 0;
        wr_op = 0;
        wr_addr = 0;
        wr_len = 0;
        rd_start = 0;
        rd_addr = 0;
        rd_stop = 0;
    end

    always @(posedge clk) begin
        if (pb_we) page[pb_addr] <= pb_data;
        page_q <= page[wr_buf_addr];
    end
    assign wr_buf_data = page_q;

    assign req_busy = (state != IDLE);
    assign rd_ready = (state == READ);

    wire in_flash = (req_addr[23:22] == 2'd0);
    wire erase_bad = req_len > 24'd1 || !in_flash
                     || (req_len[0] ? req_addr[15:0] != 0 : req_addr[11:0] != 0);
    // len <= 256 here, so the 9-bit sum can't overflow
    wire prog_bad = req_len == 0 || req_len > 24'd256 || !in_flash
                    || {1'b0, req_addr[7:0]} + req_len[8:0] > 9'd256;
    wire crc_bad = req_len == 0 || {1'b0, req_addr} + {1'b0, req_len} > 25'h400000;

    // HELLO and DATA are answered by serial_link and never come here
    wire known = req_op == BEGIN || req_op == ERASE || req_op == PROGRAM || req_op == CRC
                 || req_op == END;
    wire take = req && known && state == IDLE;
    wire expired = session && state == IDLE && timer == SESSION_TIMEOUT_CYCLES - 1;

    always @(posedge clk) begin
        rsp <= 1'b0;
        session_end <= 1'b0;
        wr_start <= 1'b0;
        rd_start <= 1'b0;
        rd_stop <= 1'b0;

        if (pb_we && count != 9'h1ff) count <= count + 1'b1;

        // The timeout pauses while the flash works and restarts on every frame
        if (!session || take || pb_we) timer <= 0;
        else if (state == IDLE) timer <= timer + 1'b1;

        if (!rst_n) begin
            state <= IDLE;
            session <= 1'b0;
        end else case (state)
            IDLE:
                if (take) begin
                    rsp <= 1'b1;
                    rsp_status <= OK;
                    if (req_op == PROGRAM) count <= 0;
                    if (req_op == BEGIN) begin
                        session <= 1'b1;
                        count <= 0;
                        rd_stop <= 1'b1;  // the loader may have left a read running
                    end else if (!session) begin
                        rsp_status <= NO_SESSION;
                    end else case (req_op)
                        ERASE:
                            if (erase_bad) rsp_status <= BAD_ARG;
                            else begin
                                rsp <= 1'b0;
                                wr_start <= 1'b1;
                                wr_op <= req_len[1:0];
                                wr_addr <= req_addr;
                                state <= WRITE;
                            end
                        PROGRAM:
                            if (prog_bad) rsp_status <= BAD_ARG;
                            else if (count != req_len[8:0]) rsp_status <= DATA_COUNT;
                            else begin
                                rsp <= 1'b0;
                                wr_start <= 1'b1;
                                wr_op <= 2'd2;
                                wr_addr <= req_addr;
                                wr_len <= req_len[8:0];
                                state <= WRITE;
                            end
                        CRC:
                            if (crc_bad) rsp_status <= BAD_ARG;
                            else begin
                                rsp <= 1'b0;
                                rd_start <= 1'b1;
                                rd_addr <= req_addr;
                                left <= req_len;
                                crc <= 32'hFFFFFFFF;
                                state <= READ;
                            end
                        END: begin
                            rsp <= 1'b1;
                            state <= ENDING;
                        end
                        default: ;
                    endcase
                end else if (expired) begin
                    session <= 1'b0;
                    session_end <= 1'b1;
                end

            WRITE:
                if (wr_done) begin
                    rsp <= 1'b1;
                    state <= IDLE;
                end

            READ:
                if (rd_valid) begin
                    crc <= crc32_byte(crc, rd_byte);
                    left <= left - 1'b1;
                    if (left == 1) begin
                        rd_stop <= 1'b1;
                        rsp <= 1'b1;
                        rsp_crc <= ~crc32_byte(crc, rd_byte);
                        state <= IDLE;
                    end
                end

            ENDING: begin
                session <= 1'b0;
                session_end <= 1'b1;
                state <= IDLE;
            end
        endcase
    end

endmodule
