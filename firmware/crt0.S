// Reset vector and C runtime startup for the RV32I SoC.
//
// The core comes out of reset with PC = 0 and every architectural register zeroed, and
// there is no bootloader, no ROM, and no runtime library underneath this. Everything the
// C environment assumes to be true has to be made true here, in this order:
//
//   1. a valid stack pointer          -- C cannot call anything without one
//   2. zeroed .bss                    -- the C standard guarantees it; the image doesn't
//                                        contain it, so nobody zeroes it unless we do
//   3. jump to main
//   4. halt cleanly when main returns
//
// There is deliberately no .data copy loop. On a system that boots from flash, .data has
// a load address in flash and a run address in RAM, and startup copies between them.
// Here the image is loaded directly into the single memory array at its final addresses,
// so load address and run address are identical and a copy loop would move bytes onto
// themselves. Writing one anyway would be cargo-culting; the linker script asserts the
// two are equal instead.

    .section .init, "ax"
    .global _start
    .type _start, @function

_start:
    // 1. Stack pointer. Grows down from the top of the linker's RAM region, which stops
    //    short of the host-owned area at 0x5000 (see link.ld).
    la      sp, _stack_top

    // gp is not used by this build (no -msmall-data-limit relaxation), but leaving it
    // undefined would break any object that did rely on it, so it is pointed somewhere
    // deterministic rather than left as whatever reset happened to leave behind.
    la      gp, _end

    // 2. Zero .bss. _sbss/_ebss come from the linker script and are word-aligned there,
    //    so this can store a word at a time without a byte-tail case.
    la      t0, _sbss
    la      t1, _ebss
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    // 3. Into C. main takes no arguments and returns int; a0 holds the return value.
    call    main

    // 4. Halt. The core treats ECALL as end-of-run and raises its halted flag, which is
    //    what the testbench waits on. Looping forever instead would hang the simulation.
_halt:
    ecall
    j       _halt            // unreachable; guards against ECALL ever becoming resumable

    .size _start, . - _start
