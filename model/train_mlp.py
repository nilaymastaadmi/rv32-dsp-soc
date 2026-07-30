#!/usr/bin/env python3
"""Train a small MLP on MNIST, quantise it to INT8, and emit it as C for the SoC.

The quantisation scheme here is deliberately chosen so the whole forward pass is
integer-only *and* needs no multiply outside the dot products themselves:

    acc1[j]  = sum_i( x_q[i] * w1_q[j][i] ) + b1[j]        int32
    h_q[j]   = min( relu(acc1[j]) >> SHIFT1, 127 )         int8, 0..127
    acc2[k]  = sum_j( h_q[j] * w2_q[k][j] ) + b2[k]        int32
    logits   = acc2[k]                                     int32, the reported output

Two things about that are worth stating plainly rather than glossing over.

First, requantisation between the layers is a *power-of-two right shift*, not the usual
multiply-by-fixed-point-scale-then-shift. The usual form needs a 64-bit intermediate
(int32 accumulator times an int32 multiplier), and on a core with no hardware multiply at
all a 64-bit multiply is brutally expensive -- it would swamp the very cost this project
is trying to measure. A shift restricts the activation scale to powers of two, which
costs accuracy. That cost is measured and reported rather than hidden; see the accuracy
table this script prints.

Second, ReLU is applied *before* the shift, so the shifted value is always non-negative.
That matters because right-shifting a negative integer is arithmetic (round-toward
negative-infinity) in both C and numpy but is a well-known place for a host model and a
target to disagree on rounding. Clamping to non-negative first removes the question
entirely instead of relying on both sides happening to agree.

Outputs:
    firmware/weights.h      quantised parameters as C const arrays
    firmware/vectors.h      test inputs, baked into the firmware image
    build/nn_vectors.json   the same inputs plus the int32 logits this model produces for
                            them, which is what the SoC is checked bit-for-bit against
"""
import argparse
import gzip
import json
import os
import struct
import urllib.request

import numpy as np

SEED = 20260730
IN_DIM = 196          # 14x14, MNIST downscaled by 2x2 average pooling
HID_DIM = 32          # overridable with --hid, for the size sweep in scripts/nn_sweep.py
OUT_DIM = 10
EPOCHS = 20
BATCH = 128
LR = 0.05
N_VECTORS = 20        # how many test images to hand to the SoC for the bit-exact check

MIRROR = "https://storage.googleapis.com/cvdf-datasets/mnist/"
FILES = {
    "train_x": "train-images-idx3-ubyte.gz",
    "train_y": "train-labels-idx1-ubyte.gz",
    "test_x": "t10k-images-idx3-ubyte.gz",
    "test_y": "t10k-labels-idx1-ubyte.gz",
}


def data_dir():
    # MNIST is ~11 MB and is *not* committed: it is an input, not a result. Cache it
    # outside the repo so a clean checkout stays clean.
    d = os.environ.get("MNIST_DIR", os.path.expanduser("~/.cache/mnist"))
    os.makedirs(d, exist_ok=True)
    return d


def fetch(name):
    path = os.path.join(data_dir(), FILES[name])
    if not os.path.exists(path):
        url = MIRROR + FILES[name]
        print(f"  downloading {FILES[name]} ...", flush=True)
        urllib.request.urlretrieve(url, path)
    return path


def read_idx(path):
    with gzip.open(path, "rb") as f:
        magic, ndim = struct.unpack(">HBB", f.read(4))[1:]
        dims = struct.unpack(f">{ndim}I", f.read(4 * ndim))
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(dims)


def load():
    print("MNIST:")
    xtr = read_idx(fetch("train_x"))
    ytr = read_idx(fetch("train_y"))
    xte = read_idx(fetch("test_x"))
    yte = read_idx(fetch("test_y"))
    return xtr, ytr, xte, yte


def downscale(imgs):
    """28x28 -> 14x14 by 2x2 average pooling, staying in uint8 range."""
    n = imgs.shape[0]
    x = imgs.reshape(n, 14, 2, 14, 2).mean(axis=(2, 4))
    return x.reshape(n, IN_DIM)


