`default_nettype none

// Flash spike: after power-on (and on every S1 press) reads 16 bytes at
// 0x020000 (slot 1) and compares them with A0, A1, ... AF.
// LED 0 = match, LED 1 = done, LED 2 = mismatch. LEDs are active low.
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,
    output wire       flash_cs_n,
    output wire       flash_clk,
    output wire       flash_mosi,
    input  wire       flash_miso
);

    reg [16:0] por_count = 0;
    wire por = ~por_count[16];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_pressed;
    reset_sync #(.DEBOUNCE(1)) s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_pressed));
    reg s1_prev = 0, por_prev = 1;

    reg start = 0, stop = 0;
    wire out_valid;
    wire [7:0] out_byte;

    spi_flash_reader reader (
        .clk(clk), .rst_n(~por), .start(start), .addr(24'h020000), .stop(stop),
        .out_valid(out_valid), .out_byte(out_byte), .out_ready(1'b1),
        .flash_cs_n(flash_cs_n), .flash_clk(flash_clk), .flash_mosi(flash_mosi),
        .flash_miso(flash_miso)
    );

    reg busy = 0, done = 0, bad = 0;
    reg [4:0] count = 0;

    always @(posedge clk) begin
        start <= 1'b0;
        stop <= 1'b0;
        s1_prev <= s1_pressed;
        por_prev <= por;

        if ((por_prev && !por) || (s1_pressed && !s1_prev)) begin
            start <= 1'b1;
            busy <= 1'b1;
            done <= 1'b0;
            bad <= 1'b0;
            count <= 0;
        end else if (busy && out_valid) begin
            if (out_byte != 8'ha0 + count[3:0]) bad <= 1'b1;
            count <= count + 1'b1;
            if (count == 5'd15) begin
                stop <= 1'b1;
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    assign led = ~{3'b000, done & bad, done, done & ~bad};

endmodule

`default_nettype wire
