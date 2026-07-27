#!/usr/bin/env python3
"""Convert a flat binary image into the one-word-per-line hex format the testbench loads.

`objcopy -O binary` gives a byte image starting at the lowest section address, which for
this linker script is 0. The SoC's memory is a 32-bit word array read with $readmemh, so
the image has to be re-emitted as little-endian words, one per line, with no address
records -- the same format model/asm.py produces, so both toolchains drop into the same
testbench unchanged.
"""

import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <in.bin> <out.hex>")

    data = open(sys.argv[1], "rb").read()

    # Pad to a word boundary. A trailing partial word can only come from a section whose
    # size is not a multiple of 4; zero-filling it is what the memory array would hold
    # anyway.
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], "little")
            f.write(f"{word:08x}\n")

    print(f"converted {len(data)} bytes -> {len(data) // 4} words -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
