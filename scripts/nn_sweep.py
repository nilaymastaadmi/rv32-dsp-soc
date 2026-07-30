#!/usr/bin/env python3
"""Accuracy / latency / memory trade-off across hidden-layer widths.

Retrains, requantises, rebuilds the firmware and re-measures cycles at several hidden
widths, so the three costs can be read against each other rather than one at a time.

Two things about the method, since both affect how the numbers should be read.

Cycles are measured at two vector counts (1 and N_MEASURE) and the per-inference figure is
the difference divided by N_MEASURE-1, exactly as scripts/nn_measure.py does it, so fixed
startup cost is subtracted rather than divided in. N_MEASURE is small here (5, versus 20 for
the headline result) purely because the software path costs ~140k cycles per inference and
iverilog is not fast; the arithmetic is identical, the sample is just narrower.

This script REPLACES firmware/weights.h and firmware/vectors.h while it runs, because the
model dimensions are compile-time constants. It backs up the committed versions first and
restores them in a finally block, so an interrupted run does not leave the canonical 32-unit
model overwritten by a sweep point. The restore is verified with git before exiting, and the
sweep's firmware build products are deleted so nothing downstream can pick up a stale image
built for a different model size -- see the comment in that finally block, which records a real
failure caused by restoring with mtimes intact.
"""
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(REPO, "build")
SIM = os.path.join(BUILD, "nn_sim")

HIDDEN = [16, 32, 64]
N_MEASURE = 5

# Files the sweep overwrites and must put back.
MANAGED = [
    "firmware/weights.h",
    "firmware/vectors.h",
    "firmware/prebuilt/nn_vectors.json",
]

PY = os.path.join(os.path.expanduser("~"), ".venvs", "nn", "bin", "python")
if not os.path.exists(PY):
    PY = sys.executable


def sh(cmd, **kw):
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, **kw)


def run_sim(variant, nvec):
    out = os.path.join(BUILD, f"nn_sweep_{variant}_{nvec}.txt")
    r = sh([SIM, f"+hex={os.path.join(BUILD, f'nn_{variant}.hex')}",
            f"+nvec={nvec}", f"+out={out}"])
    m = re.search(r"(\d+) inference\(s\), (\d+) cycles", r.stdout)
    if not m:
        print(r.stdout, r.stderr, file=sys.stderr)
        sys.exit(f"FATAL: sim failed for {variant} nvec={nvec}")
    count, cycles = int(m.group(1)), int(m.group(2))
    if count != nvec:
        sys.exit(f"FATAL: asked for {nvec} inferences, ran {count}")
    return cycles


def measure(variant):
    c1 = run_sim(variant, 1)
    cn = run_sim(variant, N_MEASURE)
    return (cn - c1) / (N_MEASURE - 1)


def main():
    backup = os.path.join(BUILD, "sweep_backup")
    os.makedirs(backup, exist_ok=True)
    for f in MANAGED:
        src = os.path.join(REPO, f)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(backup, os.path.basename(f)))

    rows = []
    try:
        for hid in HIDDEN:
            print(f"=== hidden width {hid} ===", flush=True)

            r = sh([PY, "model/train_mlp.py", "--hid", str(hid), "--quiet"])
            m = re.search(r"SUMMARY hid=(\d+) acc_f=([\d.]+) acc_q=([\d.]+) "
                          r"shift=(\d+) bytes=(\d+) macs=(\d+)", r.stdout)
            if not m:
                print(r.stdout, r.stderr, file=sys.stderr)
                sys.exit("FATAL: training did not emit a SUMMARY line")
            _, acc_f, acc_q, shift, nbytes, macs = m.groups()
            print(f"  float32 {acc_f}%  int8 {acc_q}%  "
                  f"shift>>{shift}  {nbytes} B  {macs} MACs", flush=True)

            # Rebuild both firmware variants against the new headers.
            b = sh(["make", "-s", "build/nn_sw.hex", "build/nn_mac.hex"])
            if b.returncode != 0:
                print(b.stdout, b.stderr, file=sys.stderr)
                sys.exit(f"FATAL: firmware build failed at hid={hid}")

            # Bit-exactness still has to hold at every sweep point. A trade-off table built
            # on top of an unverified forward pass would be measuring the wrong thing.
            chk = sh(["python3", "scripts/nn_check.py"])
            ok = "PASS: software and accelerator paths" in chk.stdout
            print(f"  bit-exact: {'PASS' if ok else 'FAIL'}", flush=True)
            if not ok:
                print(chk.stdout[-1500:], file=sys.stderr)
                sys.exit(f"FATAL: bit-exactness failed at hid={hid}")

            sw = measure("sw")
            mac = measure("mac")
            print(f"  sw {sw:,.0f} cyc/inf   mac {mac:,.0f} cyc/inf   "
                  f"speedup {sw / mac:.2f}x", flush=True)

            rows.append(dict(hid=hid, acc_f=float(acc_f), acc_q=float(acc_q),
                             shift=int(shift), bytes=int(nbytes), macs=int(macs),
                             sw=sw, mac=mac, speedup=sw / mac))
    finally:
        for f in MANAGED:
            src = os.path.join(backup, os.path.basename(f))
            if os.path.exists(src):
                dst = os.path.join(REPO, f)
                # copyfile, NOT copy2, and then stamp the mtime to now.
                #
                # copy2 preserves the source's mtime, and that is a genuinely nasty trap here:
                # restoring the committed header gave it an mtime OLDER than the firmware built
                # during the last sweep point, so make saw a build product newer than its own
                # source and skipped the rebuild. The repo was left with correct sources and a
                # stale build/, and `make nn-check` then compared 64-unit firmware against a
                # 32-unit reference and failed all 200 logits. The source tree looked clean the
                # whole time, which is what made it worth writing down.
                shutil.copyfile(src, dst)
                os.utime(dst, None)

        # Belt and braces: drop the firmware build products outright, so a rebuild is forced by
        # absence rather than by a timestamp comparison that could go wrong again.
        for name in os.listdir(BUILD) if os.path.isdir(BUILD) else []:
            if name.startswith("nn_") and name.rsplit(".", 1)[-1] in ("elf", "hex", "bin"):
                os.remove(os.path.join(BUILD, name))

        # Verify the restore rather than trusting it: this script's whole risk is leaving the
        # committed model overwritten.
        st = subprocess.run(["git", "status", "--porcelain"] + MANAGED,
                            cwd=REPO, capture_output=True, text=True)
        if st.stdout.strip():
            print("\nWARNING: managed files still differ from the committed versions after "
                  "restore:\n" + st.stdout, file=sys.stderr)
        else:
            print("\nrestored firmware/weights.h, firmware/vectors.h and the reference vectors "
                  "to their committed state (git reports them clean), and removed the sweep's "
                  "firmware build products so the next build cannot reuse them")

    print("\n| hidden | params (B) | MACs | float32 | INT8 | drop | sw cyc/inf | "
          "mac cyc/inf | speedup |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        print(f"| {r['hid']} | {r['bytes']:,} | {r['macs']:,} | {r['acc_f']:.2f}% | "
              f"{r['acc_q']:.2f}% | {r['acc_q'] - r['acc_f']:+.2f} pp | "
              f"{r['sw']:,.0f} | {r['mac']:,.0f} | {r['speedup']:.2f}x |")

    with open(os.path.join(BUILD, "nn_sweep.json"), "w") as f:
        json.dump(dict(n_measure=N_MEASURE, rows=rows), f, indent=1)
    print(f"\nwrote build/nn_sweep.json")


if __name__ == "__main__":
    main()
