// Erases or programs the board's SPI NOR flash (PUYA P25Q32H, datasheet Ver1.3),
// SPI mode 0 with the same SCK as spi_flash_reader (clk / (2 * HALF_PERIOD)).
// One start runs three steps, each its own CS# low period:
//   WREN 06h (s10.2), then the op: sector erase 20h (s10.28), 64 KB block
//   erase D8h (s10.30) or page program 02h (s10.32) with len bytes read from
//   the page buffer, then RDSR 05h (s10.5) polls until WIP (S0) reads 0.
// done pulses once WIP is 0. Erase and program are only accepted with WEL set
// and when CS# rises on a byte boundary (s10.28-10.32). CS# stays high a full
// SCK period between steps, above tSHSL (30 ns, Table 5-3).
module spi_flash_writer #(
    parameter HALF_PERIOD = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire [23:0] addr,
    input  wire [8:0]  len,
    output wire [7:0]  buf_addr,
    input  wire [7:0]  buf_data,
    output wire        busy,
    output reg         done,
    output reg         flash_cs_n,
    output reg         flash_clk,
    output reg         flash_mosi,
    input  wire        flash_miso
);

    localparam IDLE = 2'd0, SHIFT = 2'd1, GAP = 2'd2;
    localparam WREN = 2'd0, OP = 2'd1, POLL = 2'd2;

    reg [1:0] state = IDLE;
    reg [1:0] step = WREN;
    reg [1:0] op_r = 0;
    reg [23:0] addr_r = 0;
    reg [8:0] len_r = 0;
    reg [8:0] idx = 0;       // byte within the current CS# low period
    reg [8:0] data_idx = 0;  // next page buffer byte
    reg [7:0] shift_out = 0;
    reg [7:0] shift_in = 0;
    reg [2:0] bit_n = 0;
    reg [$clog2(2 * HALF_PERIOD + 1)-1:0] tick = 0;

    initial begin
        done = 0;
        flash_cs_n = 1;
        flash_clk = 0;
        flash_mosi = 0;
    end

    assign busy = (state != IDLE);
    assign buf_addr = data_idx[7:0];

    wire half = (tick == HALF_PERIOD - 1);
    wire [8:0] next_idx = idx + 1'b1;

    wire [8:0] op_bytes = (op_r == 2'd2) ? 9'd4 + len_r : 9'd4;
    wire [8:0] step_bytes = (step == WREN) ? 9'd1 : (step == OP) ? op_bytes : 9'd2;

    wire [7:0] opcode = (op_r == 2'd0) ? 8'h20 : (op_r == 2'd1) ? 8'hd8 : 8'h02;

    // The byte to send next: byte 0 of the step while in GAP, else byte idx + 1.
    // Program bytes from 4 on come from the buffer (buf_addr was set earlier).
    wire [8:0] n = (state == GAP) ? 9'd0 : next_idx;
    wire [7:0] next_byte =
        (step == WREN) ? 8'h06 :
        (step == POLL) ? ((n == 0) ? 8'h05 : 8'h00) :
        (n == 0) ? opcode :
        (n == 1) ? addr_r[23:16] :
        (n == 2) ? addr_r[15:8] :
        (n == 3) ? addr_r[7:0] : buf_data;

    always @(posedge clk) begin
        done <= 1'b0;

        if (!rst_n) begin
            state <= IDLE;
            flash_cs_n <= 1'b1;
            flash_clk <= 1'b0;
            tick <= 0;
        end else case (state)
            IDLE: if (start) begin
                op_r <= op;
                addr_r <= addr;
                len_r <= len;
                step <= WREN;
                state <= GAP;
                tick <= 0;
            end

            // CS# high for one SCK period, then the step's first byte
            GAP: begin
                tick <= tick + 1'b1;
                if (tick == 2 * HALF_PERIOD - 1) begin
                    tick <= 0;
                    idx <= 0;
                    data_idx <= 0;
                    bit_n <= 0;
                    shift_out <= {next_byte[6:0], 1'b0};
                    flash_mosi <= next_byte[7];
                    flash_cs_n <= 1'b0;
                    state <= SHIFT;
                end
            end

            SHIFT: begin
                tick <= half ? 0 : tick + 1'b1;
                if (half) begin
                    if (!flash_clk) begin
                        flash_clk <= 1'b1;
                        shift_in <= {shift_in[6:0], flash_miso};
                    end else begin
                        flash_clk <= 1'b0;
                        bit_n <= bit_n + 1'b1;
                        if (bit_n != 3'd7) begin
                            flash_mosi <= shift_out[7];
                            shift_out <= {shift_out[6:0], 1'b0};
                        end else if (next_idx != step_bytes) begin
                            idx <= next_idx;
                            if (next_idx >= 4) data_idx <= data_idx + 1'b1;
                            flash_mosi <= next_byte[7];
                            shift_out <= {next_byte[6:0], 1'b0};
                        end else begin
                            flash_cs_n <= 1'b1;
                            if (step == WREN) begin
                                step <= OP;
                                state <= GAP;
                            end else if (step == OP || shift_in[0]) begin
                                step <= POLL;
                                state <= GAP;
                            end else begin
                                done <= 1'b1;
                                state <= IDLE;
                            end
                        end
                    end
                end
            end

            default: state <= IDLE;
        endcase
    end

endmodule
