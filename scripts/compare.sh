#!/bin/bash
# Compare an ISS trace against an RTL trace and report the first divergence.
#
# The first differing line is the useful artifact: it names the PC and encoded
# instruction where the two models parted company, which is almost always enough to
# identify the decode or execute path at fault without opening a waveform.

ISS="$1"
RTL="$2"

if [ ! -f "$ISS" ] || [ ! -f "$RTL" ]; then
  echo "FAIL: missing trace file(s)"
  exit 1
fi

n_iss=$(wc -l < "$ISS")
n_rtl=$(wc -l < "$RTL")

if diff -q "$ISS" "$RTL" > /dev/null 2>&1; then
  echo "PASS: $n_iss instructions, traces identical"
  exit 0
fi

echo "FAIL: traces diverge"
echo "  ISS retired: $n_iss"
echo "  RTL retired: $n_rtl"
echo ""

line=$(diff <(cat "$ISS") <(cat "$RTL") | head -1 | grep -oE '^[0-9]+' | head -1)
[ -z "$line" ] && line=1

start=$(( line > 3 ? line - 3 : 1 ))
echo "--- first divergence near line $line ---"
echo "        pc       insn     rd val"
echo "ISS:"
sed -n "${start},$((line + 2))p" "$ISS" | sed 's/^/  /'
echo "RTL:"
sed -n "${start},$((line + 2))p" "$RTL" | sed 's/^/  /'
echo ""
echo "Read the first line where they differ: field 1 is the PC, field 2 the encoded"
echo "instruction, field 3 the destination register, field 4 the value written."
exit 1
