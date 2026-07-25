# rv32-dsp-soc

A small RISC-V SoC with a GPS L1 C/A correlator attached as a memory-mapped accelerator,
written to answer a question left over from a software GNSS receiver project: the code
phase search was the expensive part, so what does it cost to put it in hardware instead?

Everything here is verified against an independent reference model rather than by
inspecting waveforms. The CPU is checked instruction by instruction against a C++
instruction-set simulator, and the correlator is checked against a C++ signal model that
first validates itself against the GPS interface specification.

## Result

Both paths run the same 1023-hypothesis acquisition search over the same noisy samples
and return the same answer, so the comparison is like for like.

| | cycles | per hypothesis | result |
|---|---:|---:|---|
| software on the RV32I core | 8,905,752 | 8,705 | phase 511, peak 22013 |
| hardware accelerator | 1,583,123 | 1,547 | phase 511, peak 22013 |

**5.63x** speedup, measured, and it is a floor rather than a best case: the software
version is handed a precomputed code table so it never pays for code generation, the
table is stored twice so its inner loop needs no modulo, and correlation is done with a
branch and an add rather than a multiply.

The remaining hardware cost is dominated by the code slew, which averages 511 idle cycles
per hypothesis while the generator is advanced to the phase under test, plus the CPU
busy-polling the done flag. Parallel correlator banks or an FFT-based search are the
natural next steps.

## Synthesis (Yosys, generic cell library)

| module | cells | flip-flops |
|---|---:|---:|
| `rv32i_core` | 8,305 | 1,024 |
| `correlator` (incl. code generator) | 814 | 101 |
| `ca_code_gen` | 165 | 20 |

The core's flip-flop count is exactly 31x32 register bits plus a 32-bit PC, confirming
that x0's storage was correctly optimised away rather than instantiated and tied off.

## How correctness is decided

**The CPU** retires exactly one instruction per clock and exposes a retire port, so the
testbench emits one trace line per instruction in the same format the C++ ISS produces.
Correctness is then a `diff`. There is no human judgement in the loop, and a failure
names the exact PC and encoded instruction where the two models diverged.

Coverage is a directed smoke test plus a constrained-random regression:

```
make check TEST=smoke        # 62 instructions, hand-aimed at the classic decode traps
bash scripts/regress.sh 400 300   # 400 random programs, ~132k instructions compared
```

The directed test targets signed versus unsigned comparison, arithmetic versus logical
shift, shift-amount masking, every load and store width, byte-lane merging, and jump
linkage. The random generator reserves a data pointer and emits no control flow, so every
program terminates in a known instruction count while still producing operand and
immediate combinations nobody chose deliberately.

**The correlator** is checked in two stages. Its reference model validates itself against
IS-GPS-200 before being trusted: first-ten-chip octal values for PRN 1 through 10, an
autocorrelation peak of exactly 1023 with the three-valued off-peak signature a Gold code
family must have, and worst-case cross-correlation 23.9 dB below the peak. Then the RTL
must match that model chip for chip across a full 1023-chip period, and a full acquisition
sweep over a 45 dB-Hz signal must peak at the same phase and the same accumulated value.

## Two defects the harness caught

Both were found by the trace comparison, not by reading waveforms, and both are recorded
because the way they presented is the useful part.

**Arithmetic right shift executing as logical.** `SRAI` returned `0x3ffffffc` where the
model said `0xfffffffc`. The cause is Verilog signedness propagation: in
`alt ? ($signed(a) >>> shamt) : (a >> shamt)`, the ternary's result type is derived from
both branches, so pairing a signed branch with an unsigned one makes the whole expression
unsigned, and that pushes back onto the operands and silently degrades `>>>` into `>>`.
Fixed by splitting the two shifts into separate self-determined assignments.

**Acquisition peak one chip late.** The peak magnitude was exactly correct but attributed
to phase 512 instead of 511, which immediately localised the fault to phase bookkeeping
rather than the datapath. The code generator's enable was registered, putting the slew one
cycle out of step with its own counter. Fixed by driving the generator's control
combinationally from the state, so N cycles in the slew state means exactly N chips.

## Layout

```
model/    iss.cpp          RV32I instruction-set simulator, the golden reference
          gnss_model.cpp   C/A code and signal model, self-validating against IS-GPS-200
          asm.py           minimal two-pass RV32I assembler
          gen_random.py    constrained-random program generator
rtl/      rv32i_core.v     single-cycle RV32I
          soc_top.v        core, memory, peripheral decode
          ca_code_gen.v    dual-LFSR gold code generator
          correlator.v     integrate-and-dump with code slew
          correlator_bus.v memory-mapped register interface
tb/       tb_soc.v         trace-emitting SoC testbench
          tb_correlator.v  standalone correlator verification
tests/    smoke.s          directed decode test
          acq_hw.s         accelerated acquisition sweep
          acq_sw.s         software-only acquisition sweep
```

## Building

Requires `iverilog`, `yosys`, `g++` and `python3`. No cross-compiler is needed; the
included assembler covers the instruction subset the tests use.

```
make check TEST=smoke     # ISS versus RTL
make synth                # gate counts
bash scripts/regress.sh   # randomised regression
```

## Scope

This is a single-cycle core: no pipeline, no hazard logic, no caches, no CSRs or
interrupts, and memory is a flat asynchronous-read array. Those are the deliberate
next steps rather than oversights, and the retire-port trace methodology is specifically
designed to survive them, since a pipelined core still retires instructions in order and
can emit the same trace format.
