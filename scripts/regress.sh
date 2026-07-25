#!/bin/bash
# Randomized regression: N seeds, each a fresh random program run on both models.
# Reports a pass/fail tally and keeps the failing artifacts for any seed that diverges,
# so a failure is reproducible from its seed alone.

cd "$HOME/rv32-dsp-soc" || exit 1
N=${1:-100}
BODY=${2:-150}
mkdir -p build/rand

pass=0
fail=0
failed_seeds=""

for seed in $(seq 1 "$N"); do
  python3 model/gen_random.py "$seed" build/rand/r$seed.s "$BODY" 2>/dev/null
  python3 model/asm.py build/rand/r$seed.s build/rand/r$seed.hex > /dev/null 2>&1 || {
    echo "seed $seed: ASSEMBLER ERROR"; fail=$((fail+1)); continue; }

  ./build/iss build/rand/r$seed.hex build/rand/r$seed.iss 500000 2> /dev/null
  ./build/sim_run build/rand/r$seed.hex build/rand/r$seed.rtl > /dev/null 2>&1

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
