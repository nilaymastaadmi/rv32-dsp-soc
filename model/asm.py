#!/usr/bin/env python3
"""Minimal two-pass RV32I assembler.

Exists so the project is self-contained: we can build and verify the core without
depending on a cross-compiler being installed. Emits a flat hex image, one 32-bit word
per line, suitable for both the C++ ISS's loader and Verilog's $readmemh.
"""
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
REGS.update({
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23, "s8": 24, "s9": 25,
    "s10": 26, "s11": 27, "t3": 28, "t4": 29, "t5": 30, "t6": 31,
})

# funct3/funct7 tables
ALU_R = {  # name: (funct3, funct7)
    "add": (0x0, 0x00), "sub": (0x0, 0x20), "sll": (0x1, 0x00), "slt": (0x2, 0x00),
    "sltu": (0x3, 0x00), "xor": (0x4, 0x00), "srl": (0x5, 0x00), "sra": (0x5, 0x20),
    "or": (0x6, 0x00), "and": (0x7, 0x00),
}
ALU_I = {"addi": 0x0, "slti": 0x2, "sltiu": 0x3, "xori": 0x4, "ori": 0x6, "andi": 0x7}
SHIFT_I = {"slli": (0x1, 0x00), "srli": (0x5, 0x00), "srai": (0x5, 0x20)}
LOADS = {"lb": 0x0, "lh": 0x1, "lw": 0x2, "lbu": 0x4, "lhu": 0x5}
STORES = {"sb": 0x0, "sh": 0x1, "sw": 0x2}
BRANCHES = {"beq": 0x0, "bne": 0x1, "blt": 0x4, "bge": 0x5, "bltu": 0x6, "bgeu": 0x7}


def reg(tok):
    t = tok.strip().lower()
    if t not in REGS:
        raise ValueError(f"unknown register {tok!r}")
    return REGS[t]


def parse_lines(text):
    """-> list of (label_or_None, mnemonic_or_None, [operands])"""
    out = []
    for raw in text.splitlines():
        line = re.sub(r"[#;].*$", "", raw)          # strip comments
        line = re.sub(r"//.*$", "", line).strip()
        if not line:
            continue
        while True:
            m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", line)
            if not m:
                break
            out.append((m.group(1), None, []))
            line = m.group(2).strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].lower()
        ops = []
        if len(parts) > 1:
            ops = [o.strip() for o in parts[1].split(",")]
        out.append((None, mnem, ops))
    return out


def expand_pseudo(mnem, ops):
    """Return a list of (mnem, ops) real instructions."""
    if mnem == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if mnem == "mv":
        return [("addi", [ops[0], ops[1], "0"])]
    if mnem == "not":
        return [("xori", [ops[0], ops[1], "-1"])]
    if mnem == "neg":
        return [("sub", [ops[0], "x0", ops[1]])]
    if mnem == "j":
        return [("jal", ["x0", ops[0]])]
    if mnem == "jr":
        return [("jalr", ["x0", ops[0], "0"])]
    if mnem == "ret":
        return [("jalr", ["x0", "x1", "0"])]
    if mnem == "beqz":
        return [("beq", [ops[0], "x0", ops[1]])]
    if mnem == "bnez":
        return [("bne", [ops[0], "x0", ops[1]])]
    if mnem == "li":
        # Small immediates fit in one ADDI; anything else needs LUI+ADDI, with the
        # low-12 sign extension compensated for in the upper part.
        val = int(ops[1], 0) & 0xFFFFFFFF
        sv = val - (1 << 32) if val >> 31 else val
        if -2048 <= sv < 2048:
            return [("addi", [ops[0], "x0", str(sv)])]
        lo = val & 0xFFF
        hi = (val - (lo - 0x1000 if lo & 0x800 else lo)) & 0xFFFFFFFF
        seq = [("lui", [ops[0], hex(hi >> 12)])]
        if lo:
            slo = lo - 0x1000 if lo & 0x800 else lo
            seq.append(("addi", [ops[0], ops[0], str(slo)]))
        return seq
    if mnem == "la":
        return [("__la", ops)]      # resolved during encode (needs label address)
    return [(mnem, ops)]


def mem_operand(tok):
    """Parse 'imm(rs1)' or bare 'rs1' -> (imm, rs1)."""
    m = re.match(r"^\s*(-?\w+)?\s*\(\s*([A-Za-z0-9]+)\s*\)\s*$", tok)
    if m:
        return (int(m.group(1), 0) if m.group(1) else 0), reg(m.group(2))
    return 0, reg(tok)


