// Serializes three TMDS channels and the clock lane (10:1, LSB first) onto
// differential outputs.
module hdmi_phy_gowin (
    input  wire       clk_pix,
    input  wire       clk_ser,
    input  wire       rst,
    input  wire [9:0] ch0,
    input  wire [9:0] ch1,
    input  wire [9:0] ch2,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    wire [9:0] lanes [0:3];
    assign lanes[0] = ch0;
    assign lanes[1] = ch1;
    assign lanes[2] = ch2;
    assign lanes[3] = 10'b0000011111;

    wire [3:0] serial;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_lane
            OSER10 ser (
                .D0(lanes[i][0]), .D1(lanes[i][1]), .D2(lanes[i][2]), .D3(lanes[i][3]),
                .D4(lanes[i][4]), .D5(lanes[i][5]), .D6(lanes[i][6]), .D7(lanes[i][7]),
                .D8(lanes[i][8]), .D9(lanes[i][9]),
                .PCLK(clk_pix), .FCLK(clk_ser), .RESET(rst),
                .Q(serial[i])
            );
        end
    endgenerate

    ELVDS_OBUF buf_d0  (.I(serial[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF buf_d1  (.I(serial[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF buf_d2  (.I(serial[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF buf_clk (.I(serial[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule
