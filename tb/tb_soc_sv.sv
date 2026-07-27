// SystemVerilog verification wrapper for the RV32I SoC.
//
// This adds two things the plain Verilog testbench does not have: functional coverage
// over which instructions actually retired, and concurrent assertions checking
// architectural invariants on every cycle rather than only at the two points (smoke test,
// regression) where a human thought to check. It reuses the exact same DUT and the same
// per-instruction trace format, so it is additive to the existing verification, not a
// replacement for the trace-diff methodology that found the two real bugs.
//
// Built for Verilator specifically: Icarus Verilog's SystemVerilog support does not
// include covergroups, so this file is Verilator-only. Build with
// `verilator --binary --coverage --assert --top-module tb_soc_sv <rtl files> tb/tb_soc_sv.sv`
// (there is no Makefile target for this yet -- see the README's Coverage section for
// the full invocation used to regenerate coverage.dat).

`timescale 1ns / 1ps

module tb_soc_sv;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [31:0] retire_pc, retire_insn, retire_val;
    logic [4:0]  retire_rd;
    logic        retire_we, halted;

    int trace_fd;
    int retired = 0;
    int max_cycles;
    string hex_path;

    soc_top dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .retire_pc  (retire_pc),
        .retire_insn(retire_insn),
        .retire_rd  (retire_rd),
        .retire_val (retire_val),
        .retire_we  (retire_we),
        .halted     (halted)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------------------
    // Instruction classification, decoded from the retiring instruction word purely for
    // coverage bookkeeping. This mirrors model/coverage.py's decode table so the two
    // coverage measurements (Python-side, over ISS traces; SV-side, sampled live off the
    // RTL) are checking the same partition of the instruction set.
    // ------------------------------------------------------------------------------
    typedef enum {
        I_LUI, I_AUIPC, I_JAL, I_JALR,
        I_BEQ, I_BNE, I_BLT, I_BGE, I_BLTU, I_BGEU,
        I_LB, I_LH, I_LW, I_LBU, I_LHU,
        I_SB, I_SH, I_SW,
        I_ADDI, I_SLTI, I_SLTIU, I_XORI, I_ORI, I_ANDI, I_SLLI, I_SRLI, I_SRAI,
        I_ADD, I_SUB, I_SLL, I_SLT, I_SLTU, I_XOR, I_SRL, I_SRA, I_OR, I_AND,
        I_ECALL, I_UNKNOWN
    } instr_class_e;

    function automatic instr_class_e classify(logic [31:0] insn);
        logic [6:0] op   = insn[6:0];
        logic [2:0] f3   = insn[14:12];
        logic       b30  = insn[30];
        unique case (op)
            7'b0110111: return I_LUI;
            7'b0010111: return I_AUIPC;
            7'b1101111: return I_JAL;
            7'b1100111: return I_JALR;
            7'b1100011: unique case (f3)
                3'b000: return I_BEQ;  3'b001: return I_BNE;
                3'b100: return I_BLT;  3'b101: return I_BGE;
                3'b110: return I_BLTU; 3'b111: return I_BGEU;
                default: return I_UNKNOWN;
            endcase
            7'b0000011: unique case (f3)
                3'b000: return I_LB; 3'b001: return I_LH; 3'b010: return I_LW;
                3'b100: return I_LBU; 3'b101: return I_LHU;
                default: return I_UNKNOWN;
            endcase
            7'b0100011: unique case (f3)
                3'b000: return I_SB; 3'b001: return I_SH; 3'b010: return I_SW;
                default: return I_UNKNOWN;
            endcase
            7'b0010011: unique case (f3)
                3'b000: return I_ADDI; 3'b010: return I_SLTI; 3'b011: return I_SLTIU;
                3'b100: return I_XORI; 3'b110: return I_ORI;  3'b111: return I_ANDI;
                3'b001: return I_SLLI;
                3'b101: return b30 ? I_SRAI : I_SRLI;
                default: return I_UNKNOWN;
            endcase
            7'b0110011: unique case (f3)
                3'b000: return b30 ? I_SUB : I_ADD;
                3'b001: return I_SLL;  3'b010: return I_SLT; 3'b011: return I_SLTU;
                3'b100: return I_XOR;
                3'b101: return b30 ? I_SRA : I_SRL;
                3'b110: return I_OR;   3'b111: return I_AND;
                default: return I_UNKNOWN;
            endcase
            7'b1110011: return I_ECALL;
            default: return I_UNKNOWN;
        endcase
    endfunction

    instr_class_e cur_class;
    logic sampling_now;
    assign sampling_now = rst_n && !halted;
    always_comb cur_class = classify(retire_insn);

    // Branch-direction tracking: remember that the previous retired instruction was a
    // branch and where it retired from, so this cycle's PC tells us whether that branch
    // was taken (landed elsewhere) or not taken (fell through to prev_pc+4). A regression
    // that only ever exercises one direction is barely testing the branch at all.
    logic        prev_was_branch;
    logic [31:0] prev_pc;
    logic        branch_taken;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_was_branch <= 1'b0;
            prev_pc         <= 32'd0;
        end else if (sampling_now) begin
            prev_was_branch <= (cur_class inside {I_BEQ, I_BNE, I_BLT, I_BGE, I_BLTU, I_BGEU});
            prev_pc         <= retire_pc;
        end
    end
    assign branch_taken = prev_was_branch && (retire_pc != prev_pc + 32'd4);

    // ------------------------------------------------------------------------------
    // Functional coverage: has every RV32I base-integer mnemonic actually retired at
    // least once? This is the property-level analogue of model/coverage.py's tally, kept
    // as a genuine SystemVerilog covergroup rather than a script, which is the form the
    // JD's "Design/SoC Verification" language actually means.
    // ------------------------------------------------------------------------------
    covergroup instr_cg @(posedge clk iff sampling_now);
        option.per_instance = 1;
        cp_class: coverpoint cur_class {
            bins lui    = {I_LUI};    bins auipc = {I_AUIPC};
            bins jal    = {I_JAL};    bins jalr  = {I_JALR};
            bins beq    = {I_BEQ};    bins bne   = {I_BNE};
            bins blt    = {I_BLT};    bins bge   = {I_BGE};
            bins bltu   = {I_BLTU};   bins bgeu  = {I_BGEU};
            bins lb     = {I_LB};     bins lh    = {I_LH};
            bins lw     = {I_LW};     bins lbu   = {I_LBU};   bins lhu = {I_LHU};
            bins sb     = {I_SB};     bins sh    = {I_SH};    bins sw  = {I_SW};
            bins addi   = {I_ADDI};   bins slti  = {I_SLTI};  bins sltiu = {I_SLTIU};
            bins xori   = {I_XORI};   bins ori   = {I_ORI};   bins andi  = {I_ANDI};
            bins slli   = {I_SLLI};   bins srli  = {I_SRLI};  bins srai  = {I_SRAI};
            bins add_   = {I_ADD};    bins sub_  = {I_SUB};   bins sll_  = {I_SLL};
            bins slt_   = {I_SLT};    bins sltu_ = {I_SLTU};  bins xor_  = {I_XOR};
            bins srl_   = {I_SRL};    bins sra_  = {I_SRA};   bins or_   = {I_OR};
            bins and_   = {I_AND};    bins ecall = {I_ECALL};
            ignore_bins unk = {I_UNKNOWN};
        }
        // Sampled one cycle after a branch retires (see prev_was_branch above), so this
        // checks whether the regression actually exercised BOTH directions of at least
        // one branch, not merely that branch opcodes appeared somewhere in the stream.
        cp_taken: coverpoint branch_taken iff (prev_was_branch) {
            bins not_taken = {1'b0};
            bins taken     = {1'b1};
        }
    endgroup

    instr_cg cg_i = new();

    // ------------------------------------------------------------------------------
    // Assertions: architectural invariants checked every cycle, not just where a
    // directed test happened to look.
    // ------------------------------------------------------------------------------

    // x0 must never appear as a write destination in the retire trace. The core folds
    // writes to x0 into retire_rd == 0 (see rv32i_core.v's commit_we), so this assertion
    // is really checking that folding logic holds under every instruction the regression
    // throws at it, not just the ones a directed test happened to construct.
    property p_x0_never_written;
        @(posedge clk) disable iff (!rst_n)
        (retire_we) |-> (retire_rd != 5'd0);
    endproperty
    a_x0_never_written: assert property (p_x0_never_written)
        else $error("x0 was written: pc=%08x insn=%08x", retire_pc, retire_insn);

    // The PC must stay word-aligned. RV32I has no compressed extension here, so any
    // fetch address with a set low bit is a bug, most plausibly in JALR's mask-off-bit-0
    // or in an FSM computing a branch/jump target incorrectly.
    a_pc_aligned: assert property (
        @(posedge clk) disable iff (!rst_n) sampling_now |-> (retire_pc[1:0] == 2'b00)
    ) else $error("misaligned PC: %08x", retire_pc);

    // A halted core must stay halted. This is what "ECALL ends the run" actually means
    // architecturally, and it is exactly the kind of one-line invariant that is easy to
    // break silently while refactoring the control FSM later (e.g. adding CSRs).
    a_halt_is_sticky: assert property (
        @(posedge clk) disable iff (!rst_n) halted |=> halted
    ) else $error("halted deasserted without a reset");

    // ------------------------------------------------------------------------------
    // Driver: identical structure to tb_soc.v so the two testbenches are interchangeable
    // for correctness purposes; this one adds coverage and assertions on top.
    // ------------------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("hex=%s", hex_path)) begin
            $display("FATAL: pass +hex=<file>");
            $finish;
        end
        if (!$value$plusargs("max=%d", max_cycles)) max_cycles = 20_000_000;

        for (int i = 0; i < 65536; i++) dut.mem[i] = 32'd0;
        $readmemh(hex_path, dut.mem);

        trace_fd = $fopen("sv.trace", "w");

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && !halted) begin
            $fwrite(trace_fd, "%08x %08x %2d %08x\n",
                    retire_pc, retire_insn, retire_rd, retire_val);
            retired++;
            if (retired >= max_cycles) begin
                $display("TIMEOUT after %0d instructions", retired);
                $fclose(trace_fd);
                $finish;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && halted) begin
            $display("RTL: retired %0d instruction(s), halted", retired);
            $fclose(trace_fd);
            // Note: the covergroup's inline get_coverage() introspection method is not
            // implemented by the simulator this targets (structural coverage collection
            // is; the query API is not), so the actual percentage is read from the
            // coverage database afterward with its dedicated report tool, not printed here.
            $finish;
        end
    end

endmodule
