# Firmware-style UART self-test, running on the RV32I core.
#
# Reads a vector count and a block of test bytes that the Python host controller placed in
# memory, transmits each one through the UART, waits for it to arrive back over the
# loopback, and compares. Pass/fail counters and every received byte are written to a
# results region for the host to read back and score.
#
# This is deliberately structured the way a real bring-up test would be: the CPU polls a
# status register rather than relying on timing, so it stays correct at any baud divisor.
#
# Memory map used here:
#   0x5000  vector count
#   0x5004+ test bytes, one per word
#   0x6000  pass count
#   0x6004  fail count
#   0x7000+ received bytes, one per word

    li   x1, 0x10001000        # UART base
    li   x2, 4
    sw   x2, 8(x1)             # BAUD_DIV

    li   x3, 0x5000
    lw   x4, 0(x3)             # count
    li   x5, 0                 # index
    li   x6, 0                 # pass
    li   x7, 0                 # fail
    li   x8, 0x5004            # next vector
    li   x9, 0x7000            # next result slot

loop:
    beq  x5, x4, done

    lw   x10, 0(x8)            # byte to transmit
    sw   x10, 4(x1)            # TXDATA
    li   x11, 1
    sw   x11, 0(x1)            # pulse SEND

poll:
    lw   x12, 0(x1)            # STATUS
    andi x12, x12, 2           # rx_ready
    beq  x12, x0, poll

    lw   x13, 4(x1)            # RXDATA (also clears rx_ready)
    andi x13, x13, 255
    sw   x13, 0(x9)            # log what actually came back

    beq  x13, x10, ok
    addi x7, x7, 1
    j    next
ok:
    addi x6, x6, 1
next:
    addi x5, x5, 1
    addi x8, x8, 4
    addi x9, x9, 4
    j    loop

done:
    li   x14, 0x6000
    sw   x6, 0(x14)            # pass count
    sw   x7, 4(x14)            # fail count
    ecall
