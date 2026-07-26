#!/usr/bin/env python3
"""Constrained-random RV32I program generator.

Directed tests only cover the cases you thought of. This emits random but legal
instruction streams so the core gets hit with operand and immediate combinations nobody
chose deliberately, which is where sign-extension, shift-amount and byte-lane bugs
actually live.

Constraints that keep a random stream meaningful rather than merely chaotic:
  - control flow is emitted, but only ever FORWARD, so the program is a DAG and
    termination is still guaranteed without an instruction-count cap
  - x31 is reserved as the data base pointer and never written, so memory operations
    always land in a known-safe window well clear of the program image
  - shift amounts are drawn from the full 0..31 range including the boundaries

The forward-only rule is what makes branch coverage possible at all here. An earlier
version emitted no control flow, which guaranteed termination but left all eight branch
and jump instructions at zero coverage: the regression looked large while never testing
the PC-redirect path. Measuring coverage is what surfaced that.
"""
import random
import sys

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
LOADS = ["lb", "lh", "lw", "lbu", "lhu"]
STORES = ["sb", "sh", "sw"]

BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]

DATA_BASE = 0x1000
DATA_SPAN = 0x400

# x0 is readable but never meaningfully written; x31 is the reserved data pointer.
# x29 and x30 double as jump scratch, which is harmless since they hold random values.
WRITABLE = list(range(0, 31))
READABLE = list(range(0, 32))
JUMP_SCRATCH = 30


def interesting_imm(rng):
    """Bias toward values that break naive implementations."""
    return rng.choice([
        0, 1, -1, 2047, -2048, 2046, -2047,
        rng.randint(-2048, 2047), rng.randint(-2048, 2047),
    ])


def interesting_word(rng):
    return rng.choice([
        0x00000000, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x0000FFFF, 0xFFFF0000,
        0x00000001, 0xDEADBEEF, 0x12345678, 0x80000001,
        rng.getrandbits(32),
    ])


def gen(seed, n_body):
    rng = random.Random(seed)
    out = [f"# constrained-random RV32I test, seed={seed}, body={n_body}"]

    # Seed the architectural state with values chosen to stress sign boundaries.
    out.append(f"    li x31, {hex(DATA_BASE)}")
    for r in range(1, 31):
        out.append(f"    li x{r}, {hex(interesting_word(rng))}")

    label_n = 0

    def filler(count):
        """Straight-line instructions used as branch-shadow bodies."""
        out = []
        for _ in range(count):
            out.append(f"    addi x{rng.choice(WRITABLE)}, x{rng.choice(READABLE)}, "
                       f"{interesting_imm(rng)}")
        return out

    for _ in range(n_body):
        kind = rng.choices(
            ["r", "i", "sh", "ld", "st", "lui", "auipc", "br", "jal", "jalr"],
            weights=[26, 19, 12, 12, 10, 3, 3, 9, 3, 3],
        )[0]

        rd = rng.choice(WRITABLE)
        rs1 = rng.choice(READABLE)
        rs2 = rng.choice(READABLE)

        # ---- control flow: forward only, so the program stays a DAG ----
        if kind in ("br", "jal", "jalr"):
            label_n += 1
            lab = f"L{label_n}"
            shadow = rng.randint(1, 3)

            if kind == "br":
                # Operands are random, so taken and not-taken both occur across seeds,
                # and both paths converge on the label.
                out.append(f"    {rng.choice(BRANCHES)} x{rs1}, x{rs2}, {lab}")
            elif kind == "jal":
                # Unconditional forward jump; the shadow instructions are unreachable,
                # which is itself worth exercising.
                out.append(f"    jal x{rng.choice(WRITABLE)}, {lab}")
            else:
                # Indirect jump: materialise the target address, then jump through it.
                # Emitted adjacently so nothing can clobber the scratch register between.
                out.append(f"    la x{JUMP_SCRATCH}, {lab}")
                out.append(f"    jalr x0, x{JUMP_SCRATCH}, 0")

            out.extend(filler(shadow))
            out.append(f"{lab}:")
            continue

        if kind == "r":
            out.append(f"    {rng.choice(R_OPS)} x{rd}, x{rs1}, x{rs2}")
        elif kind == "i":
            out.append(f"    {rng.choice(I_OPS)} x{rd}, x{rs1}, {interesting_imm(rng)}")
        elif kind == "sh":
            # Includes 0 and 31, the two amounts most likely to expose a bad mask.
            out.append(f"    {rng.choice(SH_OPS)} x{rd}, x{rs1}, {rng.choice([0, 1, 31, 30, rng.randint(0, 31)])}")
        elif kind == "ld":
            op = rng.choice(LOADS)
            # Align the offset to the access width so the model comparison stays
            # meaningful; misaligned behaviour is out of scope for this core.
            step = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}[op]
            off = rng.randrange(0, DATA_SPAN, step)
            out.append(f"    {op} x{rd}, {off}(x31)")
        elif kind == "st":
            op = rng.choice(STORES)
            step = {"sb": 1, "sh": 2, "sw": 4}[op]
            off = rng.randrange(0, DATA_SPAN, step)
            out.append(f"    {op} x{rs2}, {off}(x31)")
        elif kind == "lui":
            out.append(f"    lui x{rd}, {hex(rng.getrandbits(20))}")
        else:
            out.append(f"    auipc x{rd}, {hex(rng.getrandbits(20))}")

    out.append("    ecall")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 3:
        sys.exit(f"usage: {sys.argv[0]} <seed> <out.s> [n_body]")
    seed = int(sys.argv[1])
    n_body = int(sys.argv[3]) if len(sys.argv) > 3 else 150
    with open(sys.argv[2], "w") as f:
        f.write(gen(seed, n_body))


if __name__ == "__main__":
    main()