def quantise_input(x_u8):
    """uint8 pixel 0..255 -> int8 0..127.

    The float model is trained on x/255 in [0,1], so the matching integer input is
    round(x/255 * 127). Kept non-negative, which is what the real data is anyway.
    """
    return np.rint(x_u8.astype(np.float64) / 255.0 * 127.0).astype(np.int32)


# ---------------------------------------------------------------- float training

def init_params(rng):
    # He initialisation for the ReLU layer, Xavier for the linear output.
    w1 = rng.normal(0, np.sqrt(2.0 / IN_DIM), (HID_DIM, IN_DIM))
    b1 = np.zeros(HID_DIM)
    w2 = rng.normal(0, np.sqrt(1.0 / HID_DIM), (OUT_DIM, HID_DIM))
    b2 = np.zeros(OUT_DIM)
    return w1, b1, w2, b2


def forward_float(x, p):
    w1, b1, w2, b2 = p
    a1 = x @ w1.T + b1
    h = np.maximum(a1, 0.0)
    return a1, h, h @ w2.T + b2


def train(xtr, ytr, xte, yte, quiet=False):
    rng = np.random.default_rng(SEED)
    p = init_params(rng)
    w1, b1, w2, b2 = p
    n = xtr.shape[0]

    if not quiet:
        print(f"\ntraining float32 {IN_DIM}-{HID_DIM}-{OUT_DIM}, "
              f"{EPOCHS} epochs, batch {BATCH}, lr {LR}")
    for ep in range(EPOCHS):
        order = rng.permutation(n)
        for s in range(0, n, BATCH):
            idx = order[s:s + BATCH]
            xb, yb = xtr[idx], ytr[idx]
            m = xb.shape[0]

            a1, h, logits = forward_float(xb, (w1, b1, w2, b2))

            # softmax cross-entropy gradient
            z = logits - logits.max(axis=1, keepdims=True)
            e = np.exp(z)
            sm = e / e.sum(axis=1, keepdims=True)
            d_logits = sm
            d_logits[np.arange(m), yb] -= 1.0
            d_logits /= m

            g_w2 = d_logits.T @ h
            g_b2 = d_logits.sum(axis=0)
            d_h = d_logits @ w2
            d_a1 = d_h * (a1 > 0)
            g_w1 = d_a1.T @ xb
            g_b1 = d_a1.sum(axis=0)

            w2 -= LR * g_w2
            b2 -= LR * g_b2
            w1 -= LR * g_w1
            b1 -= LR * g_b1

        if not quiet and (ep % 5 == 4 or ep == EPOCHS - 1):
            acc = (forward_float(xte, (w1, b1, w2, b2))[2].argmax(1) == yte).mean()
            print(f"  epoch {ep + 1:2d}  test acc {acc * 100:.2f}%")

    return w1, b1, w2, b2


# ---------------------------------------------------------------- quantisation

def sym_scale(t):
    """Per-tensor symmetric scale mapping max|t| onto 127."""
    m = float(np.abs(t).max())
    return (m / 127.0) if m > 0 else 1.0


def quantise(p, xq_cal):
    """Post-training quantisation. Returns int arrays plus the chosen shift."""
    w1, b1, w2, b2 = p

    s_x = 1.0 / 127.0                       # input scale: x_q = x_real * 127
    s_w1 = sym_scale(w1)
    s_w2 = sym_scale(w2)

    w1_q = np.clip(np.rint(w1 / s_w1), -127, 127).astype(np.int32)
    w2_q = np.clip(np.rint(w2 / s_w2), -127, 127).astype(np.int32)

    # Bias lives in accumulator units, i.e. the product of the two input scales.
    b1_q = np.rint(b1 / (s_x * s_w1)).astype(np.int64)

    # Pick SHIFT1 by calibration: run the real int32 layer-1 accumulator over calibration
    # data and choose the shift that puts the 99.9th percentile near the top of int8.
    # Calibrating on a percentile rather than the absolute max keeps a handful of outlier
    # activations from compressing the scale for everything else.
    acc1 = xq_cal @ w1_q.T + b1_q
    hi = float(np.percentile(np.maximum(acc1, 0), 99.9))
    shift1 = 0
    while (hi / (2 ** shift1)) > 127.0:
        shift1 += 1

    # Hidden activation scale that shift actually realises, needed to put the layer-2
    # bias in layer-2 accumulator units.
    s_h = (s_x * s_w1) * (2 ** shift1)
    b2_q = np.rint(b2 / (s_h * s_w2)).astype(np.int64)

    return dict(w1=w1_q, b1=b1_q, w2=w2_q, b2=b2_q, shift1=shift1,
                s_x=s_x, s_w1=s_w1, s_w2=s_w2, s_h=s_h)


