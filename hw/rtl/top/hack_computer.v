// CPU + data memory with a fetch/execute sequencer.
//
// FETCH: request the instruction at PC and wait for pm_ready, which may come in
// the request cycle itself (REQ goes straight to EXEC). RAM reads are
// registered and A changed at the previous EXEC edge, so the request cycle
// still gives inM a cycle to settle on the current A.
// EXEC: one cycle with ce high; A, D, PC and any M write update on its edge.
//
// pm_req is a one cycle pulse, and only one request is outstanding at a time.
//
// clear writes 0 to RAM and screen (0-24575) through the CPU's memory port, one
// word per cycle. The CPU is held in reset while clearing is high.
//
// fetch_en low stops the next fetch from starting; one in flight still runs.
// While idle (in REQ with no fetch starting), the debug ports may use the CPU's
// memory ports. A RAM read is granted only then, so the cycle before EXEC
// always reads M at A and inM is as it would have been. A ROM read holds off
// the CPU's fetches until its pm_ready.
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
    output wire [15:0] dbg_wdata,
    input  wire        fetch_en,    // 1: the next instruction may start
    input  wire        dbg_mreq,    // data memory read of dbg_maddr, in an idle cycle
    input  wire [14:0] dbg_maddr,
    output wire        dbg_mgnt,    // dbg_mreq taken; dbg_mdata holds the word next cycle
    output wire [15:0] dbg_mdata,
    input  wire        dbg_preq,    // program memory read of dbg_paddr, held until dbg_pready
    input  wire [14:0] dbg_paddr,
    output wire        dbg_pready,  // 1 cycle, word on dbg_pdata
    output wire [15:0] dbg_pdata,
    output wire        fetch_start, // a CPU fetch starts this cycle (pm_req for the CPU)
    output wire        idle,
    output wire [14:0] next_pc
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

    reg pread_out = 1'b0;
    wire cpu_req = (state == REQ) & ~hold & fetch_en & ~pread_out;
    assign fetch_start = cpu_req;
    assign idle = (state == REQ) & ~cpu_req & ~clearing & ~pread_out;
    assign dbg_mgnt = dbg_mreq & idle;
    wire pread_issue = dbg_preq & idle;
    assign pm_req = cpu_req | pread_issue;
    assign dbg_pready = pm_ready & (pread_out | pread_issue);
    assign dbg_pdata = pm_data;

    // progmem_psram can answer in the request cycle
    always @(posedge clk)
        if (pm_ready) pread_out <= 1'b0;
        else if (pread_issue) pread_out <= 1'b1;

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
        .clk(clk), .address(clearing ? clear_addr : dbg_mgnt ? dbg_maddr : address_m),
        .in(clearing ? 16'd0 : out_m),
        .load(clearing | (write_m & exec)), .out(in_m),
        .keyboard(keyboard), .vclk(vclk), .vaddr(vaddr), .vdata(vdata)
    );

    assign pm_addr = pread_issue ? dbg_paddr : pc;
    assign next_pc = pc;
    assign dbg_mdata = in_m;
    assign dbg_we = write_m & exec;
    assign dbg_waddr = address_m;
    assign dbg_wdata = out_m;

    // A fetch already in flight when reset or clearing starts is still waited
    // out, so a late pm_ready can't be taken for the next fetch. Its instruction
    // is for the old PC, so it's dropped even if the hold is over by then.
    reg drop = 1'b0;

    always @(posedge clk) begin
        case (state)
            REQ:  if (cpu_req) begin
                      if (pm_ready) begin
                          dbg_instr <= pm_data;
                          dbg_pc <= pc;
                          state <= EXEC;
                      end else begin
                          state <= WAIT;
                      end
                  end
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
