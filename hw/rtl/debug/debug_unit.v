`default_nettype none

// Run control and memory reads for the serial link's DEBUG and READ packets.
//
// fetch_en gates hack_computer's next fetch, so a pause sits between
// instructions: next_pc is the instruction about to run and A and D are as the
// last one left them. gap is the minimum number of cycles between fetch
// starts, 0 = full speed. since counts from the last fetch_start, so reads and
// stalls never shorten the gap.
//
// One command at a time, each ending with a cmd_done pulse once it has taken
// effect. RUN and SPEED: the next cycle. PAUSE: the first idle cycle, or at once
// if the CPU is held. STEP: runs one instruction when paused and seq !=
// step_seq, done the cycle after its exec or when a hold cuts it off; ignored
// (done at once) otherwise, so a resent STEP never runs twice. RESET: a reset_cpu
// pulse, then done as PAUSE when paused. RESET keeps the run state and gap.
//
// go_run forces run at full speed and keeps step_seq. A PAUSE still waiting
// then gets its done.
//
// Reads: one word at a time through hack_computer's debug ports, RAM words in
// idle cycles, ROM words between CPU fetches. Refused at full speed. If full
// speed comes back mid-read, a ROM word already asked for is waited out, then
// the read ends refused.
module debug_unit (
    input  wire        clk,
    input  wire        rst,
    input  wire        go_run,       // level: run at gap 0
    input  wire        cmd,          // 1 cycle
    input  wire [2:0]  cmd_op,       // 0 RUN 1 PAUSE 2 STEP 3 RESET 4 SPEED
    input  wire [7:0]  cmd_seq,
    input  wire [24:0] cmd_gap,
    output reg         cmd_done,
    input  wire        rd,           // 1 cycle
    input  wire        rd_rom,
    input  wire [14:0] rd_addr,
    input  wire [6:0]  rd_count,     // 1-64, checked by serial_link
    output reg         rd_word_valid,
    output reg  [15:0] rd_word,
    output reg         rd_end,       // 1 cycle, after the last word or with rd_refused
    output reg         rd_refused,
    output reg         paused,
    output reg  [24:0] gap,
    output reg  [7:0]  step_seq,
    output wire        reset_cpu,    // ORed into the CPU reset
    input  wire        cpu_hold,     // the CPU reset
    input  wire        exec,
    input  wire        fetch_start,
    input  wire        idle,
    output wire        fetch_en,
    output wire        dbg_mreq,
    output wire [14:0] dbg_maddr,
    input  wire        dbg_mgnt,
    input  wire [15:0] dbg_mdata,
    output wire        dbg_preq,
    output wire [14:0] dbg_paddr,
    input  wire        dbg_pready,
    input  wire [15:0] dbg_pdata
);

    localparam OP_RUN = 3'd0, OP_PAUSE = 3'd1, OP_STEP = 3'd2, OP_RESET = 3'd3;
    localparam [24:0] SINCE_MAX = {25{1'b1}};

    reg wait_idle = 1'b0;  // PAUSE, or RESET while paused
    reg stepping = 1'b0;
    reg step_go = 1'b0;    // lets one fetch through while paused
    reg [24:0] since = SINCE_MAX;

    initial begin
        cmd_done = 1'b0;
        paused = 1'b0;
        gap = 25'd0;
        step_seq = 8'd0;
    end

    assign reset_cpu = cmd & (cmd_op == OP_RESET);
    assign fetch_en = (~paused & (since >= gap)) | step_go;

    always @(posedge clk) begin
        cmd_done <= 1'b0;
        if (fetch_start) begin
            since <= 25'd1;
            step_go <= 1'b0;
        end else if (since != SINCE_MAX) begin
            since <= since + 1'b1;
        end
        if (wait_idle & (idle | cpu_hold | go_run)) begin
            wait_idle <= 1'b0;
            cmd_done <= 1'b1;
        end
        if (stepping & (exec | cpu_hold)) begin
            stepping <= 1'b0;
            step_go <= 1'b0;
            cmd_done <= 1'b1;
        end
        if (cmd) begin
            case (cmd_op)
                OP_RUN: begin
                    paused <= 1'b0;
                    cmd_done <= 1'b1;
                end
                OP_PAUSE: begin
                    // idle now means no fetch starts this cycle, and paused stops the next
                    paused <= 1'b1;
                    if (idle | cpu_hold) cmd_done <= 1'b1;
                    else wait_idle <= 1'b1;
                end
                OP_STEP:
                    if (paused & ~cpu_hold & (cmd_seq != step_seq)) begin
                        step_go <= 1'b1;
                        stepping <= 1'b1;
                        step_seq <= cmd_seq;
                    end else begin
                        cmd_done <= 1'b1;
                    end
                OP_RESET:
                    if (paused) wait_idle <= 1'b1;
                    else cmd_done <= 1'b1;
                default: begin  // SPEED
                    gap <= cmd_gap;
                    cmd_done <= 1'b1;
                end
            endcase
        end
        // A step_go still set is used by the next fetch, which now starts anyway
        if (go_run) begin
            paused <= 1'b0;
            gap <= 25'd0;
        end
        if (rst) begin
            cmd_done <= 1'b0;
            paused <= 1'b0;
            gap <= 25'd0;
            step_seq <= 8'd0;
            wait_idle <= 1'b0;
            stepping <= 1'b0;
            step_go <= 1'b0;
            since <= SINCE_MAX;
        end
    end

    // Reads. left: words not yet asked for; rem: words not yet given.
    reg reading = 1'b0, rom = 1'b0, m_pend = 1'b0, p_out = 1'b0;
    reg [6:0] left = 7'd0, rem = 7'd0;
    reg [14:0] addr = 15'd0;
    initial begin
        rd_word_valid = 1'b0;
        rd_word = 16'd0;
        rd_end = 1'b0;
        rd_refused = 1'b0;
    end

    wire full = ~paused & (gap == 25'd0);
    assign dbg_mreq = reading & ~rom & (left != 7'd0) & ~full;
    // hack_computer wants dbg_preq held until dbg_pready
    assign dbg_preq = reading & rom & (p_out | ((left != 7'd0) & ~full));
    assign dbg_maddr = addr;
    assign dbg_paddr = addr;

    always @(posedge clk) begin
        rd_word_valid <= 1'b0;
        rd_end <= 1'b0;
        rd_refused <= 1'b0;
        // a RAM word is on dbg_mdata the cycle after its grant
        m_pend <= dbg_mgnt;
        if (dbg_mgnt | dbg_pready) begin
            addr <= addr + 1'b1;
            left <= left - 1'b1;
        end
        // the ROM word may come in the cycle it is asked for
        if (dbg_pready) p_out <= 1'b0;
        else if (dbg_preq & idle) p_out <= 1'b1;
        if (m_pend | dbg_pready) begin
            rd_word <= m_pend ? dbg_mdata : dbg_pdata;
            rd_word_valid <= 1'b1;
            rem <= rem - 1'b1;
        end
        if (rd & ~reading) begin
            if (full) begin
                rd_end <= 1'b1;
                rd_refused <= 1'b1;
            end else begin
                reading <= 1'b1;
                rom <= rd_rom;
                addr <= rd_addr;
                left <= rd_count;
                rem <= rd_count;
            end
        end else if (reading & (rem == 7'd0)) begin
            reading <= 1'b0;
            rd_end <= 1'b1;
        end else if (reading & full & ~p_out & ~m_pend) begin
            reading <= 1'b0;
            rd_end <= 1'b1;
            rd_refused <= 1'b1;
        end
        if (rst) begin
            reading <= 1'b0;
            m_pend <= 1'b0;
            p_out <= 1'b0;
            rd_word_valid <= 1'b0;
            rd_end <= 1'b0;
            rd_refused <= 1'b0;
        end
    end

endmodule
