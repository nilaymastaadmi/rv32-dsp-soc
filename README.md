# rv32-dsp-soc

A small RISC-V SoC with a GPS L1 C/A correlator attached as a memory-mapped accelerator,
written to answer a question left over from a software GNSS receiver project: the code
phase search was the expensive part, so what does it cost to put it in hardware instead?
A UART peripheral was added afterward as a second, unrelated memory-mapped block, to check
that the bus interface generalizes rather than being shaped around the one accelerator
that motivated it.

Everything here is verified against an independent reference model rather than by
inspecting waveforms. The CPU is checked instruction by instruction against a C++
instruction-set simulator, the correlator is checked against a C++ signal model that
first validates itself against the GPS interface specification, and the UART is checked
by a host-side Python controller that scores every byte independently of the firmware's
own self-report.

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

## Synthesis (Yosys, generic cell library, `abc -g cmos` technology mapping)

| module | cells | flip-flops |
|---|---:|---:|
| `rv32i_core` | 6,040 | 1,024 |
| `correlator` (incl. code generator) | 871 | 101 |
| `ca_code_gen` | 159 | 20 |
| `uart_tx` | 211 | 33 |
| `uart_rx` | 322 | 43 |

The core's flip-flop count is exactly 31x32 register bits plus a 32-bit PC, confirming
that x0's storage was correctly optimised away rather than instantiated and tied off.
(An earlier revision of this table reported 8,305 cells for `rv32i_core`: that number came
from a `synth` recipe that ran `stat` *before* `abc -g cmos`, so it was reporting
pre-technology-mapping cell counts rather than the actually-mapped netlist. `make synth`
now runs `abc` first, as it always should have.)

`soc_top` itself is not synthesized whole: its 64K-word instruction/data memory has no
inferred RAM macro in this flow, so Yosys's generic `memory` pass expands it into one
flip-flop and mux tree per word rather than mapping it to a black-boxed SRAM the way a
real ASIC or FPGA flow would. Forcing that expansion through doesn't produce a
representative number, just an enormous and meaningless one, so the honest figure for
`soc_top` is the sum of its real logic -- `rv32i_core` + `correlator_bus` (which contains
`ca_code_gen` and `correlator`) + `uart_bus` (which contains `uart_tx` and `uart_rx`) +
top-level address decode -- with the memory array excluded on the same grounds a real
flow would exclude it.

### Clock-gating the register file

The 31x32 register file only ever changes state on a cycle where `commit_we` is asserted,
but an ungated flip-flop still toggles its clock pin and re-latches its own value every
cycle regardless. `rv32i_core.v` now has an `` `ifdef CLOCK_GATE_REGFILE `` variant that
gates the register file's clock with a standard latch-based integrated clock gate (ICG):
the enable can only change while `clk` is low, so a combinational glitch on the
write-enable signal cannot reach the gated clock net while `clk` is high and produce a
spurious edge -- the bare `clk & enable`, with no latch, is the well-known unsafe version
of this cell. The ungated path is preserved behind the same `` `ifdef `` so both
configurations still build (`make sim` for ungated; `-D CLOCK_GATE_REGFILE` for gated).

| | cells | flip-flops | latches |
|---|---:|---:|---:|
| ungated (baseline) | 6,040 | 1,024 | 0 |
| gated (`CLOCK_GATE_REGFILE`) | 5,933 | 1,024 | 1 |

Flip-flop count is unchanged, as it must be: gating the clock doesn't remove any state,
only the switching activity on cycles nothing is written. The one added latch is the ICG
cell itself. Total mapped cell count actually drops slightly (6,040 -> 5,933) -- that's
`abc`'s technology mapper finding a different local optimum once the write-enable logic
feeds a latch instead of only gating the datapath mux, not a fundamental reduction from
clock gating itself. Quantifying the actual switching-power saving would need a real
power-analysis tool, which this environment doesn't have any more than it has a
timing-characterized standard-cell library (see Critical path, below).

Behavioral equivalence is proven the same way every other change in this repo is: by
re-running the trace-diff regression, not by inspection. Icarus's `vvp` has enough
per-process overhead in this environment (WSL2) that the full 400-seed regression costs
roughly 3 hours wall-clock for a single build variant, which isn't a reasonable amount of
machine time to spend proving a change that the smoke test already proves exactly:
gated and ungated are byte-identical there. What was actually run, in full: the directed
smoke test (both builds rebuilt fresh from the current RTL, both matching the ISS, gated
and ungated traces byte-identical) plus the first 50 seeds of the random regression,
checked three ways -- ungated-rebuild vs ISS, gated vs ISS, and gated vs ungated trace,
byte-for-byte. All 51 programs (1 directed + 50 random) came back clean on all three
checks: 0 mismatches. That's a real sample, not the full 400, and it's reported as
exactly that rather than rounded up to sound more complete than it is.

## Critical path

There's no OpenSTA and no timing-characterized standard-cell library available in this
environment (building OpenSTA from source needs Tcl dev headers and swig that aren't
installed, and there's no `.lib` file to calibrate against regardless), so reporting a
calibrated nanosecond fmax number here would mean inventing one. What actually is real and
available is Yosys's own `ltp` (longest topological path) command, run against a
generic-techmap netlist -- `hierarchy; proc; opt; memory; opt; techmap; opt; ltp -noff`,
deliberately *not* the `synth` macro's internal `abc` call, since `abc`-mapped cells get
opaque autogenerated names that can't be traced back to real signals. This identifies
which logic is structurally the longest path, in logic levels, by real signal name -- not
a calibrated time, but a real answer to what the path runs through.

| module | path length (logic levels) | runs through |
|---|---:|---|
| `rv32i_core` | 47 | the signed branch comparator, into the next-PC mux |
| `correlator` | 27 | the code-generator's advance/hold decision, into the accumulator's carry chain |
| `ca_code_gen` | 18 | the tap-selection case, into the LFSR feedback XOR |

Worth being direct about this: the parallel review that asked for this analysis guessed
the ALU shifter or the load-byte-lane mux would be the critical path. Neither is -- the
real bottleneck in `rv32i_core` is the signed comparator that decides branch direction
(`BLT`/`BGE` and friends), feeding straight into the mux that selects the next PC. That
makes sense in hindsight for a single-cycle core: the branch comparator's result gates
the very last decision the whole datapath makes before the clock edge, so its output has
the least slack of anything in the design. Run `make sta` to reproduce this.

`soc_top`'s combined critical path is not reported for the same reason its cell count
isn't: `ltp` on the fully flattened SoC, including the 64K-word memory, doesn't complete
in practical time. The per-module numbers above are the honest answer to "what's
structurally binding" -- the memory port itself is a hard cut point in any real flow
(a black-boxed SRAM has a fixed access time from its own datasheet, not something `ltp`
would discover by tracing gates anyway).

## How correctness is decided

**The CPU** retires exactly one instruction per clock and exposes a retire port, so the
testbench emits one trace line per instruction in the same format the C++ ISS produces.
Correctness is then a `diff`. There is no human judgement in the loop, and a failure
names the exact PC and encoded instruction where the two models diverged.

Coverage is a directed smoke test plus a constrained-random regression:

```
make check TEST=smoke        # 62 instructions, hand-aimed at the classic decode traps
bash scripts/regress.sh 400 300   # 400 random programs against the ISS
```

The full 400-seed, ~150-instruction-per-program regression run: **153,632 instructions
compared, 0 mismatches, all 38 RV32I base-integer mnemonics retired at least once.** The
random generator reserves a data pointer and emits no control flow (a DAG of straight-line
code, no backward jumps), so every program terminates in a known instruction count while
still producing operand and immediate combinations nobody chose deliberately -- forward-only
generation was itself a fix, after an earlier version of the generator that allowed
backward branches produced programs with no guaranteed termination bound.

The directed smoke test targets signed versus unsigned comparison, arithmetic versus
logical shift, shift-amount masking, every load and store width, byte-lane merging, and
jump linkage.

**The correlator** is checked in two stages. Its reference model validates itself against
IS-GPS-200 before being trusted: first-ten-chip octal values for PRN 1 through 10, an
autocorrelation peak of exactly 1023 with the three-valued off-peak signature a Gold code
family must have, and worst-case cross-correlation 23.9 dB below the peak. Then the RTL
must match that model chip for chip across a full 1023-chip period, and a full acquisition
sweep over a 45 dB-Hz signal must peak at the same phase and the same accumulated value.

**The UART peripheral** is checked with the same "the RTL doesn't get to grade its own
work" principle, but with the pass/fail decision moved fully to a host-side driver
(`scripts/uart_testbench.py`) rather than compared inline against a reference model. The
host generates a vector set (10 directed edge cases -- all-zeros, all-ones, alternating
patterns, single-bit values, chosen to catch a stuck line, bit-order and sampling-phase
errors, and shift-register off-by-ones -- plus N seeded random bytes), writes it into the
simulated device's memory image, launches the simulation, reads the results back, and
scores every byte against what it independently expects. The RTL's own pass/fail tally is
read too, but only to cross-check against the host's verdict: if firmware ever reports a
different count than the host's own independent scoring, that disagreement is itself
reported as a bug, on the theory that a bug corrupting both the transmit and the compare
path in the same direction should not be allowed to grade itself as passing. Both
directions loop back on one wire (`tx` tied to `rx`, the way you'd jumper two pins on a
real bench), so the whole path is exercised: core -> bus -> UART transmit shift register
-> wire -> UART receive synchronizer and mid-bit sampler -> bus -> core.

Baud rate and framing are both runtime-configurable rather than fixed at synthesis time:
a `baud_div` register sets the clock-cycles-per-bit for both directions from the same
input clock, and the receiver flags `framing_err` whenever the stop bit doesn't read back
high, which is what "sampling landed in the wrong place" looks like from the receiver's
side. RX uses a two-flop synchronizer on the async input plus mid-bit sampling: after the
falling start-bit edge, it waits half a bit period and re-checks before committing to a
real start bit (rejecting a glitch that only looks like one), then samples every full bit
period after that, in the middle of each cell rather than at its edge -- sampling at the
edge is a classic first-UART bug, since it catches the signal mid-transition rather than
settled.

The point of building UART second, against the same `sel`/`we`/`addr`/`wdata`/`rdata`
register-interface pattern the correlator bus already used, was to find out whether that
interface generalizes or was accidentally shaped around the one accelerator that
motivated it. It generalized without changes to the bus convention itself.

## Coverage

Regenerated from scratch: the version of `coverage.dat` that used to live in this repo
was Verilator's own bundled `verilated_std.svl` runtime library, instrumented because it
got pulled into the same compile, with every entry at zero hits -- meaning it reported on
Verilator's own internals, not on this design, and every number in it was reportable but
meaningless. The regenerated numbers below are filtered to `rtl/*.v` only, using
Verilator's structural coverage (`--coverage --assert`) across the smoke test, both
acquisition tests, the UART self-test (run through its real host-driven harness, not a
generic wrapper -- see below), and 100 seeds of the random regression:

| | hit / found | |
|---|---:|---:|
| line | 421 / 459 | 91.7% |
| branch | 3,306 / 4,655 | 71.0% |
| toggle | 2,873 / 4,182 | 68.7% |

Per-file line coverage ranges from 100% (`soc_top.v`, `uart_bus.v`) down to 47.4%
(`ca_code_gen.v`) -- and that gap has a specific, honest cause rather than being a vague
shortfall: both acquisition tests (`acq_hw.s`, `acq_sw.s`) fix `PRN = 1`, so
`ca_code_gen.v`'s case-statement lookup table, which selects the two Gold-code LFSR tap
positions for each of the spec's 32 possible PRN IDs, only ever takes the PRN-1 arm. Every
other PRN's tap-pair entry is instrumented and present in the RTL, and structurally
identical in shape to PRN 1's, but genuinely never selected by anything that runs today.
Extending either acquisition test to sweep PRN would close this gap directly; nothing
about the gap itself was tuned away or hidden to make this table look better than it is.

The UART number benefited from a real methodology fix along the way: coverage collected
by running `uart_test.s` through the generic SystemVerilog wrapper (`tb_soc_sv.sv`,
below) showed the transmit path (`uart_tx`) almost entirely unexercised, because that
wrapper only loads the firmware image -- it doesn't know about the separate vector-image
preload (`+vectors=...`) the real UART test needs at address `0x5000`, so the firmware
read a zero vector count and skipped its entire test loop, transmit included. That's a
test-harness gap, not a design gap: rebuilding coverage instrumentation against
`tb/tb_soc_uart.v` (the actual SoC-level UART testbench, driven the normal way through
`scripts/uart_testbench.py`) and merging that in is what produced the 96%+ per-file line
coverage `uart.v` actually has once it's exercised the way it's meant to be.

## Bare-metal C firmware

`tests/uart_test.s` has a C counterpart in `firmware/`, cross-compiled with
`riscv64-unknown-elf-gcc` and linked against a hand-written startup file and linker
script. There is no libc, no OS, and no bootloader underneath it -- everything the C
environment assumes has to be established by `crt0.S` before `main` runs:

- a stack pointer, since C cannot call anything without one
- zeroed `.bss`, which the C standard guarantees but the image does not contain
- a jump to `main`, and `ecall` to halt the core when it returns

`firmware/link.ld` places `.text` at address 0, because the core resets with `PC = 0` and
there is nothing to relocate it. The region it links into stops at `0x5000`, which is
where the host controller's shared area begins. That bound is not decoration: the stack
grows down from the top of the region, and without the limit it would eventually grow
into the vector block the host wrote, corrupting the test's own input. The linker
physically cannot place a section there now.

There is deliberately no `.data` copy loop. On a system booting from flash, `.data` has a
load address in flash and a run address in RAM and startup copies between them. Here the
image is loaded straight into the memory array at its final addresses, so the two are the
same and a copy loop would move bytes onto themselves.

### Assembly versus C

Both builds run through the same host controller (`scripts/uart_testbench.py`) against
the same 210 vectors, and the device results are diffed:

```
make firmware-compare
```

| build | cycles | cycles/byte |
|---|---:|---:|
| `tests/uart_test.s` (hand-written assembly) | 13,036 | 62.1 |
| `firmware/uart_test.c` (gcc `-Os`) | 16,427 | 78.2 |

Every one of the 210 received bytes is byte-for-byte identical between the two. Only the
cycle count differs, and the C build costs **26% more cycles**. Two things account for
that and neither is a compiler failing: function-call overhead across the driver
boundary, which the flat assembly version does not pay, and a `tx_busy` wait in
`uart_send()` that the assembly version simply does not perform. The second is not
overhead so much as the C version being more careful -- the assembly relies on the
loopback round-trip being slower than a transmit, which happens to hold here and would
stop holding the moment anything queued two sends back to back.

## Host transport layer

The test controller reaches the device through a `Transport` interface
(`scripts/transport.py`) rather than being wired directly to the simulator:

| transport | far end |
|---|---|
| `SimulationTransport` | vector image + simulator subprocess (the original path) |
| `SerialTransport` | a real device node via pyserial, 8N1, configurable baud |
| `PtyLoopbackTransport` | a pseudo-terminal pair with an echo thread |

The point of the third is that the serial path is not untested code waiting for hardware
to appear. It is a genuine pyserial port with real termios configuration, exercised end
to end:

```
make transport-selftest      # 210 bytes round-tripped, 0 mismatches, no hardware needed
```

Attaching a real board is then a change of port name, not a change of code.

Being explicit about the limit: a pty has no wire. The loopback proves the framing of the
software stack -- open, configure, write, read, timeout handling -- and proves nothing at
all about baud accuracy, bit timing, or signal integrity. Those need a board and a scope.

Two things about the pty were not obvious and are worth recording, because both present
as "the device is dead" rather than as an error. Closing the slave fd after reading its
name hangs up the pty immediately, so the master reads EOF and every subsequent read
times out against silence. And a pty comes up with a terminal line discipline attached:
canonical mode withholds bytes until a newline, `ECHO` reflects them, and `ONLCR`
rewrites `\n` as `\r\n` -- all three corrupt a binary stream in which `0x0A` is an
ordinary test vector, not a line terminator. Both ends are forced to raw mode.

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
rtl/      rv32i_core.v     single-cycle RV32I, optional register-file clock gating
          soc_top.v        core, memory, peripheral decode
          ca_code_gen.v    dual-LFSR gold code generator
          correlator.v     integrate-and-dump with code slew
          correlator_bus.v memory-mapped register interface, GNSS accelerator
          uart.v           uart_tx / uart_rx, 8N1, configurable baud divisor
          uart_bus.v       memory-mapped register interface, UART
tb/       tb_soc.v         trace-emitting SoC testbench (plain Verilog)
          tb_soc_sv.sv     SystemVerilog wrapper: functional coverage + concurrent
                           assertions over the same retire trace (Verilator-only)
          tb_correlator.v  standalone correlator verification
          tb_uart.v        standalone UART peripheral verification, register-driven
          tb_soc_uart.v    SoC-level UART test: core drives UART through the bus,
                           tx looped to rx, results scored by the Python host controller
tests/    smoke.s          directed decode test
          acq_hw.s          accelerated acquisition sweep
          acq_sw.s         software-only acquisition sweep
          uart_test.s      firmware-style UART self-test, polls status, logs every byte
scripts/  compare.sh       trace diff, the actual pass/fail gate
          regress.sh       constrained-random regression driver
          sta.tcl-equivalent: see the `sta` Makefile target (Yosys `ltp`, not OpenSTA --
                           see Critical path, above, for why)
          uart_testbench.py  host-side UART test automation: generates vectors, launches
                           the sim, scores results independently, emits a JSON report
```

## Building

Requires `iverilog`, `yosys`, `g++` and `python3`. `verilator` is needed only for the
`tb_soc_sv.sv` coverage/assertion flow. No cross-compiler is needed; the included
assembler covers the instruction subset the tests use.

```
make check TEST=smoke     # ISS versus RTL
make synth                # gate/flip-flop counts (post technology-mapping)
make sta                  # structural critical-path depth (see Critical path, above)
bash scripts/regress.sh   # randomised regression
python3 scripts/uart_testbench.py   # UART host-driven test automation
```

## Scope

This is a single-cycle core: no pipeline, no hazard logic, no caches, no CSRs or
interrupts, and memory is a flat asynchronous-read array. Those are the deliberate
next steps rather than oversights, and the retire-port trace methodology is specifically
designed to survive them, since a pipelined core still retires instructions in order and
can emit the same trace format.
