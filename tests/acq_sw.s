# Software-only GPS acquisition, for cycle comparison against the accelerated version.
# Identical search: 1023 code-phase hypotheses, 1023-sample coherent integration each,
# same input samples, same answer expected.
#
# The comparison is deliberately biased in software's favour so the resulting speedup is
# a floor rather than a best case:
#   - the C/A code is handed to it precomputed in memory, so it never pays for code
#     generation, while the accelerator generates its code on the fly every hypothesis
#   - the code table is stored twice back to back, so indexing past the end of one period
#     needs no modulo and no wrap test in the inner loop
#   - correlation is done with a branch and an add/subtract rather than a multiply, which
#     is the cheapest form available on a base integer core

    li   x1, 0x4000            # sample block
    li   x2, 0x8000            # doubled code table
    li   x5, 0                 # phase under test
    li   x6, 1023              # hypotheses, and samples per integration
    li   x7, 0                 # best magnitude
    li   x8, 0                 # best phase

phase_loop:
    li   x9, 0                 # accumulator
    add  x11, x1, x0           # sample pointer
    slli x14, x5, 2
    add  x12, x2, x14          # code pointer = table + phase
    li   x13, 0                # sample index

inner:
    lw   x14, 0(x11)           # received sample
    lw   x15, 0(x12)           # code chip: 1 means the -1 symbol
    beq  x15, x0, chip_plus
    sub  x9, x9, x14
    j    chip_done
chip_plus:
    add  x9, x9, x14
chip_done:
    addi x11, x11, 4
    addi x12, x12, 4
    addi x13, x13, 1
    blt  x13, x6, inner

    bge  x9, x0, positive      # |acc|
    sub  x9, x0, x9
positive:

    bge  x7, x9, next
    add  x7, x9, x0
    add  x8, x5, x0
next:
    addi x5, x5, 1
    blt  x5, x6, phase_loop

    li   x10, 0x3000
    sw   x8, 0(x10)            # best phase
    sw   x7, 4(x10)            # peak magnitude
    ecall
