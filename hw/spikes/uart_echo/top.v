`default_nettype none

// UART spike: echoes every byte back at the selected rate. S1 steps through
// 3M, 2.7M, 2.25M, 1.5M, 1M and 115200 baud; LED i is lit for rate i.
// A 512-byte FIFO soaks up a host that runs slightly faster than we do.
module top (
    input  wire       clk,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,
    input  wire       uart_rx,
    output wire       uart_tx
);

    reg [16:0] por_count = 0;
    wire por = ~por_count[16];
    always @(posedge clk)
        if (por) por_count <= por_count + 1'b1;

    wire s1_pressed;
    reset_sync #(.DEBOUNCE(1)) s1_sync (.clk(clk), .async_in(~btn_s1), .sync_out(s1_pressed));

    reg [2:0] rate = 0;
    reg s1_q = 0;
    always @(posedge clk) begin
        s1_q <= s1_pressed;
        if (s1_pressed && !s1_q)
            rate <= rate == 3'd5 ? 3'd0 : rate + 1'b1;
    end

    function integer clks(input integer i);
        case (i)
            0: clks = 9;
            1: clks = 10;
            2: clks = 12;
            3: clks = 18;
            4: clks = 27;
            default: clks = 234;
        endcase
    endfunction

    wire [5:0] rx_valid, tx_ready, tx_pin;
    wire [7:0] rx_data [0:5];
    wire tx_go;
    wire [7:0] tx_byte;

    genvar i;
    generate
        for (i = 0; i < 6; i = i + 1) begin : rates
            uart_rx #(.CLKS_PER_BIT(clks(i))) rx (
                .clk(clk), .rst(por || rate != i), .rx(uart_rx),
                .data(rx_data[i]), .valid(rx_valid[i]), .frame_err()
            );
            uart_tx #(.CLKS_PER_BIT(clks(i))) tx (
                .clk(clk), .rst(por || rate != i), .data(tx_byte),
                .valid(tx_go && rate == i), .ready(tx_ready[i]), .tx(tx_pin[i])
            );
        end
    endgenerate

    // FIFO between the selected receiver and transmitter
    reg [7:0] fifo [0:511];
    reg [8:0] wr = 0, rd = 0;
    wire empty = wr == rd;
    always @(posedge clk)
        if (rx_valid[rate]) begin
            fifo[wr] <= rx_data[rate];
            wr <= wr + 1'b1;
        end

    // Registered read: the byte at rd is in tx_byte a cycle later
    reg [7:0] head = 0;
    reg head_ok = 0;
    assign tx_byte = head;
    assign tx_go = head_ok;
    always @(posedge clk) begin
        if (por) begin
            head_ok <= 0;
            rd <= 0;
        end else if (head_ok) begin
            if (tx_ready[rate])
                head_ok <= 0;
        end else if (!empty) begin
            head <= fifo[rd];
            rd <= rd + 1'b1;
            head_ok <= 1;
        end
    end

    assign uart_tx = tx_pin[rate];
    assign led = ~(6'b1 << rate);

endmodule

`default_nettype wire
