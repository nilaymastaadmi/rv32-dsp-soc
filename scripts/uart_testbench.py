#!/usr/bin/env python3
"""Host-side test automation for the UART peripheral.

Structured the way bench test automation actually works, rather than as a wrapper that
prints whatever the simulation says. The host owns the whole loop:

  1. generate a test vector set (directed edge cases first, then seeded random)
  2. write it into the device's memory image
  3. launch the device (here a simulator; on a bench this would be a serial port or a
     JTAG/SWD probe against real silicon)
  4. read the results back
  5. score them against expectations the host computed independently
  6. emit a machine-readable report and a non-zero exit code on failure, so it drops
     straight into CI

Point 5 is the part that matters: the pass/fail decision lives here, not in the firmware
or the testbench. Firmware reports what it observed; the host decides whether that was
correct. A bug that corrupts both the transmit and compare paths in the same direction
would otherwise pass silently.
"""

import argparse
import json
import pathlib
import random
import subprocess
import sys

# Bytes chosen to break specific plausible implementations, not for coverage's sake:
# all-zeros and all-ones catch a stuck line, the alternating patterns catch bit-order
# and sampling-phase errors, and the single-bit values catch an off-by-one in the shift
# register's start or end.
DIRECTED = [0x00, 0xFF, 0xAA, 0x55, 0x01, 0x80, 0x0F, 0xF0, 0x7F, 0xFE]


def build_vectors(n_random, seed):
    rng = random.Random(seed)
    vectors = list(DIRECTED)
    vectors += [rng.randrange(256) for _ in range(n_random)]
    return vectors


def write_vector_image(path, vectors):
    """Word 0 is the count, then one byte per word, matching what the firmware expects."""
    with open(path, "w") as f:
        f.write(f"{len(vectors):08x}\n")
        for v in vectors:
            f.write(f"{v:08x}\n")


def parse_results(path):
    out = {"rx": {}}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "rx" and len(parts) >= 3:
                out["rx"][int(parts[1])] = int(parts[2])
            elif len(parts) >= 2:
                out[parts[0]] = int(parts[1])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", default="build/sim_soc_uart", help="compiled simulation binary")
    ap.add_argument("--vvp", default=None, help="vvp interpreter path (for Icarus builds)")
    ap.add_argument("--hex", default="build/uart_test.hex", help="firmware image")
    ap.add_argument("--vectors", default="build/uart_vectors.hex")
    ap.add_argument("--results", default="build/uart_results.txt")
    ap.add_argument("--report", default="build/uart_report.json")
    ap.add_argument("-n", "--random", type=int, default=200, help="random vectors to add")
    ap.add_argument("--seed", type=int, default=1, help="seed, so a failure is reproducible")
    args = ap.parse_args()

    vectors = build_vectors(args.random, args.seed)
    write_vector_image(args.vectors, vectors)
    print(f"[host] generated {len(vectors)} vectors "
          f"({len(DIRECTED)} directed + {args.random} random, seed {args.seed})")

    cmd = ([args.vvp, args.sim] if args.vvp else [args.sim]) + [
        f"+hex={args.hex}",
        f"+vectors={args.vectors}",
        f"+out={args.results}",
    ]
    print(f"[host] launching device: {' '.join(cmd)}")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if line.strip() and not line.startswith("WARNING"):
            print(f"[dut]  {line}")
    if proc.returncode != 0:
        print(f"[host] FAIL: device exited {proc.returncode}", file=sys.stderr)
        print(proc.stderr[:2000], file=sys.stderr)
        return 2

    if not pathlib.Path(args.results).exists():
        print("[host] FAIL: device produced no results file", file=sys.stderr)
        return 2

    res = parse_results(args.results)

    # Independent scoring. The firmware's own pass/fail tally is read too, but only to
    # cross-check it against the host's verdict -- if they ever disagree, that disagreement
    # is itself a bug worth reporting.
    mismatches = []
    for i, expected in enumerate(vectors):
        got = res["rx"].get(i)
        if got is None:
            mismatches.append({"index": i, "expected": expected, "got": None,
                               "note": "no byte recorded"})
        elif got != expected:
            mismatches.append({"index": i, "expected": expected, "got": got})

    host_pass = len(vectors) - len(mismatches)
    fw_pass = res.get("pass", -1)
    fw_fail = res.get("fail", -1)
    agree = (fw_pass == host_pass) and (fw_fail == len(mismatches))

    report = {
        "vectors": len(vectors),
        "seed": args.seed,
        "host_pass": host_pass,
        "host_fail": len(mismatches),
        "firmware_pass": fw_pass,
        "firmware_fail": fw_fail,
        "host_firmware_agree": agree,
        "cycles": res.get("cycles"),
        "mismatches": mismatches[:20],
    }
    with open(args.report, "w") as f:
        json.dump(report, f, indent=2)

    print(f"[host] scored independently: {host_pass}/{len(vectors)} correct")
    print(f"[host] firmware self-report : {fw_pass} pass / {fw_fail} fail")
    print(f"[host] host and firmware agree: {'yes' if agree else 'NO -- investigate'}")
    if res.get("cycles"):
        per_byte = res["cycles"] / max(1, len(vectors))
        print(f"[host] {res['cycles']} cycles total, {per_byte:.0f} cycles/byte")

    if mismatches:
        print(f"[host] FAIL: {len(mismatches)} mismatch(es); first few:")
        for m in mismatches[:5]:
            got = m["got"]
            got_str = "no byte" if got is None else f"0x{got:02x}"
            print(f"        idx {m['index']}: expected 0x{m['expected']:02x}, got {got_str}")
        return 1
    if not agree:
        print("[host] FAIL: firmware tally disagrees with host scoring")
        return 1

    print(f"[host] PASS: all {len(vectors)} vectors round-tripped correctly")
    print(f"[host] report written to {args.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
