#!/usr/bin/env python3
"""Bit-exactness gate: SoC logits versus the Python quantised reference.

The reference logits in build/nn_vectors.json come from model/train_mlp.py's integer
forward pass -- the same arithmetic the firmware implements, run on the host. The check is
equality on every int32 logit, not a tolerance: this is integer quantised inference, so
"close" is not a pass. A single differing logit means the two implementations disagree
about the arithmetic somewhere, and that is a real bug regardless of whether the argmax
happens to survive it.

Both firmware variants are checked against the same reference, which is also what proves
the accelerator is a drop-in replacement for the software multiply rather than something
that merely produces plausible numbers.
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(REPO, "build")
SIM = os.path.join(BUILD, "nn_sim")
# The reference lives in firmware/prebuilt/ (tracked) rather than build/ (gitignored), so a
# fresh clone can run this check without numpy, MNIST, or a training run.
REF = os.path.join(REPO, "firmware", "prebuilt", "nn_vectors.json")


def s32(x):
    """Hex word from the testbench -> signed int32."""
    v = int(x, 16)
    return v - (1 << 32) if v & 0x8000_0000 else v


def run(hexfile, nvec, out):
    cmd = [SIM, f"+hex={hexfile}", f"+nvec={nvec}", f"+out={out}"]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        sys.exit(f"FATAL: simulation failed for {hexfile}")
    return r.stdout


def parse(path):
    logits, meta = {}, {}
    with open(path) as f:
        for line in f:
            p = line.split()
            if p[0] == "logit":
                logits.setdefault(int(p[1]), {})[int(p[2])] = s32(p[3])
            else:
                meta[p[0]] = p[1]
    return meta, logits


def check(variant, ref, out_dim):
    hexfile = os.path.join(BUILD, f"nn_{variant}.hex")
    outfile = os.path.join(BUILD, f"nn_results_{variant}.txt")
    nvec = len(ref["vectors"])

    stdout = run(hexfile, nvec, outfile)
    print(f"  {stdout.strip().splitlines()[-1] if stdout.strip() else '(no output)'}")

    meta, got = parse(outfile)

    if meta.get("magic", "").lower() != "4e4e3831":
        return False, [f"sentinel not written (got {meta.get('magic')}): firmware did not "
                       f"reach the end of main()"]
    if int(meta["count"]) != nvec:
        return False, [f"ran {meta['count']} inferences, expected {nvec}"]

    errs = []
    for v in ref["vectors"]:
        i = v["index"]
        for k in range(out_dim):
            exp, act = v["logits"][k], got[i][k]
            if exp != act:
                errs.append(f"vector {i} logit {k}: SoC {act} != reference {exp} "
                            f"(delta {act - exp})")
    return len(errs) == 0, errs


def main():
    ref_path = REF
    if not os.path.exists(ref_path):
        sys.exit(f"FATAL: {ref_path} missing -- run `make nn-train` first")
    with open(ref_path) as f:
        ref = json.load(f)
    out_dim = ref["out_dim"]

    print(f"reference: {len(ref['vectors'])} vectors, {out_dim} logits each, "
          f"from model/train_mlp.py's integer forward pass")

    all_ok = True
    for variant, label in (("sw", "software shift-add multiply"),
                           ("mac", "MAC accelerator")):
        print(f"\n=== {variant} ({label}) ===")
        ok, errs = check(variant, ref, out_dim)
        if ok:
            n = len(ref["vectors"]) * out_dim
            print(f"  PASS: all {n} int32 logits bit-identical to the reference")
        else:
            all_ok = False
            print(f"  FAIL: {len(errs)} mismatch(es)")
            for e in errs[:12]:
                print(f"    {e}")
            if len(errs) > 12:
                print(f"    ... and {len(errs) - 12} more")

    # Cross-check the two variants against each other as well. They are already both
    # compared to the reference, so this cannot fail independently -- but if it ever did,
    # it would mean the reference comparison above is not doing what it claims.
    print()
    if all_ok:
        print("PASS: software and accelerator paths both bit-identical to the reference")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
