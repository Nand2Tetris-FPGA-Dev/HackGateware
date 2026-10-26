// 27 MHz -> 126 MHz serial clock (rPLL: 27 / 3 * 14) -> 25.2 MHz pixel clock (CLKDIV / 5)
module clocks_gowin (
    input  wire clk27,
    output wire clk_pix,
    output wire clk_ser,
    output wire locked
);

    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"),
        .IDIV_SEL(2),
        .DYN_FBDIV_SEL("false"),
        .FBDIV_SEL(13),
        .DYN_ODIV_SEL("false"),
        .ODIV_SEL(4),
        .PSDA_SEL("0000"),
        .DYN_DA_EN("true"),
        .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1N-9C")
    ) pll (
        .CLKIN(clk27),
        .CLKOUT(clk_ser),
        .LOCK(locked),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'd0),
        .IDSEL(6'd0),
        .ODSEL(6'd0),
        .PSDA(4'd0),
        .DUTYDA(4'd0),
        .FDLY(4'd0)
    );

    CLKDIV #(.DIV_MODE("5")) div5 (
        .HCLKIN(clk_ser),
        .RESETN(locked),
        .CALIB(1'b0),
        .CLKOUT(clk_pix)
    );

endmodule