def assemble(text, base=0):
    items = []
    for label, mnem, ops in parse_lines(text):
        if label is not None:
            items.append(("label", label))
        else:
            for m, o in expand_pseudo(mnem, ops):
                items.append(("insn", (m, o)))

    # Pass 1: assign addresses (every real instruction is 4 bytes).
    labels, addr = {}, base
    for kind, payload in items:
        if kind == "label":
            labels[payload] = addr
        else:
            addr += 4

    # Pass 2: encode.
    words, addr = [], base
    for kind, payload in items:
        if kind == "label":
            continue
        mnem, ops = payload
        words.append(encode(mnem, ops, addr, labels))
        addr += 4
    return words


def resolve(tok, labels, pc=None, relative=False):
    tok = tok.strip()
    if tok in labels:
        return labels[tok] - (pc if relative else 0)
    return int(tok, 0)


def encode(mnem, ops, pc, labels):
    def R(rd, rs1, rs2, f3, f7, op=0x33):
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    def I(rd, rs1, imm, f3, op):
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    if mnem in ALU_R:
        f3, f7 = ALU_R[mnem]
        return R(reg(ops[0]), reg(ops[1]), reg(ops[2]), f3, f7)

    if mnem in ALU_I:
        imm = resolve(ops[2], labels)
        return I(reg(ops[0]), reg(ops[1]), imm, ALU_I[mnem], 0x13)

    if mnem in SHIFT_I:
        f3, f7 = SHIFT_I[mnem]
        sh = resolve(ops[2], labels) & 0x1F
        return ((f7 << 25) | (sh << 20) | (reg(ops[1]) << 15) | (f3 << 12)
                | (reg(ops[0]) << 7) | 0x13)

    if mnem in LOADS:
        imm, rs1 = mem_operand(ops[1])
        return I(reg(ops[0]), rs1, imm, LOADS[mnem], 0x03)

    if mnem in STORES:
        imm, rs1 = mem_operand(ops[1])
        rs2 = reg(ops[0])
        return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) \
            | (STORES[mnem] << 12) | ((imm & 0x1F) << 7) | 0x23

    if mnem in BRANCHES:
        off = resolve(ops[2], labels, pc, relative=True)
        f3 = BRANCHES[mnem]
        return ((((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25)
                | (reg(ops[1]) << 20) | (reg(ops[0]) << 15) | (f3 << 12)
                | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63)

    if mnem == "jal":
        if len(ops) == 1:
            rd, target = 1, ops[0]
        else:
            rd, target = reg(ops[0]), ops[1]
        off = resolve(target, labels, pc, relative=True)
        return ((((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21)
                | (((off >> 11) & 1) << 20) | (((off >> 12) & 0xFF) << 12)
                | (rd << 7) | 0x6F)

    if mnem == "jalr":
        if len(ops) == 1:
            return I(1, reg(ops[0]), 0, 0x0, 0x67)
        if len(ops) == 2:
            imm, rs1 = mem_operand(ops[1])
            return I(reg(ops[0]), rs1, imm, 0x0, 0x67)
        return I(reg(ops[0]), reg(ops[1]), resolve(ops[2], labels), 0x0, 0x67)

    if mnem == "lui":
        return ((resolve(ops[1], labels) & 0xFFFFF) << 12) | (reg(ops[0]) << 7) | 0x37
    if mnem == "auipc":
        return ((resolve(ops[1], labels) & 0xFFFFF) << 12) | (reg(ops[0]) << 7) | 0x17

    if mnem == "__la":
        # la rd, label  ->  auipc-free simplification: absolute address via addi from x0.
        return I(reg(ops[0]), 0, resolve(ops[1], labels), 0x0, 0x13)

    if mnem in ("ecall", "ebreak"):
        return 0x00000073 | ((1 << 20) if mnem == "ebreak" else 0)
    if mnem == "fence":
        return 0x0000000F

    raise ValueError(f"unsupported mnemonic {mnem!r}")


def main():
    if len(sys.argv) < 3:
        sys.exit(f"usage: {sys.argv[0]} <in.s> <out.hex>")
    with open(sys.argv[1]) as f:
        words = assemble(f.read())
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"assembled {len(words)} instruction(s) -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
