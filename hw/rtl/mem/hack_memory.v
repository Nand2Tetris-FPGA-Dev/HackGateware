// Book memory map: RAM 0-16383, screen 16384-24575, keyboard 24576.
// Other addresses read 0 and ignore writes. out is registered like the RAMs.
module hack_memory (
    input  wire        clk,
    input  wire [14:0] address,
    input  wire [15:0] in,
    input  wire        load,
    output wire [15:0] out,
    input  wire [15:0] keyboard,
    input  wire        vclk,
    input  wire [12:0] vaddr,
    output wire [15:0] vdata
);

    wire is_ram = ~address[14];
    wire is_screen = address[14:13] == 2'b10;
    wire is_kbd = address == 15'd24576;

    wire [15:0] ram_out, screen_out;

    ram16k u_ram (
        .clk(clk), .we(load & is_ram), .addr(address[13:0]),
        .din(in), .dout(ram_out)
    );

    screen_mem u_screen (
        .clk(clk), .we(load & is_screen), .addr(address[12:0]),
        .din(in), .dout(screen_out),
        .vclk(vclk), .vaddr(vaddr), .vdata(vdata)
    );

    // Match the RAMs' one cycle read delay
    reg ram_q = 0, screen_q = 0, kbd_q = 0;
    reg [15:0] keyboard_q = 0;

    always @(posedge clk) begin
        ram_q <= is_ram;
        screen_q <= is_screen;
        kbd_q <= is_kbd;
        keyboard_q <= keyboard;
    end

    assign out = ram_q    ? ram_out :
                 screen_q ? screen_out :
                 kbd_q    ? keyboard_q : 16'd0;

endmodule