def forward_int(xq, q):
    """The exact integer forward pass the C firmware must reproduce bit for bit.

    Deliberately written with explicit int64 accumulation in numpy and then checked to
    fit in int32, rather than relying on numpy's int32 wrapping to match C's. If a real
    overflow ever happened, silently wrapping in both places by luck is not a property
    worth depending on -- so it is asserted instead.
    """
    acc1 = xq.astype(np.int64) @ q["w1"].T.astype(np.int64) + q["b1"]
    assert np.abs(acc1).max() < 2 ** 31, "layer-1 accumulator overflows int32"

    h = np.minimum(np.maximum(acc1, 0) >> q["shift1"], 127)

    acc2 = h @ q["w2"].T.astype(np.int64) + q["b2"]
    assert np.abs(acc2).max() < 2 ** 31, "layer-2 accumulator overflows int32"
    return acc2.astype(np.int64)


# ---------------------------------------------------------------- emit

def emit_weights_h(q, path):
    def arr(name, a, ctype):
        flat = a.reshape(-1)
        body = ",".join(str(int(v)) for v in flat)
        wrapped, line = [], ""
        for tok in body.split(","):
            if len(line) + len(tok) + 1 > 92:
                wrapped.append(line)
                line = ""
            line += (tok + ",")
        wrapped.append(line.rstrip(","))
        joined = "\n    ".join(wrapped)
        return f"static const {ctype} {name}[{flat.size}] = {{\n    {joined}\n}};\n"

    n_bytes = q["w1"].size + q["w2"].size + 4 * (q["b1"].size + q["b2"].size)
    with open(path, "w") as f:
        f.write("// Generated by model/train_mlp.py -- do not edit by hand.\n")
        f.write("//\n")
        f.write(f"// {IN_DIM}-{HID_DIM}-{OUT_DIM} MLP, INT8 weights, INT32 biases and\n")
        f.write("// accumulators, power-of-two requantisation between layers.\n")
        f.write(f"// Parameter memory: {n_bytes} bytes "
                f"({q['w1'].size + q['w2'].size} int8 weights + "
                f"{q['b1'].size + q['b2'].size} int32 biases).\n")
        f.write("#ifndef WEIGHTS_H\n#define WEIGHTS_H\n#include <stdint.h>\n\n")
        f.write(f"#define NN_IN   {IN_DIM}\n")
        f.write(f"#define NN_HID  {HID_DIM}\n")
        f.write(f"#define NN_OUT  {OUT_DIM}\n")
        f.write(f"#define NN_SHIFT1 {q['shift1']}\n\n")
        f.write(arr("nn_w1", q["w1"], "int8_t"))
        f.write("\n")
        f.write(arr("nn_b1", q["b1"], "int32_t"))
        f.write("\n")
        f.write(arr("nn_w2", q["w2"], "int8_t"))
        f.write("\n")
        f.write(arr("nn_b2", q["b2"], "int32_t"))
        f.write("\n#endif\n")
    return n_bytes


def emit_vectors_h(xq, labels, path):
    """Bake the test inputs into the firmware image.

    They could equally be preloaded into memory by the testbench the way the UART test
    preloads its byte vectors, but baking them in keeps the firmware self-contained: a
    fresh clone with a checked-in .hex can run the regression with no side-channel input
    file to go missing.
    """
    n = xq.shape[0]
    with open(path, "w") as f:
        f.write("// Generated by model/train_mlp.py -- do not edit by hand.\n")
        f.write(f"// {n} quantised MNIST test inputs, int8 0..127, {xq.shape[1]} each.\n")
        f.write("#ifndef VECTORS_H\n#define VECTORS_H\n#include <stdint.h>\n\n")
        f.write(f"#define NN_NVEC {n}\n\n")
        f.write(f"static const int8_t nn_vectors[{n}][{xq.shape[1]}] = {{\n")
        for r in range(n):
            row = ",".join(str(int(v)) for v in xq[r])
            f.write(f"  {{{row}}},\n")
        f.write("};\n\n")
        f.write(f"static const uint8_t nn_labels[{n}] = {{")
        f.write(",".join(str(int(v)) for v in labels))
        f.write("};\n\n#endif\n")


