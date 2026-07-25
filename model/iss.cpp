// RV32I instruction-set simulator, used as the golden reference model for the RTL core.
//
// Design intent: this is the arbiter of correctness, so it is written for clarity and
// auditability rather than speed. Every instruction retires through a single writeback
// path (wb()) and emits one trace line, so the RTL testbench can produce the identical
// format and a plain diff becomes the pass/fail signal.
//
// Trace format, one line per retired instruction:
//   <pc> <insn> <rd> <rd_value>
// rd == 0 means "no architectural register write" (x0 is hardwired to zero, so a write
// to it is indistinguishable from no write, which makes 0 an unambiguous sentinel).

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

class RV32I {
public:
    static constexpr uint32_t MEM_WORDS = 1 << 16;   // 256 KB of word-addressed memory

    RV32I() : pc(0), halted(false), retired(0) {
        std::memset(x, 0, sizeof(x));
        mem.assign(MEM_WORDS, 0);
    }

    // ---- memory: word-addressed store, little-endian byte/half accessors ----
    uint32_t load_word(uint32_t addr) const {
        uint32_t w = addr >> 2;
        return (w < MEM_WORDS) ? mem[w] : 0;
    }
    void store_word(uint32_t addr, uint32_t val) {
        uint32_t w = addr >> 2;
        if (w < MEM_WORDS) mem[w] = val;
    }
    uint8_t load_byte(uint32_t addr) const {
        return (load_word(addr) >> (8 * (addr & 3))) & 0xFF;
    }
    uint16_t load_half(uint32_t addr) const {
        return (load_word(addr) >> (8 * (addr & 2))) & 0xFFFF;
    }
    void store_byte(uint32_t addr, uint8_t val) {
        uint32_t w = load_word(addr);
        uint32_t sh = 8 * (addr & 3);
        store_word(addr, (w & ~(0xFFu << sh)) | (uint32_t(val) << sh));
    }
    void store_half(uint32_t addr, uint16_t val) {
        uint32_t w = load_word(addr);
        uint32_t sh = 8 * (addr & 2);
        store_word(addr, (w & ~(0xFFFFu << sh)) | (uint32_t(val) << sh));
    }

    bool load_hex(const char *path) {
        FILE *f = std::fopen(path, "r");
        if (!f) return false;
        uint32_t addr = 0, val;
        char line[256];
        while (std::fgets(line, sizeof(line), f)) {
            // "@ADDR" sets the current word address; bare hex words load sequentially.
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '\0' || *p == '\n' || *p == '#' || (*p == '/' && p[1] == '/')) continue;
            if (*p == '@') { addr = std::strtoul(p + 1, nullptr, 16); continue; }
            val = std::strtoul(p, nullptr, 16);
            if (addr < MEM_WORDS) mem[addr++] = val;
        }
        std::fclose(f);
        return true;
    }

    void run(uint64_t max_insns, FILE *trace) {
        while (!halted && retired < max_insns) step(trace);
    }

    uint32_t reg(int i) const { return x[i]; }
    uint64_t insns_retired() const { return retired; }
    bool is_halted() const { return halted; }

