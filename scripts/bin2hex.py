#!/usr/bin/env python3
"""Flat binary -> one 32-bit hex word per line, little-endian.

Emits exactly the format model/asm.py already produces, so a firmware image built by the
C toolchain drops into the same $readmemh / ISS loader path as a hand-assembled test with
no change on the consumer side.

A trailing partial word is zero-padded rather than dropped: .rodata can end mid-word and
silently truncating the last one to three bytes of a weight array would be a genuinely
nasty bug to chase.
"""
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <in.bin> <out.hex>")

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    pad = (-len(data)) % 4
    if pad:
        data += b"\x00" * pad

    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")

    print(f"{len(data) // 4} word(s) ({len(data)} bytes"
          + (f", {pad} pad" if pad else "")
          + f") -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
