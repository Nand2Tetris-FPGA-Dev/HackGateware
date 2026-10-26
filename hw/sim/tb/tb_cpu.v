`timescale 1ns / 1ps

module tb_cpu;
    reg clk = 0, ce = 0, reset = 0;
    reg [15:0] inM = 0, instruction = 0;
    wire [15:0] outM, dbg_a, dbg_d;
    wire writeM;
    wire [14:0] addressM, pc;
    integer errors = 0;

    hack_cpu dut (
        .clk(clk), .ce(ce), .reset(reset),
        .inM(inM), .instruction(instruction),
        .outM(outM), .writeM(writeM), .addressM(addressM), .pc(pc),
        .dbg_a(dbg_a), .dbg_d(dbg_d)
    );

    always #5 clk = ~clk;

    task check(input [15:0] got, input [15:0] want, input [8*24-1:0] what);
        if (got !== want) begin
            $display("FAIL %0s: got %04x want %04x", what, got, want);
            errors = errors + 1;
        end
    endtask

    // Run one instruction with ce high for one clock edge
    task exec(input [15:0] instr);
        begin
            instruction = instr;
            ce = 1;
            @(posedge clk);
            #1 ce = 0;
        end
    endtask

    initial begin
        reset = 1;
        @(posedge clk);
        #1 reset = 0;
        check(pc, 0, "reset pc");

        exec(16'd1234);                          // @1234
        check(dbg_a, 1234, "@1234 A");
        check(pc, 1, "@1234 pc");

        exec(16'b1110110000010000);              // D=A
        check(dbg_d, 1234, "D=A");

        instruction = 16'b1110001100001000;      // M=D
        #1;
        check(writeM, 1, "M=D writeM");
        check(outM, 1234, "M=D outM");
        check(addressM, 1234, "M=D addressM");
        exec(instruction);

        exec(16'b1110001100000001);              // D;JGT, D > 0
        check(pc, 1234, "D;JGT taken");

        exec(16'b1110101010010000);              // D=0
        exec(16'b1110001100000001);              // D;JGT, D = 0
        check(pc, 1236, "D;JGT not taken");

        exec(16'd100);                           // @100
        exec(16'b1110101010000111);              // 0;JMP
        check(pc, 100, "0;JMP");

        instruction = 16'd5;                     // @5 with ce low
        @(posedge clk);
        #1;
        check(dbg_a, 100, "ce=0 holds A");
        check(pc, 100, "ce=0 holds pc");

        exec(16'b1110111111010000);              // D=1
        reset = 1;                               // reset works without ce
        @(posedge clk);
        #1 reset = 0;
        check(pc, 0, "reset pc");
        check(dbg_a, 100, "reset keeps A");
        check(dbg_d, 1, "reset keeps D");

        exec(16'd5);                             // @5
        inM = 41;
        instruction = 16'b1111110111101000;      // AM=M+1
        #1;
        check(addressM, 5, "AM=M+1 addressM");
        check(outM, 42, "AM=M+1 outM");
        check(writeM, 1, "AM=M+1 writeM");
        exec(instruction);
        check(dbg_a, 42, "AM=M+1 A");

        exec(16'b1110111010100000);              // A=-1
        check(addressM, 15'h7fff, "addressM is 15 bits");

        if (errors == 0) $display("PASS");
        $finish;
    end
endmodule
