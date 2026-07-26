#!/usr/bin/env python3
"""Instruction coverage over the randomized regression traces.

A regression is only as good as what it actually reached. This decodes every retired
instruction from the ISS traces and reports which of the RV32I base instructions were
exercised and how often, so "400 programs" can be replaced by a real coverage figure and
the holes can be named rather than assumed absent.
"""
import glob
import sys
from collections import Counter

# The RV32I base integer set, excluding FENCE and the CSR instructions which this core
# does not implement.
RV32I = [
    "LUI", "AUIPC", "JAL", "JALR",
    "BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU",
    "LB", "LH", "LW", "LBU", "LHU",
    "SB", "SH", "SW",
    "ADDI", "SLTI", "SLTIU", "XORI", "ORI", "ANDI", "SLLI", "SRLI", "SRAI",
    "ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND",
    "ECALL",
]

BRANCH = {0: "BEQ", 1: "BNE", 4: "BLT", 5: "BGE", 6: "BLTU", 7: "BGEU"}
LOAD = {0: "LB", 1: "LH", 2: "LW", 4: "LBU", 5: "LHU"}
STORE = {0: "SB", 1: "SH", 2: "SW"}
ALUI = {0: "ADDI", 2: "SLTI", 3: "SLTIU", 4: "XORI", 6: "ORI", 7: "ANDI"}
ALUR = {0: "ADD", 1: "SLL", 2: "SLT", 3: "SLTU", 4: "XOR", 5: "SRL", 6: "OR", 7: "AND"}


def decode(insn):
    op = insn & 0x7F
    f3 = (insn >> 12) & 0x7
    bit30 = (insn >> 30) & 1
    if op == 0x37: return "LUI"
    if op == 0x17: return "AUIPC"
    if op == 0x6F: return "JAL"
    if op == 0x67: return "JALR"
    if op == 0x63: return BRANCH.get(f3)
    if op == 0x03: return LOAD.get(f3)
    if op == 0x23: return STORE.get(f3)
    if op == 0x13:
        if f3 == 1: return "SLLI"
        if f3 == 5: return "SRAI" if bit30 else "SRLI"
        return ALUI.get(f3)
    if op == 0x33:
        if f3 == 0: return "SUB" if bit30 else "ADD"
        if f3 == 5: return "SRA" if bit30 else "SRL"
        return ALUR.get(f3)
    if op == 0x73: return "ECALL"
    return None


def main():
    patterns = sys.argv[1:] or ["build/rand/*.iss", "build/*.iss.trace"]
    files = []
    for p in patterns:
        files.extend(glob.glob(p))
    if not files:
        sys.exit("no trace files matched")

    counts = Counter()
    total = 0
    for path in files:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2:
                    continue
                name = decode(int(parts[1], 16))
                if name:
                    counts[name] += 1
                    total += 1

    hit = [m for m in RV32I if counts[m] > 0]
    missed = [m for m in RV32I if counts[m] == 0]

    print(f"trace files      : {len(files)}")
    print(f"instructions     : {total:,}")
    print(f"RV32I coverage   : {len(hit)}/{len(RV32I)} "
          f"({100.0 * len(hit) / len(RV32I):.1f}%)")
    print()
    print("counts per instruction:")
    for m in RV32I:
        bar = "#" * min(40, counts[m] * 40 // max(1, max(counts.values())))
        print(f"  {m:<6} {counts[m]:>8,}  {bar}")
    if missed:
        print()
        print("NOT REACHED:", ", ".join(missed))


if __name__ == "__main__":
    main()
