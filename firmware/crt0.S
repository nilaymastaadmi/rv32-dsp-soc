# Startup code. Runs at PC = 0 out of reset, hands off to main(), halts on return.
#
# Deliberately minimal: no libc, no bootloader, no interrupt vector table (the core has
# no CSRs or interrupts), no global-pointer setup (nothing is compiled -msmall-data so
# nothing addresses through gp), and no .data copy (load and run addresses are identical
# in this flat memory, so .data is already where it belongs).
#
# What it does do is zero .bss, because the C code relies on static storage starting at
# zero and the testbench's own memory zeroing is not something the firmware should depend
# on -- a real target's RAM comes up with whatever was in it.

    .section .text.entry, "ax"
    .globl _start
_start:
    # Stack pointer. __stack_top comes from the linker script.
    la      sp, __stack_top

    # Zero .bss, word at a time. __bss_start/__bss_end are 4-aligned by the linker script,
    # so no tail handling for a partial word is needed.
    la      t0, __bss_start
    la      t1, __bss_end
bss_clear:
    bge     t0, t1, bss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       bss_clear
bss_done:

    call    main

    # ECALL is what this core treats as "run finished" -- soc_top's core sets its halt flag
    # on any SYSTEM opcode, and the testbench prints the retired-instruction and cycle
    # counts at that point. Reaching here means main() returned normally.
halt:
    ecall
    j       halt            # unreachable once halted, but never fall into whatever follows
