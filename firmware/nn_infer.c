// INT8 MLP inference on an RV32I core with no hardware multiply.
//
// The core implements RV32I base only: there is no M extension, so there is no MUL
// instruction. Every one of the 6,592 multiply-accumulates in this network therefore costs
// a software routine rather than one instruction, and that is the cost this file exists to
// expose and measure before phase 2 moves it into hardware.
//
// Nothing here calls into libgcc. The build links with -nostdlib and without -lgcc
// specifically so that an accidental `*`, `/` or `%` on an int becomes an undefined
// reference to __mulsi3 / __divsi3 at link time instead of quietly linking in a multiply
// routine nobody measured. If this file links, it contains no hidden multiply.
//
// Build variants (all from this one source, the way rv32i_core.v keeps its gated and
// ungated register file behind one `ifdef):
//
//   default            software shift-add multiply
//   -DUSE_MAC_ACCEL    dot products issued to the memory-mapped MAC accelerator
//   -DMUL_STUB         multiply replaced by a single add; see the comment on mul_sa()

#include <stdint.h>
#include "soc.h"
#include "weights.h"
#include "vectors.h"

// Hidden activations live in .bss rather than on the stack so they have a stable address
// in main memory. The MAC accelerator fetches its operands from memory itself, exactly as
// the correlator fetches its samples, so its input vector has to be somewhere it can
// address -- not in a register or a stack slot the CPU happens to be holding.
static int8_t hid[NN_HID];

// ---------------------------------------------------------------- software multiply

// Shift-and-add multiply. `a` is an activation and is *always non-negative*: layer 1's
// activations are quantised pixels (0..127) and layer 2's come out of a ReLU followed by a
// clamp to 0..127. That is worth stating because it removes the sign handling a general
// multiply needs -- there is no negative-multiplier case to get wrong, so the routine
// iterates over the multiplier's bits directly with no magnitude/sign fixup.
//
// Cost is data-dependent: the loop exits as soon as the remaining multiplier bits are
// zero, so a small activation is cheaper than a large one and a zero activation costs
// almost nothing. Measured cycle counts below are therefore for the real test vectors,
// not a synthetic worst case.
// Not built at all in the accelerator variant, where no software multiply is reachable.
#ifndef USE_MAC_ACCEL
#ifdef MUL_STUB
// Profiling variant. Replaces the shift-add loop with a single add, keeping the loop
// structure, memory traffic and data dependencies of the caller intact so the compiler
// cannot delete the dot product. The difference between this build and the default one is
// "the cost of the shift-add loops, minus one add per MAC" -- which is what gets reported,
// rather than being rounded off to "the cost of multiply".
static inline int32_t mul_sa(int32_t w, uint32_t a) { return w + (int32_t)a; }
#else
static int32_t mul_sa(int32_t w, uint32_t a)
{
    int32_t acc = 0;
    while (a) {
        if (a & 1u) acc += w;
        w <<= 1;
        a >>= 1u;
    }
    return acc;
}
#endif
#endif

// ---------------------------------------------------------------- dot product

#ifdef USE_MAC_ACCEL
// Hand the whole dot product to the accelerator: four register writes, a start pulse, a
// poll, and one read. The CPU never touches the individual terms, which is the same
// division of labour the GNSS correlator uses -- the accelerator walks memory itself
// rather than being fed sample by sample.
static int32_t dot(const int8_t *a, const int8_t *b, uint32_t n)
{
    MMIO32(MAC_LEN)    = n;
    MMIO32(MAC_ADDR_A) = (uint32_t)a;
    MMIO32(MAC_ADDR_B) = (uint32_t)b;
    MMIO32(MAC_CTRL)   = 1u;                       // start
    while (!(MMIO32(MAC_CTRL) & 2u)) { }           // poll done
    return (int32_t)MMIO32(MAC_ACC);
}
#else
static int32_t dot(const int8_t *a, const int8_t *b, uint32_t n)
{
    int32_t acc = 0;
    for (uint32_t i = 0; i < n; i++)
        acc += mul_sa(b[i], (uint32_t)(uint8_t)a[i]);
    return acc;
}
#endif

// ---------------------------------------------------------------- the network

// acc1[j] = sum_i( x[i] * w1[j][i] ) + b1[j]          int32
// hid[j]  = min( relu(acc1[j]) >> NN_SHIFT1, 127 )    int8, 0..127
// acc2[k] = sum_j( hid[j] * w2[k][j] ) + b2[k]        int32  <- reported logits
//
// ReLU is applied before the shift so the shifted operand is never negative. Right-
// shifting a negative value is arithmetic in C and in numpy, but making the host model and
// the target agree on rounding by relying on that is a worse guarantee than not having
// negative values to shift in the first place.
static void infer(const int8_t *x, int32_t *logits)
{
    const int8_t *w = nn_w1;
    for (uint32_t j = 0; j < NN_HID; j++) {
        int32_t acc = nn_b1[j] + dot(x, w, NN_IN);
        w += NN_IN;
        int32_t v = (acc < 0) ? 0 : (acc >> NN_SHIFT1);
        hid[j] = (int8_t)((v > 127) ? 127 : v);
    }

    const int8_t *w2 = nn_w2;
    for (uint32_t k = 0; k < NN_OUT; k++) {
        logits[k] = nn_b2[k] + dot(hid, w2, NN_HID);
        w2 += NN_HID;
    }
}

int main(void)
{
    // How many vectors to run is supplied by the testbench in memory rather than compiled
    // in, so one firmware image can be measured at two different vector counts and the
    // fixed startup cost separated from the per-inference cost by subtraction.
    uint32_t nvec = MMIO32(NN_NVEC_ADDR);
    if (nvec == 0u || nvec > NN_NVEC) nvec = NN_NVEC;

    volatile uint32_t *out = (volatile uint32_t *)NN_RESULT_LOGIT;

    for (uint32_t v = 0; v < nvec; v++) {
        int32_t logits[NN_OUT];
        infer(nn_vectors[v], logits);
        for (uint32_t k = 0; k < NN_OUT; k++)
            *out++ = (uint32_t)logits[k];
    }

    MMIO32(NN_RESULT_COUNT) = nvec;
    MMIO32(NN_RESULT_MAGIC) = NN_MAGIC;   // written last: proves the loop ran to completion
    return 0;
}
