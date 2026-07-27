/* Linker script for the RV32I SoC.
 *
 * The SoC has one flat 65536-word (256 KB) memory array serving both instruction fetch
 * and data access, and the core resets with PC = 0. So .text has to start at address 0
 * and everything else is placed by this script.
 *
 * The region below is deliberately only the first 20 KB of that array, not all of it.
 * Addresses 0x5000 upward belong to the host test controller, which writes a vector
 * count and test data there before the run and reads results back afterwards:
 *
 *   0x5000        vector count            (host -> device)
 *   0x5004+       test bytes, one/word    (host -> device)
 *   0x6000        pass count              (device -> host)
 *   0x6004        fail count              (device -> host)
 *   0x7000+       received bytes, one/word(device -> host)
 *
 * Confining the link region to 0x0-0x5000 means the linker physically cannot place a
 * section on top of that shared region, and the stack (which grows down from the top of
 * the region) cannot grow into it either. Getting this wrong is the classic bare-metal
 * failure: the stack silently eats a data structure and the symptom shows up somewhere
 * unrelated.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00005000   /* 20 KB, ends where host region begins */
}

ENTRY(_start)

SECTIONS
{
    /* Reset vector first: the core starts executing at address 0, so _start must be the
     * very first thing in the image. KEEP() stops --gc-sections from discarding it,
     * since nothing "calls" it. */
    .text 0x00000000 :
    {
        KEEP(*(.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > RAM

    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM

    /* .bss is not in the image file, so crt0 has to zero it at startup. These symbols
     * are what tells it where. */
    .bss : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    _end = .;

    /* Stack grows down from the top of the region, i.e. from just below 0x5000. */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) }
}
