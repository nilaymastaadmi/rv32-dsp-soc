// RV32I single-cycle core.
//
// One instruction retires per clock. The design is deliberately partitioned as
// combinational decode/execute plus a single synchronous writeback so that the retire
// event is unambiguous: exactly one instruction commits per posedge, which lets the
// testbench emit a trace line per cycle and diff it against the C++ ISS bit for bit.
//
// Memory is exposed as an asynchronous-read / synchronous-write interface so the
// instruction fetch and the data access can both resolve in the same cycle. That is a
// simulation-oriented choice: a real implementation would pipeline these into separate
// stages with a proper memory interface, which is the natural next step for this design.

module rv32i_core (
    input  wire        clk,
    input  wire        rst_n,

    // instruction fetch (asynchronous read)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_data,

    // data memory
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,     // per-byte write enables
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,

    // retire/trace observation port (verification only, not architectural state)
    output wire [31:0] retire_pc,
    output wire [31:0] retire_insn,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_val,
    output wire        retire_we,
    output wire        halted
);

    // ------------------------------------------------------------------ state
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg        halt_r;

    // ------------------------------------------------------------------ fetch
    assign imem_addr = pc;
    wire [31:0] insn = imem_data;

    // ----------------------------------------------------------------- decode
    wire [6:0] opcode = insn[6:0];
    wire [4:0] rd     = insn[11:7];
    wire [2:0] funct3 = insn[14:12];
    wire [4:0] rs1    = insn[19:15];
    wire [4:0] rs2    = insn[24:20];
    wire [6:0] funct7 = insn[31:25];

    // x0 reads as zero regardless of what the array holds.
    wire [31:0] a = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    wire [31:0] b = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    // Immediate forms. The B and J encodings scatter their bits, so each is spelled out
    // explicitly rather than derived, to keep the mapping auditable against the spec.
    wire [31:0] imm_i = {{20{insn[31]}}, insn[31:20]};
    wire [31:0] imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    wire [31:0] imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    wire [31:0] imm_u = {insn[31:12], 12'b0};
    wire [31:0] imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_ALUI   = 7'b0010011;
    localparam OP_ALUR   = 7'b0110011;
    localparam OP_FENCE  = 7'b0001111;
    localparam OP_SYSTEM = 7'b1110011;

    // ---------------------------------------------------------------- execute
    // Shift amount is only ever 5 bits; taking more would silently mis-execute
    // SLLI/SRLI/SRAI with large immediates.
    wire [4:0]  shamt   = (opcode == OP_ALUR) ? b[4:0] : insn[24:20];
    wire [31:0] alu_b   = (opcode == OP_ALUR) ? b : imm_i;
    wire        alt     = insn[30];   // selects SUB vs ADD, and SRA vs SRL

    reg [31:0] alu_out;
    always @(*) begin
        case (funct3)
            3'b000: alu_out = (opcode == OP_ALUR && alt) ? (a - alu_b) : (a + alu_b);
            3'b001: alu_out = a << shamt;
            3'b010: alu_out = ($signed(a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            3'b011: alu_out = (a < alu_b) ? 32'd1 : 32'd0;
            3'b100: alu_out = a ^ alu_b;
            // SRA and SRL must be written as separate assignments rather than as two
            // branches of one ternary. A ternary's result signedness is derived from
            // both branches, so pairing a signed branch with an unsigned one makes the
            // whole expression unsigned, and that propagates back into the operands and
            // silently turns >>> into a logical shift. Splitting them gives each
            // assignment its own self-determined context.
            3'b101: begin
                if (alt) alu_out = $signed(a) >>> shamt;   // SRA / SRAI
                else     alu_out = a >> shamt;             // SRL / SRLI
            end
            3'b110: alu_out = a | alu_b;
            3'b111: alu_out = a & alu_b;
            default: alu_out = 32'd0;
        endcase
    end

    // ---------------------------------------------------------------- branches
    reg branch_taken;
    always @(*) begin
        case (funct3)
            3'b000: branch_taken = (a == b);                        // BEQ
            3'b001: branch_taken = (a != b);                        // BNE
            3'b100: branch_taken = ($signed(a) <  $signed(b));      // BLT
            3'b101: branch_taken = ($signed(a) >= $signed(b));      // BGE
            3'b110: branch_taken = (a <  b);                        // BLTU
            3'b111: branch_taken = (a >= b);                        // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    // ------------------------------------------------------------ data memory
    wire [31:0] mem_addr = a + ((opcode == OP_STORE) ? imm_s : imm_i);
    wire [1:0]  byte_off = mem_addr[1:0];

    assign dmem_addr = {mem_addr[31:2], 2'b00};
    assign dmem_we   = (opcode == OP_STORE);

    // Byte and half stores are placed into the addressed lane; the strobe tells the
    // memory which lanes to commit so the rest of the word survives.
    reg [31:0] st_data;
    reg [3:0]  st_strb;
    always @(*) begin
        case (funct3)
            3'b000: begin // SB
                st_data = {4{b[7:0]}};
                st_strb = 4'b0001 << byte_off;
            end
            3'b001: begin // SH
                st_data = {2{b[15:0]}};
                st_strb = byte_off[1] ? 4'b1100 : 4'b0011;
            end
            default: begin // SW
                st_data = b;
                st_strb = 4'b1111;
            end
        endcase
    end
    assign dmem_wdata = st_data;
    assign dmem_wstrb = st_strb;

    // Load extraction mirrors the store lane logic, with sign or zero extension.
    wire [7:0]  ld_byte = dmem_rdata[8*byte_off +: 8];
    wire [15:0] ld_half = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    reg [31:0] load_out;
    always @(*) begin
        case (funct3)
            3'b000: load_out = {{24{ld_byte[7]}},  ld_byte};   // LB
            3'b001: load_out = {{16{ld_half[15]}}, ld_half};   // LH
            3'b010: load_out = dmem_rdata;                     // LW
            3'b100: load_out = {24'b0, ld_byte};               // LBU
            3'b101: load_out = {16'b0, ld_half};               // LHU
            default: load_out = dmem_rdata;
        endcase
    end

    // --------------------------------------------------------- writeback mux
    wire [31:0] pc_plus4 = pc + 32'd4;

    reg [31:0] wb_data;
    reg        wb_en;
    always @(*) begin
        wb_en   = 1'b0;
        wb_data = 32'd0;
        case (opcode)
            OP_LUI:   begin wb_en = 1'b1; wb_data = imm_u; end
            OP_AUIPC: begin wb_en = 1'b1; wb_data = pc + imm_u; end
            OP_JAL:   begin wb_en = 1'b1; wb_data = pc_plus4; end
            OP_JALR:  begin wb_en = 1'b1; wb_data = pc_plus4; end
            OP_LOAD:  begin wb_en = 1'b1; wb_data = load_out; end
            OP_ALUI:  begin wb_en = 1'b1; wb_data = alu_out; end
            OP_ALUR:  begin wb_en = 1'b1; wb_data = alu_out; end
            default:  begin wb_en = 1'b0; wb_data = 32'd0; end
        endcase
    end

    // A write to x0 is architecturally a no-op. Folding that in here means the trace's
    // rd field is zero exactly when no state changed, matching the ISS convention.
    wire commit_we = wb_en && (rd != 5'd0);

    // ----------------------------------------------------------- next-pc logic
    reg [31:0] next_pc;
    always @(*) begin
        case (opcode)
            OP_JAL:    next_pc = pc + imm_j;
            // The spec requires clearing bit 0 of a JALR target.
            OP_JALR:   next_pc = (a + imm_i) & ~32'd1;
            OP_BRANCH: next_pc = branch_taken ? (pc + imm_b) : pc_plus4;
            default:   next_pc = pc_plus4;
        endcase
    end

    // ------------------------------------------------------------- sequential
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc     <= 32'd0;
            halt_r <= 1'b0;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'd0;
        end else if (!halt_r) begin
            if (opcode == OP_SYSTEM) begin
                halt_r <= 1'b1;          // ECALL/EBREAK ends the run, as in the ISS
            end else begin
                if (commit_we) regs[rd] <= wb_data;
                pc <= next_pc;
            end
        end
    end

    // --------------------------------------------------------- trace outputs
    assign retire_pc   = pc;
    assign retire_insn = insn;
    assign retire_rd   = commit_we ? rd : 5'd0;
    assign retire_val  = commit_we ? wb_data : 32'd0;
    assign retire_we   = commit_we;
    assign halted      = halt_r;

endmodule
