// Reads bytes from an SPI NOR flash with the READ command (0x03), SPI mode 0:
// MOSI changes while SCK is low, both sides sample on the rising edge.
// SCK = clk / (2 * HALF_PERIOD); 27 MHz / 4 = 6.75 MHz, well under READ's limit.
// A start pulse sends the command and addr, then bytes stream out on
// out_valid/out_ready. SCK pauses while a byte waits. stop raises CS.
// The board's flash is a PUYA P25Q32H (as reported by openFPGALoader); READ is
// in its datasheet, section 10.10 Read Data Bytes. Checked on the board.
module spi_flash_reader #(
    parameter HALF_PERIOD = 2
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [23:0] addr,
    input  wire        stop,
    output reg         out_valid,
    output reg  [7:0]  out_byte,
    input  wire        out_ready,
    output reg         flash_cs_n,
    output reg         flash_clk,
    output reg         flash_mosi,
    input  wire        flash_miso
);

    localparam IDLE = 2'd0, CMD = 2'd1, READ = 2'd2;

    reg [1:0] state = IDLE;
    reg [31:0] shift_out = 0;
    reg [7:0] shift_in = 0;
    reg [5:0] bits_left = 0;
    reg [$clog2(HALF_PERIOD + 1)-1:0] tick = 0;

    initial begin
        out_valid = 0;
        out_byte = 0;
        flash_cs_n = 1;
        flash_clk = 0;
        flash_mosi = 0;
    end

    wire half = (tick == HALF_PERIOD - 1);
    wire stalled = out_valid && !out_ready;

    always @(posedge clk) begin
        if (out_valid && out_ready) out_valid <= 1'b0;

        if (!rst_n || stop) begin
            state <= IDLE;
            flash_cs_n <= 1'b1;
            flash_clk <= 1'b0;
            out_valid <= 1'b0;
            tick <= 0;
        end else if (state == IDLE) begin
            if (start) begin
                shift_out <= {8'h03, addr};
                flash_mosi <= 1'b0;  // first command bit (0x03 starts with 0)
                bits_left <= 6'd32;
                flash_cs_n <= 1'b0;
                tick <= 0;
                state <= CMD;
            end
        end else if (!(state == READ && !flash_clk && stalled)) begin
            tick <= half ? 0 : tick + 1'b1;
            if (half) begin
                if (!flash_clk) begin
                    flash_clk <= 1'b1;
                    if (state == READ) shift_in <= {shift_in[6:0], flash_miso};
                end else begin
                    flash_clk <= 1'b0;
                    bits_left <= bits_left - 1'b1;
                    if (state == CMD) begin
                        shift_out <= {shift_out[30:0], 1'b0};
                        flash_mosi <= shift_out[30];
                        if (bits_left == 1) begin
                            bits_left <= 6'd8;
                            state <= READ;
                        end
                    end else if (bits_left == 1) begin
                        out_byte <= shift_in;
                        out_valid <= 1'b1;
                        bits_left <= 6'd8;
                    end
                end
            end
        end
    end

endmodule
