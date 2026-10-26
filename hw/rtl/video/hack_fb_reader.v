// Turns the 512x256 Hack screen into 640x480 pixels, centered, with a gray
// border. Hack bit 1 is black. Outputs lag the inputs by 2 clocks: one for the
// screen RAM read and one for the output register.
module hack_fb_reader (
    input  wire        clk,
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    output wire [12:0] vaddr,
    input  wire [15:0] vdata,
    output reg  [23:0] rgb,
    output reg         de_o,
    output reg         hs_o,
    output reg         vs_o
);

    wire [9:0] hx = x - 10'd64;
    wire [9:0] hy = y - 10'd112;
    wire in_window = (x >= 10'd64) && (x < 10'd576) && (y >= 10'd112) && (y < 10'd368);

    // word = hy * 32 + hx / 16
    assign vaddr = {hy[7:0], hx[8:4]};

    reg [3:0] bit_q = 0;
    reg in_window_q = 0, de_q = 0, hs_q = 1, vs_q = 1;

    initial begin
        rgb = 24'd0;
        de_o = 0;
        hs_o = 1;
        vs_o = 1;
    end

    always @(posedge clk) begin
        bit_q <= hx[3:0];
        in_window_q <= in_window;
        de_q <= de;
        hs_q <= hs;
        vs_q <= vs;

        if (!de_q)
            rgb <= 24'h000000;
        else if (!in_window_q)
            rgb <= 24'h404040;
        else
            rgb <= vdata[bit_q] ? 24'h000000 : 24'hffffff;
        de_o <= de_q;
        hs_o <= hs_q;
        vs_o <= vs_q;
    end

endmodule
