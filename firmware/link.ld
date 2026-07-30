/* Linker script for bare-metal firmware on this SoC.
 *
 * The core resets with PC = 0 and the testbench $readmemh's the image into memory word 0,
 * so the entry point must be the very first thing in .text at address 0. That is enforced
 * by giving crt0.S's code its own input section (.text.entry) and placing it first, rather
 * than relying on link order happening to put the right object first.
 *
 * There is no bootloader, no ROM/RAM split and no relocation: the image is loaded straight
 * into the one flat memory the core fetches from, so load address and virtual address are
 * the same everywhere and there is nothing to copy at startup except zeroing .bss.
 */

ENTRY(_start)

MEMORY
{
  /* 65536 words of 32 bits. Matches soc_top's MEM_WORDS parameter; if that parameter
     ever changes this length must change with it. */
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 256K
}

SECTIONS
{
  .text 0x00000000 : {
    KEEP(*(.text.entry))    /* crt0: must be at 0, must not be GC'd */
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.*)    /* the quantised weights and the baked-in test vectors */
  } > RAM

  .data : ALIGN(4) {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > RAM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  /* Where the image stops. Reported by the build so the stack top can be sanity-checked
     against it rather than assumed to be clear. */
  __image_end = .;

  /* Stack grows down from here. Value comes from firmware/soc.h; the two must agree. */
  __stack_top = 0x0000E000;

  /* Nothing generates these in a -nostdlib build, but discarding them explicitly keeps a
     stray .eh_frame or .comment from silently landing in the middle of the image. */
  /DISCARD/ : {
    *(.comment)
    *(.note .note.*)
    *(.eh_frame .eh_frame_hdr)
    *(.riscv.attributes)
  }
}
