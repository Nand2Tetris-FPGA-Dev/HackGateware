// CPU + data memory with a fetch/execute sequencer.
//
// FETCH: request the instruction at PC and wait for pm_ready. RAM reads are
// registered, so this also gives inM a cycle to settle on the current A.
// EXEC: one cycle with ce high; A, D, PC and any M write update on its edge.
//
// pm_req is a one cycle pulse, and only one request is outstanding at a time.
//
// clear writes 0 to RAM and screen (0-24575) through the CPU's memory port, one
// word per cycle. The CPU is held in reset while clearing is high.
module hack_computer (
    input  wire        clk,
    input  wire        reset,
    input  wire        clear,
    output reg         clearing,
    output wire        pm_req,
    output wire [14:0] pm_addr,
    input  wire        pm_ready,
    input  wire [15:0] pm_data,
    input  wire [15:0] keyboard,
    input  wire        vclk,
    input  wire [12:0] vaddr,
    output wire [15:0] vdata,
    output reg  [14:0] dbg_pc,     // address of dbg_instr
    output wire [15:0] dbg_a,
    output wire [15:0] dbg_d,
    output reg  [15:0] dbg_instr,
    output wire        dbg_exec,
    output wire        dbg_we,
    output wire [14:0] dbg_waddr,
    output wire [15:0] dbg_wdata
);

    localparam REQ = 2'd0, WAIT = 2'd1, EXEC = 2'd2;

    reg [1:0] state = REQ;
    reg [14:0] clear_addr = 0;
    initial begin
        dbg_instr = 16'd0;
        dbg_pc = 15'd0;
        clearing = 1'b0;
    end

    always @(posedge clk) begin
        if (clear) begin
            clearing <= 1'b1;
            clear_addr <= 0;
        end else if (clearing) begin
            clear_addr <= clear_addr + 1'b1;
            if (clear_addr == 15'd24575) clearing <= 1'b0;
        end
    end

    wire hold = reset | clearing;
    wire exec = (state == EXEC) & ~hold;
    assign dbg_exec = exec;
    assign pm_req = (state == REQ) & ~hold;

    wire [15:0] in_m, out_m;
    wire [14:0] address_m, pc;
    wire write_m;

    hack_cpu u_cpu (
        .clk(clk), .ce(exec), .reset(hold),
        .inM(in_m), .instruction(dbg_instr),
        .outM(out_m), .writeM(write_m), .addressM(address_m), .pc(pc),
        .dbg_a(dbg_a), .dbg_d(dbg_d)
    );

    hack_memory u_mem (
        .clk(clk), .address(clearing ? clear_addr : address_m), .in(clearing ? 16'd0 : out_m),
        .load(clearing | (write_m & exec)), .out(in_m),
        .keyboard(keyboard), .vclk(vclk), .vaddr(vaddr), .vdata(vdata)
    );

    assign pm_addr = pc;
    assign dbg_we = write_m & exec;
    assign dbg_waddr = address_m;
    assign dbg_wdata = out_m;

    // A fetch already in flight when reset or clearing starts is still waited
    // out, so a late pm_ready can't be taken for the next fetch. Its instruction
    // is for the old PC, so it's dropped even if the hold is over by then.
    reg drop = 1'b0;

    always @(posedge clk) begin
        case (state)
            REQ:  if (!hold) state <= WAIT;
            WAIT: if (pm_ready) begin
                      dbg_instr <= pm_data;
                      dbg_pc <= pc;
                      state <= (hold | drop) ? REQ : EXEC;
                      drop <= 1'b0;
                  end else if (hold) begin
                      drop <= 1'b1;
                  end
            default: state <= REQ;
        endcase
    end

endmodule
