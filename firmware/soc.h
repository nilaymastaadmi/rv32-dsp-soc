// Memory map shared between the firmware and the testbench that scores it.
//
// The SoC's memory is a flat 65536-word (256 KB) array based at zero, with peripherals
// decoded well above it at 0x1000_0000, so everything below 0x40000 is plain RAM and
// there is no MMIO hazard in choosing these addresses. The existing tests already claim
// 0x3000 (results), 0x4000 (GNSS samples) and 0x8000 (code table); the regions below sit
// clear of all three so an NN run and an acquisition run can never tread on each other.

#ifndef SOC_H
#define SOC_H
#include <stdint.h>

// ---- RAM layout ----
// .text/.rodata/.data/.bss grow up from 0. Weights are ~6.7 KB and the baked-in test
// vectors ~3.9 KB, so the image lands well under 32 KB; the stack top at 0xE000 leaves a
// wide margin rather than a computed-tight one.
#define NN_STACK_TOP    0x0000E000u

// Firmware writes its results here for the testbench to read back out of memory.
#define NN_RESULT_BASE  0x00010000u
#define NN_RESULT_COUNT (NN_RESULT_BASE + 0x0u)   // vectors actually processed
#define NN_RESULT_MAGIC (NN_RESULT_BASE + 0x4u)   // sentinel, proves the run reached the end
#define NN_RESULT_LOGIT (NN_RESULT_BASE + 0x8u)   // NN_OUT int32 logits per vector
#define NN_MAGIC        0x4E4E3831u               // "NN81"

// The testbench pokes the number of vectors to run here before releasing reset, so cycle
// cost can be measured at two different vector counts from one firmware image. Measuring
// N=1 and N=K and taking the difference separates fixed startup cost from the per-
// inference steady state, instead of dividing a total by K and quietly folding startup in.
#define NN_NVEC_ADDR    0x00020000u

// ---- MAC accelerator (added in phase 2; see rtl/mac_bus.v) ----
#define MAC_BASE        0x10002000u
#define MAC_CTRL        (MAC_BASE + 0x00u)  // W: bit0=start   R: bit0=busy, bit1=done
#define MAC_LEN         (MAC_BASE + 0x04u)  // RW: number of terms
#define MAC_ADDR_A      (MAC_BASE + 0x08u)  // RW: byte address of the int8 activation vector
#define MAC_ADDR_B      (MAC_BASE + 0x0Cu)  // RW: byte address of the int8 weight vector
#define MAC_ACC         (MAC_BASE + 0x10u)  // R : int32 dot product

#define MMIO32(a) (*(volatile uint32_t *)(a))

#endif