private:
    uint32_t x[32];
    uint32_t pc;
    std::vector<uint32_t> mem;
    bool halted;
    uint64_t retired;

    // Pending architectural writeback for the current instruction.
    int wb_rd = 0;
    uint32_t wb_val = 0;

    void wb(int rd, uint32_t val) {
        // x0 is hardwired to zero: the write is architecturally discarded, but we keep
        // rd == 0 as the trace sentinel meaning "nothing was written".
        if (rd != 0) { x[rd] = val; wb_rd = rd; wb_val = val; }
        else         { wb_rd = 0;   wb_val = 0; }
    }

    // ---- immediate decoders, kept separate because the B/J bit scrambling is the
    // ---- single most common source of silent decode bugs in an RV32I implementation.
    static int32_t imm_i(uint32_t in) { return int32_t(in) >> 20; }
    static int32_t imm_s(uint32_t in) {
        uint32_t v = ((in >> 25) << 5) | ((in >> 7) & 0x1F);
        return int32_t(v << 20) >> 20;
    }
    static int32_t imm_b(uint32_t in) {
        uint32_t v = (((in >> 31) & 1) << 12) | (((in >> 7) & 1) << 11)
                   | (((in >> 25) & 0x3F) << 5) | (((in >> 8) & 0xF) << 1);
        return int32_t(v << 19) >> 19;
    }
    static int32_t imm_u(uint32_t in) { return int32_t(in & 0xFFFFF000u); }
    static int32_t imm_j(uint32_t in) {
        uint32_t v = (((in >> 31) & 1) << 20) | (((in >> 12) & 0xFF) << 12)
                   | (((in >> 20) & 1) << 11) | (((in >> 21) & 0x3FF) << 1);
        return int32_t(v << 11) >> 11;
    }

    void step(FILE *trace) {
        uint32_t this_pc = pc;
        uint32_t in = load_word(pc);
        uint32_t next_pc = pc + 4;

        uint32_t opcode = in & 0x7F;
        int rd  = (in >> 7)  & 0x1F;
        int rs1 = (in >> 15) & 0x1F;
        int rs2 = (in >> 20) & 0x1F;
        uint32_t f3 = (in >> 12) & 0x7;
        uint32_t f7 = (in >> 25) & 0x7F;
        uint32_t a = x[rs1], b = x[rs2];

        wb_rd = 0; wb_val = 0;

        switch (opcode) {
        case 0x37: wb(rd, uint32_t(imm_u(in))); break;                 // LUI
        case 0x17: wb(rd, this_pc + uint32_t(imm_u(in))); break;       // AUIPC

        case 0x6F:                                                      // JAL
            wb(rd, next_pc);
            next_pc = this_pc + uint32_t(imm_j(in));
            break;

        case 0x67:                                                      // JALR
            wb(rd, next_pc);
            // The low bit of the computed target is cleared, per the spec.
            next_pc = (a + uint32_t(imm_i(in))) & ~1u;
            break;

        case 0x63: {                                                    // branches
            bool take = false;
            switch (f3) {
            case 0x0: take = (a == b); break;                                  // BEQ
            case 0x1: take = (a != b); break;                                  // BNE
            case 0x4: take = (int32_t(a) <  int32_t(b)); break;                // BLT
            case 0x5: take = (int32_t(a) >= int32_t(b)); break;                // BGE
            case 0x6: take = (a <  b); break;                                  // BLTU
            case 0x7: take = (a >= b); break;                                  // BGEU
            default: bad(in, this_pc); return;
            }
            // Branch target is relative to the branch's own PC, not PC+4.
            if (take) next_pc = this_pc + uint32_t(imm_b(in));
            break;
        }

        case 0x03: {                                                    // loads
            uint32_t addr = a + uint32_t(imm_i(in));
            switch (f3) {
            case 0x0: wb(rd, uint32_t(int32_t(int8_t (load_byte(addr))))); break;  // LB
            case 0x1: wb(rd, uint32_t(int32_t(int16_t(load_half(addr))))); break;  // LH
            case 0x2: wb(rd, load_word(addr)); break;                             // LW
            case 0x4: wb(rd, uint32_t(load_byte(addr))); break;                   // LBU
            case 0x5: wb(rd, uint32_t(load_half(addr))); break;                   // LHU
            default: bad(in, this_pc); return;
            }
            break;
        }

        case 0x23: {                                                    // stores
            uint32_t addr = a + uint32_t(imm_s(in));
            switch (f3) {
            case 0x0: store_byte(addr, uint8_t(b)); break;                        // SB
            case 0x1: store_half(addr, uint16_t(b)); break;                       // SH
            case 0x2: store_word(addr, b); break;                                 // SW
            default: bad(in, this_pc); return;
            }
            break;
        }

        case 0x13: {                                                    // ALU immediate
            int32_t imm = imm_i(in);
            uint32_t sh = imm & 0x1F;   // shifts use only the low 5 bits of the immediate
            switch (f3) {
            case 0x0: wb(rd, a + uint32_t(imm)); break;                           // ADDI
            case 0x2: wb(rd, int32_t(a) < imm ? 1 : 0); break;                    // SLTI
            case 0x3: wb(rd, a < uint32_t(imm) ? 1 : 0); break;                   // SLTIU
            case 0x4: wb(rd, a ^ uint32_t(imm)); break;                           // XORI
            case 0x6: wb(rd, a | uint32_t(imm)); break;                           // ORI
            case 0x7: wb(rd, a & uint32_t(imm)); break;                           // ANDI
            case 0x1: wb(rd, a << sh); break;                                     // SLLI
            case 0x5:
                // SRLI vs SRAI is distinguished by bit 30, not by a full funct7 compare.
                if ((in >> 30) & 1) wb(rd, uint32_t(int32_t(a) >> sh));           // SRAI
                else                wb(rd, a >> sh);                              // SRLI
                break;
            default: bad(in, this_pc); return;
            }
            break;
        }

        case 0x33: {                                                    // ALU register
            uint32_t sh = b & 0x1F;
            if (f7 == 0x00) {
                switch (f3) {
                case 0x0: wb(rd, a + b); break;                                   // ADD
                case 0x1: wb(rd, a << sh); break;                                 // SLL
                case 0x2: wb(rd, int32_t(a) < int32_t(b) ? 1 : 0); break;         // SLT
                case 0x3: wb(rd, a < b ? 1 : 0); break;                           // SLTU
                case 0x4: wb(rd, a ^ b); break;                                   // XOR
                case 0x5: wb(rd, a >> sh); break;                                 // SRL
                case 0x6: wb(rd, a | b); break;                                   // OR
                case 0x7: wb(rd, a & b); break;                                   // AND
                default: bad(in, this_pc); return;
                }
            } else if (f7 == 0x20) {
                switch (f3) {
                case 0x0: wb(rd, a - b); break;                                   // SUB
                case 0x5: wb(rd, uint32_t(int32_t(a) >> sh)); break;              // SRA
                default: bad(in, this_pc); return;
                }
            } else { bad(in, this_pc); return; }
            break;
        }

        case 0x0F: break;                                               // FENCE: no-op here

        case 0x73:                                                      // ECALL / EBREAK
            halted = true;
            break;

        default:
            bad(in, this_pc);
            return;
        }

        x[0] = 0;   // belt-and-braces: x0 must read as zero no matter what happened above
        pc = next_pc;
        retired++;
        if (trace) std::fprintf(trace, "%08x %08x %2d %08x\n", this_pc, in, wb_rd, wb_val);
    }

    void bad(uint32_t in, uint32_t at) {
        std::fprintf(stderr, "ISS: illegal instruction %08x at pc=%08x\n", in, at);
        halted = true;
    }
};

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr,
            "usage: %s <program.hex> [trace.out] [max_insns]\n", argv[0]);
        return 2;
    }
    RV32I cpu;
    if (!cpu.load_hex(argv[1])) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }

    FILE *trace = nullptr;
    if (argc >= 3 && std::strcmp(argv[2], "-") != 0) {
        trace = std::fopen(argv[2], "w");
        if (!trace) { std::fprintf(stderr, "cannot write %s\n", argv[2]); return 2; }
    }
    uint64_t maxi = (argc >= 4) ? std::strtoull(argv[3], nullptr, 0) : 1000000;

    cpu.run(maxi, trace);
    if (trace) std::fclose(trace);

    std::fprintf(stderr, "ISS: retired %llu instruction(s), %s\n",
                 (unsigned long long)cpu.insns_retired(),
                 cpu.is_halted() ? "halted" : "instruction limit reached");
    for (int i = 0; i < 32; i += 4) {
        std::fprintf(stderr, "  x%-2d=%08x  x%-2d=%08x  x%-2d=%08x  x%-2d=%08x\n",
            i, cpu.reg(i), i+1, cpu.reg(i+1), i+2, cpu.reg(i+2), i+3, cpu.reg(i+3));
    }
    return 0;
}
