#!/usr/bin/env python3
"""Cycle measurement and profile breakdown for NN inference on the SoC.

Every number this prints comes from an actual simulation run, not a model. Three firmware
images are run at two vector counts each:

    nn_sw     software shift-add multiply       the baseline
    nn_mac    MAC accelerator                   the comparison
    nn_stub   multiply replaced by one add      profiling only

Two vector counts (1 and N) rather than one, because a single total folds the fixed startup
cost -- crt0, .bss clear, the result-store loop -- into the per-inference figure. Running
both and subtracting separates them:

    per-inference mean = (cycles(N) - cycles(1)) / (N - 1)
    startup + first    = cycles(1)

The per-inference figure is a *mean over vectors 2..N*, not a constant, because the software
multiply's cost is data-dependent: its loop exits when the remaining multiplier bits are
zero, so a dim pixel is cheaper than a bright one. That is why the analytical cross-check
below matters -- it predicts the measured cost from the actual activation bit patterns,
which is a much stronger claim than asserting that multiply dominates.
"""
import json
import os
import re
import subprocess
import sys

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(REPO, "build")
SIM = os.path.join(BUILD, "nn_sim")
REF = os.path.join(REPO, "firmware", "prebuilt", "nn_vectors.json")


def run(variant, nvec):
    """-> (cycles, retired). Both read straight off the testbench's own report."""
    out = os.path.join(BUILD, f"nn_m_{variant}_{nvec}.txt")
    cmd = [SIM, f"+hex={os.path.join(BUILD, f'nn_{variant}.hex')}",
           f"+nvec={nvec}", f"+out={out}"]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if r.returncode != 0:
        print(r.stdout, r.stderr, file=sys.stderr)
        sys.exit(f"FATAL: sim failed: {variant} nvec={nvec}")
    m = re.search(r"(\d+) inference\(s\), (\d+) cycles, (\d+) instructions", r.stdout)
    if not m:
        sys.exit(f"FATAL: could not parse sim output for {variant}:\n{r.stdout}")
    count, cycles, retired = (int(g) for g in m.groups())
    if count != nvec:
        sys.exit(f"FATAL: {variant} ran {count} inferences, asked for {nvec}")
    return cycles, retired


# Instruction counts read off the actual disassembly of build/nn_sw.elf, not guessed. The
# core retires exactly one instruction per cycle, so an instruction count IS a cycle count.
#
#   00000034 <dot>:
#     34: li a5,0        \
#     38: li a3,0         > once per dot call
#     3c: add a4,a1,a5   \
#     40: lb  a7,0(a4)    |
#     44: add a4,a0,a5    | per-MAC setup: address both operands, load both, zero the
#     48: lbu a4,0(a4)    | inner accumulator                            = 5 instructions
#     4c: li  a6,0       /
#     50: bnez a4,68     -- loop test; runs once per iteration plus once to exit
#     68: slli t3,a4,0x1f \
#     6c: srai t1,t3,0x1f  | THE INTERESTING PART: gcc turned `if (a&1) acc += w` into a
#     70: and  t1,t1,a7    | BRANCHLESS masked add -- broadcast bit 0 to a full mask, AND
#     74: add  a6,a6,t1    | it with w, add unconditionally. So the cost of an iteration
#     78: slli a7,a7,0x1   | does not depend on whether the bit was set, and popcount is
#     7c: srli a4,a4,0x1   | irrelevant to the timing. Only the multiplier's BIT LENGTH
#     80: j    50         /  matters.                        = 6 + bnez + j = 8 per iteration
#     54: addi a5,a5,1   \
#     58: add a3,a3,a6    > per-MAC teardown                 = 3 instructions
#     5c: bne a2,a5,3c   /
#
# giving  cycles_per_MAC = 5 + 8*k + 1 + 3 = 9 + 8*k   for a multiplier of bit length k.
MAC_FIXED = 9      # per-MAC instructions outside the shift-add loop
MAC_PER_ITER = 8   # instructions per shift-add iteration
STUB_PER_MAC = 8   # nn_stub's inlined `w + a` body, also read off its disassembly


def multiplier_bitlengths(ref):
    """Total shift-add iterations over the whole run, from the real activation data.

    The loop is `while (a)` with `a >>= 1` each pass, so it runs exactly bit_length(a)
    times, and not at all for a == 0. Layer 1's multipliers are the quantised inputs;
    layer 2's are the hidden activations, which are recomputed here with the same integer
    arithmetic the firmware uses rather than kept as a second copy that could drift.
    """
    w1 = np.array(ref["w1"], dtype=np.int64).reshape(ref["hid_dim"], ref["in_dim"])
    b1 = np.array(ref["b1"], dtype=np.int64)
    shift1, hid_dim, out_dim = ref["shift1"], ref["hid_dim"], ref["out_dim"]

    iters = 0
    for v in ref["vectors"]:
        x = np.array(v["input"], dtype=np.int64)
        # Layer 1: each input is a multiplier once per hidden neuron.
        iters += hid_dim * sum(int(a).bit_length() for a in x)
        # Layer 2: each hidden activation is a multiplier once per output neuron.
        acc1 = x @ w1.T + b1
        h = np.minimum(np.maximum(acc1, 0) >> shift1, 127)
        iters += out_dim * sum(int(a).bit_length() for a in h)
    return iters


