#!/usr/bin/env bash
# Post-technology-mapping cell / flip-flop / latch counts for one or more modules.
#
# Extracting these correctly is fiddlier than it looks, and getting it wrong is silent, so
# the two traps are written down here rather than rediscovered:
#
#  1. `synth ...; abc -g cmos; stat` emits TWO statistics blocks -- synth's own internal one
#     (pre-abc, generic cells) and the explicit trailing one (post-abc, mapped cells). Only
#     the last is meaningful. The README already records an earlier revision of the `synth`
#     target that reported the pre-map numbers by mistake; this is the same trap one level up.
#
#  2. Within that last block, a hierarchical module produces one "Local Count, excluding
#     submodules" section per module PLUS a "=== design hierarchy ===" section counting
#     everything including submodules. Summing flip-flops across the whole block therefore
#     double-counts: for `correlator` it gives 20 (ca_code_gen) + 81 (correlator local) + 101
#     (hierarchy total) = 202, exactly twice the real 101. The hierarchy section is the one to
#     read when it exists.
#
# Calibrated against the figures already published in the README -- correlator 871/101,
# ca_code_gen 159/20, uart_tx 211/33, uart_rx 322/43 -- so a future change to yosys's output
# format shows up as a calibration failure rather than as quietly wrong new numbers.
#
# usage: bash scripts/synth_stat.sh [--check] [module:file[,file...]] ...
#        bash scripts/synth_stat.sh                 # default set, with calibration
set -u
cd "$(dirname "$0")/.." || exit 1

OSS_BIN="$HOME/tools/oss-cad-suite/bin"
YOSYS="$(if [ -x "$OSS_BIN/yosys" ]; then echo "$OSS_BIN/yosys"; else echo yosys; fi)"
mkdir -p build

stat_one () {
  local top="$1" files="$2"
  local log="build/stat_$top.log"
  $YOSYS -p "read_verilog -defer ${files//,/ }; synth -top $top; abc -g cmos; stat" \
    > "$log" 2>&1 || { echo "yosys failed for $top, see $log" >&2; return 1; }

  local start blk sub
  start=$(grep -n 'Printing statistics' "$log" | tail -1 | cut -d: -f1)
  blk=$(tail -n +"$start" "$log")

  # Prefer the whole-design (including submodules) section when the module is hierarchical.
  sub=$(echo "$blk" | grep -n '=== design hierarchy ===' | head -1 | cut -d: -f1)
  if [ -n "$sub" ]; then
    blk=$(echo "$blk" | tail -n +"$sub")
  fi

  local cells ffs latches
  cells=$(echo "$blk"   | grep -E '^ +[0-9]+ cells$' | tail -1 | awk '{print $1}')
  ffs=$(echo "$blk"     | grep -oE '^ +[0-9]+ +\$_[A-Z]*DFF[A-Z0-9_]*_'            | awk '{s+=$1} END{print s+0}')
  latches=$(echo "$blk" | grep -oE '^ +[0-9]+ +\$_[A-Z]*(DLATCH|LATCH)[A-Z0-9_]*_' | awk '{s+=$1} END{print s+0}')
  printf '| `%s` | %s | %s | %s |\n' "$top" "${cells:-?}" "$ffs" "$latches"
}

CORR=rtl/ca_code_gen.v,rtl/correlator.v
MACF=rtl/mac.v,rtl/mac_bus.v

if [ "$#" -gt 0 ]; then
  echo "| module | cells | flip-flops | latches |"
  echo "|---|---:|---:|---:|"
  for spec in "$@"; do stat_one "${spec%%:*}" "${spec#*:}"; done
  exit 0
fi

echo "calibration against the README's published figures:"
echo "| module | cells | flip-flops | latches |"
echo "|---|---:|---:|---:|"
stat_one ca_code_gen "rtl/ca_code_gen.v"
stat_one correlator  "$CORR"
stat_one uart_tx     "rtl/uart.v"
stat_one uart_rx     "rtl/uart.v"
echo "expected: ca_code_gen 159/20, correlator 871/101, uart_tx 211/33, uart_rx 322/43"
echo
echo "new blocks:"
echo "| module | cells | flip-flops | latches |"
echo "|---|---:|---:|---:|"
stat_one mac     "rtl/mac.v"
stat_one mac_bus "$MACF"
