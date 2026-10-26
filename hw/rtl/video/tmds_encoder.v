// DVI 1.0 TMDS encoder, one cycle of latency. Sends data while de is high,
// otherwise the control token for c.
module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] d,
    input  wire [1:0] c,
    input  wire       de,
    output reg  [9:0] q
);

    function [3:0] ones8(input [7:0] v);
        integer i;
        begin
            ones8 = 4'd0;
            for (i = 0; i < 8; i = i + 1) ones8 = ones8 + v[i];
        end
    endfunction

    // Stage 1: transition-minimized 9 bit word
    wire [3:0] d_ones = ones8(d);
    wire use_xnor = (d_ones > 4'd4) || (d_ones == 4'd4 && !d[0]);
    wire [8:0] q_m;
    assign q_m[0] = d[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : gen_qm
            assign q_m[i] = use_xnor ? ~(q_m[i-1] ^ d[i]) : (q_m[i-1] ^ d[i]);
        end
    endgenerate
    assign q_m[8] = ~use_xnor;

    // Stage 2: DC balance using the running disparity
    wire [3:0] n1 = ones8(q_m[7:0]);
    wire signed [4:0] diff = $signed({1'b0, n1}) - $signed(5'd8 - {1'b0, n1});  // ones - zeros
    reg signed [4:0] disparity = 5'sd0;
    initial q = 10'd0;

    always @(posedge clk) begin
        if (!de) begin
            disparity <= 5'sd0;
            case (c)
                2'd0: q <= 10'b1101010100;
                2'd1: q <= 10'b0010101011;
                2'd2: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (disparity == 0 || diff == 0) begin
            q <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            disparity <= q_m[8] ? disparity + diff : disparity - diff;
        end else if ((disparity > 0 && diff > 0) || (disparity < 0 && diff < 0)) begin
            q <= {1'b1, q_m[8], ~q_m[7:0]};
            disparity <= disparity + $signed({3'b0, q_m[8], 1'b0}) - diff;
        end else begin
            q <= {1'b0, q_m[8], q_m[7:0]};
            disparity <= disparity - $signed({3'b0, ~q_m[8], 1'b0}) + diff;
        end
    end

endmodule