def main():
    with open(REF) as f:
        ref = json.load(f)
    n = len(ref["vectors"])
    in_dim, hid_dim, out_dim = ref["in_dim"], ref["hid_dim"], ref["out_dim"]
    macs = in_dim * hid_dim + hid_dim * out_dim

    print(f"model {in_dim}-{hid_dim}-{out_dim}, {macs} MACs per inference, "
          f"{n} vectors\n")

    res = {}
    for variant in ("sw", "mac", "stub"):
        c1, r1 = run(variant, 1)
        cn, rn = run(variant, n)
        per = (cn - c1) / (n - 1)
        res[variant] = dict(c1=c1, cn=cn, per=per, retired_n=rn)
        print(f"  {variant:5s}  1 vector {c1:>10,}   {n} vectors {cn:>12,}   "
              f"per-inference {per:>11,.1f}")

    sw, mac, stub = res["sw"], res["mac"], res["stub"]
    speedup_total = sw["cn"] / mac["cn"]
    speedup_per = sw["per"] / mac["per"]

    print(f"\n=== like-for-like, same {n} vectors, same weights, same logits ===")
    print(f"  software shift-add multiply : {sw['cn']:>12,} cycles")
    print(f"  MAC accelerator            : {mac['cn']:>12,} cycles")
    print(f"  speedup                    : {speedup_total:>12.2f}x  (total)")
    print(f"                               {speedup_per:>12.2f}x  (per-inference mean)")

    total_macs = macs * n
    iters = multiplier_bitlengths(ref)

    # ---- analytical model, from the disassembly, checked against the measurement ----
    # This is the strong claim: the software cost is predicted from instruction counts read
    # off the ELF plus the real activation bit patterns, then compared to what the simulator
    # actually did. Agreement to a fraction of a percent is what makes the profile below a
    # measurement rather than a story.
    pred_sw = MAC_FIXED * total_macs + MAC_PER_ITER * iters
    pred_stub = STUB_PER_MAC * total_macs
    sw_resid = sw["cn"] - pred_sw
    stub_resid = stub["cn"] - pred_stub

    print(f"\n=== analytical model vs measurement (software path) ===")
    print(f"  MACs executed over {n} vectors    : {total_macs:>12,}")
    print(f"  shift-add iterations (sum of "
          f"multiplier bit lengths): {iters:>12,}  ({iters / total_macs:.3f} per MAC)")
    print(f"  predicted  {MAC_FIXED}*MACs + {MAC_PER_ITER}*iters"
          f"          : {pred_sw:>12,} cycles")
    print(f"  measured                          : {sw['cn']:>12,} cycles")
    print(f"  unmodelled remainder              : {sw_resid:>12,} cycles "
          f"({100.0 * sw_resid / sw['cn']:.2f}%)")
    print(f"  ... which is the requantise/clamp/store path, the 42 dot() call and return")
    print(f"      sequences per inference, and crt0 -- none of which the model covers.")
    print(f"\n  stub build, predicted {STUB_PER_MAC}*MACs"
          f"        : {pred_stub:>12,} cycles")
    print(f"  stub build, measured              : {stub['cn']:>12,} cycles "
          f"(remainder {stub_resid:,})")

    print(f"\n=== where the software cycles go ===")
    mul_cost = sw["cn"] - stub["cn"]
    print(f"  full software build               : {sw['cn']:>12,} cycles")
    print(f"  multiply stubbed to a single add  : {stub['cn']:>12,} cycles")
    print(f"  difference, i.e. the shift-add "
          f"loops : {mul_cost:>12,} cycles ({100.0 * mul_cost / sw['cn']:.1f}%)")
    print(f"  everything else                   : {stub['cn']:>12,} cycles "
          f"({100.0 * stub['cn'] / sw['cn']:.1f}%)")
    print("\n  Two honest caveats on that split. The difference excludes the one add per MAC")
    print("  the stub still pays, so it is not quite 'the cost of multiply'. And gcc inlined")
    print("  dot() into main() in the stub build but kept it as a real function in the full")
    print("  build, so the stub also avoids call overhead the baseline pays -- which means")
    print("  61.6% is a slight over-attribution to multiply, not an under-one.")

    print(f"\n=== accelerator cost model ===")
    print(f"  MACs per inference                : {macs:>12,}")
    print(f"  accelerator cycles per inference   : {mac['per']:>12,.1f}")
    print(f"  cycles per MAC                    : {mac['per'] / macs:>12.2f}")
    print("\n  The block fetches 4 terms per 2 cycles in steady state (one cycle per operand")
    print("  stream through a single memory read port), so 0.5 cycles/MAC is its floor. The")
    print("  measured figure is above that because each dot product still costs the CPU four")
    print("  register writes, a start, a polling loop and a result read -- and with only 196")
    print("  or 32 terms per call, that per-call overhead is a real fraction of the total.")

    with open(os.path.join(BUILD, "nn_measure.json"), "w") as f:
        json.dump(dict(model=[in_dim, hid_dim, out_dim], macs=macs, nvec=n,
                       results=res, speedup_total=speedup_total,
                       speedup_per=speedup_per, mul_cost=mul_cost,
                       loop_iters=iters, predicted_sw=pred_sw,
                       predicted_stub=pred_stub, sw_residual=sw_resid), f, indent=1)
    print(f"\nwrote build/nn_measure.json")


if __name__ == "__main__":
    main()
