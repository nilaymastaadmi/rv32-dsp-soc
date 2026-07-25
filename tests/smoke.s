# Smoke test: deliberately targets the decode paths that are most often silently wrong
# in a fresh RV32I implementation. Each block leaves its result in a distinct register so
# a single register dump tells you exactly which one failed.

    # --- block 1: loop with accumulate. sum 1..10 = 55 -> s1
    li   s1, 0              # accumulator
    li   t0, 1              # i
    li   t1, 11             # limit
loop:
    add  s1, s1, t0
    addi t0, t0, 1
    blt  t0, t1, loop       # BLT, signed
    # s1 should be 55 (0x37)

    # --- block 2: signed vs unsigned comparison must disagree here
    li   t2, -1             # 0xFFFFFFFF
    li   t3, 1
    slt  s2, t2, t3         # signed: -1 < 1  -> 1
    sltu s3, t2, t3         # unsigned: 0xFFFFFFFF < 1 -> 0
    # s2=1, s3=0

    # --- block 3: arithmetic vs logical right shift must disagree here
    li   t4, -16            # 0xFFFFFFF0
    srai s4, t4, 2          # sign-extends -> 0xFFFFFFFC
    srli s5, t4, 2          # zero-fills   -> 0x3FFFFFFC
    # s4=0xFFFFFFFC, s5=0x3FFFFFFC

    # --- block 4: shift amount must use only the low 5 bits
    li   t5, 1
    slli s6, t5, 33         # 33 & 31 = 1 -> 2, not 0
    # s6=2

    # --- block 5: memory round trip at all three widths
    li   t6, 0x2000
    li   a0, 0x12345678
    sw   a0, 0(t6)
    lw   s7, 0(t6)          # 0x12345678
    lbu  s8, 0(t6)          # little-endian low byte -> 0x78
    lb   a1, 3(t6)          # 0x12 -> sign-extends positive
    sh   a0, 8(t6)
    lhu  s9, 8(t6)          # 0x5678
    # s7=0x12345678, s8=0x78, a1=0x12, s9=0x5678

    # --- block 6: byte-enable behaviour. overwrite one byte inside a word
    li   a2, 0xFF
    sb   a2, 1(t6)
    lw   s10, 0(t6)         # 0x1234FF78 if byte lanes are right
    # s10=0x1234FF78

    # --- block 7: LUI + immediate sign-extension interaction
    lui  a3, 0x12345
    addi a3, a3, -1         # 0x12345000 - 1 = 0x12344FFF
    # a3=0x12344FFF

    # --- block 8: jal/jalr link register and return
    jal  ra, subr
    # a4 set by subr
    j    done

subr:
    li   a4, 0xABC
    ret                     # jalr x0, ra, 0

done:
    ecall                   # halt
