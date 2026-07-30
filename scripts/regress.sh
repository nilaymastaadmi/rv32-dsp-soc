#!/bin/bash
# Randomized regression: N seeds, each a fresh random program run on both models.
# Reports a pass/fail tally and keeps the failing artifacts for any seed that diverges,
# so a failure is reproducible from its seed alone.

cd "$HOME/rv32-dsp-soc" || exit 1
N=${1:-100}
BODY=${2:-150}
mkdir -p build/rand

# This script used to invoke `./build/sim_run <hex> <trace>` positionally. No Makefile
# target has ever built a binary by that name -- not in any commit -- so every seed failed
# on a missing executable and the tally read "0 passed, N failed" regardless of whether the
# core was correct. `make check` was unaffected, which is why it went unnoticed: the smoke
# test passes through a different code path. The RTL simulator the Makefile does build is
# build/sim (tb_soc), and it takes plusargs rather than positional arguments.
VVP="$(if [ -x "$HOME/tools/oss-cad-suite/bin/vvp" ]; then echo "$HOME/tools/oss-cad-suite/bin/vvp"; else echo vvp; fi)"

if [ ! -x build/sim ] || [ ! -x build/iss ]; then
  echo "build/sim or build/iss missing -- run 'make sim iss' first" >&2
  exit 1
fi

pass=0
fail=0
failed_seeds=""

for seed in $(seq 1 "$N"); do
  python3 model/gen_random.py "$seed" build/rand/r$seed.s "$BODY" 2>/dev/null
  python3 model/asm.py build/rand/r$seed.s build/rand/r$seed.hex > /dev/null 2>&1 || {
    echo "seed $seed: ASSEMBLER ERROR"; fail=$((fail+1)); continue; }

  ./build/iss build/rand/r$seed.hex build/rand/r$seed.iss 500000 2> /dev/null
  "$VVP" build/sim +hex=build/rand/r$seed.hex +trace=build/rand/r$seed.rtl +max=500000 \
    > /dev/null 2>&1

  if diff -q build/rand/r$seed.iss build/rand/r$seed.rtl > /dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    failed_seeds="$failed_seeds $seed"
  fi
done

echo "================================"
echo "seeds run : $N  (body $BODY instructions each)"
echo "passed    : $pass"
echo "failed    : $fail"
[ -n "$failed_seeds" ] && echo "failing seeds:$failed_seeds"
echo "total instructions compared: ~$((N * (BODY + 31)))"
echo "================================"
[ "$fail" -eq 0 ] || exit 1