def main():
    global HID_DIM
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("weights_h", nargs="?", default="firmware/weights.h")
    ap.add_argument("vectors_json", nargs="?", default="firmware/prebuilt/nn_vectors.json")
    ap.add_argument("vectors_h", nargs="?", default="firmware/vectors.h")
    ap.add_argument("--hid", type=int, default=HID_DIM,
                    help="hidden layer width (default %(default)s)")
    ap.add_argument("--quiet", action="store_true", help="suppress per-epoch output")
    args = ap.parse_args()

    HID_DIM = args.hid
    out_h, out_vec, out_vh = args.weights_h, args.vectors_json, args.vectors_h

    xtr_raw, ytr, xte_raw, yte = load()
    xtr_u8 = downscale(xtr_raw)
    xte_u8 = downscale(xte_raw)

    xtr_f = xtr_u8 / 255.0
    xte_f = xte_u8 / 255.0

    p = train(xtr_f, ytr, xte_f, yte, quiet=args.quiet)

    acc_f = (forward_float(xte_f, p)[2].argmax(1) == yte).mean()

    xtr_q = quantise_input(xtr_u8)
    xte_q = quantise_input(xte_u8)

    # Calibrate the requantisation shift on training data only, never on the test set.
    q = quantise(p, xtr_q[:5000])

    logits_i = forward_int(xte_q, q)
    acc_q = (logits_i.argmax(1) == yte).mean()

    n_bytes = emit_weights_h(q, out_h)

    os.makedirs(os.path.dirname(out_vec) or ".", exist_ok=True)
    vec_idx = list(range(N_VECTORS))
    emit_vectors_h(xte_q[:N_VECTORS], yte[:N_VECTORS], out_vh)
    with open(out_vec, "w") as f:
        json.dump({
            "in_dim": IN_DIM, "hid_dim": HID_DIM, "out_dim": OUT_DIM,
            "shift1": int(q["shift1"]),
            # Layer-1 parameters are included so scripts/nn_measure.py can recompute the
            # hidden activations and predict the software multiply's loop count from the
            # real data, rather than keeping a second copy of the forward pass in sync.
            "w1": [int(v) for v in q["w1"].reshape(-1)],
            "b1": [int(v) for v in q["b1"].reshape(-1)],
            "vectors": [
                {"index": int(i),
                 "label": int(yte[i]),
                 "input": [int(v) for v in xte_q[i]],
                 "logits": [int(v) for v in logits_i[i]],
                 "argmax": int(logits_i[i].argmax())}
                for i in vec_idx
            ],
        }, f)

    macs = IN_DIM * HID_DIM + HID_DIM * OUT_DIM
    if args.quiet:
        # One machine-readable line for the sweep driver.
        print(f"SUMMARY hid={HID_DIM} acc_f={acc_f * 100:.2f} acc_q={acc_q * 100:.2f} "
              f"shift={q['shift1']} bytes={n_bytes} macs={macs}")
    else:
        print("\n=== accuracy ===")
        print(f"  float32          {acc_f * 100:.2f}%")
        print(f"  int8 quantised   {acc_q * 100:.2f}%")
        print(f"  drop             {(acc_f - acc_q) * 100:+.2f} pp")
        print(f"\n  requantise shift : >> {q['shift1']}")
        print(f"  parameter memory : {n_bytes} bytes")
        print(f"  MACs / inference : {macs}")
        print(f"\nwrote {out_h}")
        print(f"wrote {out_vh}")
        print(f"wrote {out_vec}  ({N_VECTORS} vectors)")


if __name__ == "__main__":
    main()
