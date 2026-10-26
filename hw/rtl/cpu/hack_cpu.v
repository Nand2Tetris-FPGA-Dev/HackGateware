// Book CPU with a clock enable. A, D and PC only update on clock edges where ce
// is high; reset clears PC on any edge and leaves A and D alone.
module hack_cpu (
    input  wire        clk,
    input  wire        ce,
    input  wire        reset,
    input  wire [15:0] inM,
    input  wire [15:0] instruction,
    output wire [15:0] outM,
    output wire        writeM,
    output wire [14:0] addressM,
    output reg  [14:0] pc,
    output wire [15:0] dbg_a,
    output wire [15:0] dbg_d
);

    reg [15:0] a_reg = 16'd0;
    reg [15:0] d_reg = 16'd0;
    initial pc = 15'd0;

    wire is_c = instruction[15];
    wire load_a = ~is_c | instruction[5];
    wire load_d = is_c & instruction[4];
    assign writeM = is_c & instruction[3];

    wire [15:0] alu_out;
    wire zr, ng;
    wire [15:0] alu_y = (is_c & instruction[12]) ? inM : a_reg;

    hack_alu alu (
        .x(d_reg), .y(alu_y),
        .zx(instruction[11]), .nx(instruction[10]),
        .zy(instruction[9]), .ny(instruction[8]),
        .f(instruction[7]), .no(instruction[6]),
        .out(alu_out), .zr(zr), .ng(ng)
    );

    wire jump = is_c & ((instruction[2] & ng) |
                        (instruction[1] & zr) |
                        (instruction[0] & ~(zr | ng)));

    always @(posedge clk) begin
        if (ce) begin
            if (load_a) a_reg <= is_c ? alu_out : instruction;
            if (load_d) d_reg <= alu_out;
        end

        if (reset)
            pc <= 15'd0;
        else if (ce)
            pc <= jump ? a_reg[14:0] : pc + 15'd1;
    end

    assign outM = alu_out;
    assign addressM = a_reg[14:0];
    assign dbg_a = a_reg;
    assign dbg_d = d_reg;

endmodule
