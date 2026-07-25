# Hardware-accelerated GPS acquisition: the CPU sweeps code-phase hypotheses and the
# correlator does the integration. Per hypothesis the CPU issues a handful of register
# accesses; the 1023 sample multiply-accumulates happen in the accelerator.
#
# Results are written to 0x3000: best phase, then peak magnitude, then a cycle counter
# proxy (instructions retired is read out by the testbench instead).

    li   x1, 0x10000000        # peripheral base
    li   x2, 1
    sw   x2, 4(x1)             # PRN = 1
    li   x2, 1023
    sw   x2, 8(x1)             # NUM_SAMPLES = 1023
    li   x2, 0x4000
    sw   x2, 16(x1)            # SAMPLE_BASE = 0x4000

    li   x5, 0                 # phase under test
    li   x6, 1023              # number of hypotheses
    li   x7, 0                 # best magnitude so far
    li   x8, 0                 # best phase so far

sweep:
    sw   x5, 12(x1)            # CODE_PHASE = phase
    li   x2, 1
    sw   x2, 0(x1)             # start

poll:
    lw   x2, 0(x1)
    andi x2, x2, 2             # STATUS.done
    beq  x2, x0, poll

    lw   x9, 20(x1)            # read accumulator

    bge  x9, x0, positive      # |acc|
    sub  x9, x0, x9
positive:

    bge  x7, x9, next          # keep the larger magnitude
    add  x7, x9, x0
    add  x8, x5, x0
next:
    addi x5, x5, 1
    blt  x5, x6, sweep

    li   x10, 0x3000
    sw   x8, 0(x10)            # best phase
    sw   x7, 4(x10)            # peak magnitude
    ecall
