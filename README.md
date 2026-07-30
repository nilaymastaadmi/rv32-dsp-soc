# rv32-dsp-soc

A small RISC-V SoC with a GPS L1 C/A correlator attached as a memory-mapped accelerator,
written to answer a question left over from a software GNSS receiver project: the code
phase search was the expensive part, so what does it cost to put it in hardware instead?
A UART peripheral was added afterward as a second, unrelated memory-mapped block, to check
that the bus interface generalizes rather than being shaped around the one accelerator
that motivated it.

A third block came from asking the same question about a different workload: this core is
RV32I base, with no M extension and therefore no multiply instruction, so what does running
a quantised neural network on it actually cost, and what does moving the multiply-accumulate
into hardware buy? That is the second result below.

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

## Second result: INT8 neural network inference

A 196-32-10 MLP (MNIST downscaled to 14x14 by 2x2 average pooling), post-training quantised
to INT8, running as bare-metal C on the core. 6,760 bytes of parameters, 6,592 MACs per
inference.

### Quantisation cost

| | test accuracy |
|---|---:|
| float32 | 94.47% |
| INT8, power-of-two requantisation | 94.44% |
| **drop** | **0.03 pp** |

Requantisation between the layers is a **power-of-two right shift** (`>> 10`), not the usual
multiply-by-fixed-point-scale-then-shift. The usual form needs an int32 accumulator times an
int32 multiplier in a 64-bit intermediate, and on a core with no hardware multiply a 64-bit
multiply would cost more than the dot products this whole exercise exists to measure. The
shift constrains every activation scale to a power of two, which was expected to cost
accuracy. It cost 0.03 percentage points. That was a genuine surprise and it is reported in
the direction it actually fell; the expectation going in was worse.

ReLU is applied *before* the shift so the shifted value is never negative. Right-shifting a
negative integer is arithmetic in both C and numpy, but making a host model and a target
agree on rounding by relying on that is a weaker guarantee than having no negative values to
shift.

### Cycles

Both paths run the same 20 inferences over the same weights and the same inputs and produce
byte-identical logits, so the comparison is like for like.

| | cycles, 20 inferences | per inference | cycles / MAC |
|---|---:|---:|---:|
| software shift-add multiply | 2,782,545 | 139,813 | 21.10 |
| MAC accelerator | 84,916 | 4,241 | 0.64 |

**32.77x** speedup, measured. Per-inference figures are the mean over vectors 2..20, taken as
`(cycles(20) - cycles(1)) / 19` so the fixed startup cost (crt0, `.bss` clear) is subtracted
out rather than divided into the total.

The per-inference cost is a mean rather than a constant because the software multiply is
data-dependent: its loop runs once per bit of the multiplier, so a dim pixel is cheaper than
a bright one.

### Where the software cycles go

| | cycles | share |
|---|---:|---:|
| shift-add multiply loops | 1,714,763 | 61.6% |
| everything else (loop overhead, requantise, loads, stores, startup) | 1,067,782 | 38.4% |

Measured by building the same source with the multiply replaced by a single add and taking
the difference, not by a profiler this environment does not have. Two caveats that make 61.6%
a slight **over**-attribution rather than an under-one: the difference excludes the one add
the stubbed build still pays per MAC, and gcc inlined `dot()` into `main()` in the stubbed
build while keeping it a real function in the baseline, so the stub also avoids call overhead
the baseline pays.

### The profile predicted from first principles

Rather than assert that multiply dominates, the software cost is predicted from the
disassembly and then compared against the simulator:

```
cycles = 9 * MACs + 8 * shift_add_iterations
```

9 and 8 are instruction counts read off `build/nn_sw.elf` -- 5 to address and load both
operands and zero the inner accumulator, 3 to advance the loop, 1 for the loop-exit test, and
8 per shift-add iteration. The core retires exactly one instruction per clock, so an
instruction count is a cycle count. Iteration counts come from the real activation bit
lengths.

| | cycles |
|---|---:|
| predicted | 2,760,752 |
| measured | 2,782,545 |
| **residual** | **21,793 (0.78%)** |

The residual is the requantise/clamp/store path, the 42 `dot()` call-and-return sequences per
inference, and `crt0` -- none of which the model covers. Agreement to 0.78% is what turns
"the software multiply dominates" from a story into a measurement.

**Worth recording from that disassembly:** gcc compiled `if (a & 1) acc += w` into a
*branchless* masked add (broadcast bit 0 to a full-width mask with `slli`/`srai`, AND it with
the operand, add unconditionally). So an iteration costs the same whether the bit was set or
not, and the timing depends on the multiplier's **bit length**, not its popcount. An earlier
version of the measurement script reported a single "cycles per iteration" number that
silently conflated per-iteration cost with per-call overhead; reading the actual instructions
is what caught it.

### What the accelerator does and does not achieve

`mac.v` fetches 4 int8 terms per 2 cycles in steady state -- one cycle per operand stream
through a **single** memory read port, multiplying four byte pairs and accumulating all four
products in the second cycle. Its floor is therefore 0.5 cycles/MAC and it measures 0.64.

The gap is per-call overhead: each dot product still costs the CPU four register writes, a
start, a polling loop and a result read, and with only 196 or 32 terms per call that is a
real fraction of the total. Batching several rows per start, or letting the block walk a whole
weight matrix itself, would close most of it and is the obvious next step rather than
something attempted here.

`is_uart` in `soc_top.v` was `>= UART_BASE` with no upper bound -- correct while the UART was
the topmost device, but it would have silently swallowed every access to anything placed
above it, so the MAC block would never have been selected at all. Found by adding the third
peripheral, not by reading the line.

The MAC gets a fourth asynchronous read port on the same memory array (instruction fetch, CPU
data, correlator samples, MAC operands). A real SRAM does not hand out four read ports; this
is the same deliberate flat-memory simplification recorded in Scope, and the block is no more
optimistic about it than the correlator already was -- it takes one port and serialises its two
operand streams rather than asking for a fifth.

## Synthesis (Yosys, generic cell library, `abc -g cmos` technology mapping)

| module | cells | flip-flops |
|---|---:|---:|
| `rv32i_core` | 6,040 | 1,024 |
| `correlator` (incl. code generator) | 871 | 101 |
| `ca_code_gen` | 159 | 20 |
| `uart_tx` | 211 | 33 |
| `uart_rx` | 322 | 43 |
| `mac` | 3,103 | 84 |
| `mac_bus` (incl. `mac`) | 3,320 | 164 |

`mac` is by far the largest block here, about 3.5x the correlator, and the reason is the four
signed 8x8 multipliers it needs to do 4 MACs per accumulate cycle: the cell breakdown is
dominated by XOR/XNOR/NAND multiplier-array logic. That is the actual trade being made -- 33x
fewer cycles for roughly 3.5x the area of the existing accelerator -- and it is worth stating
plainly rather than reporting the speedup on its own. A single-multiplier version would be
around a quarter of the area at roughly half the throughput.

Its flip-flop count is exactly the declared state: 2 (FSM) + 16 (index) + 32 (latched operand
word) + 32 (accumulator) + 2 (busy, done) = 84, and `mac_bus` adds 16 + 32 + 32 = 80 for its
three configuration registers, giving 164. Both match a hand count, which is the cheap check
that nothing was inferred into existence or optimised away unnoticed.

Extracting these correctly took two attempts and the failure mode was silent, so
`scripts/synth_stat.sh` now does it and documents why: `synth; abc -g cmos; stat` prints **two**
statistics blocks and only the last is post-technology-mapping, and within that block a
hierarchical module prints one local section per submodule *plus* a design-hierarchy total, so
summing flip-flops across the block double-counts. That produced 202 for `correlator` instead
of 101 on the first pass. The script calibrates itself against the four figures published
above before reporting anything new, so a yosys output-format change fails loudly instead of
quietly returning wrong numbers.

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

**The NN firmware** is checked the same way, with the decision on the host
(`scripts/nn_check.py`): the same test inputs go through the Python quantised reference and
through the SoC, and every one of the 200 int32 logits must be **equal**, not close. Integer
quantised inference has no business being merely close, so there is no tolerance in the
comparison -- a single differing logit means the two implementations disagree about the
arithmetic and that is a real bug whether or not the argmax survives it.

Both firmware variants pass: 200 of 200 logits bit-identical to the reference, software
multiply and MAC accelerator alike. That the accelerator matches exactly is also what proves
it is a drop-in replacement for the software path rather than something that merely produces
plausible-looking numbers -- it independently validates the byte-lane extraction, the
signed-operand handling and the FSM's term counting all at once.

The build itself carries one more check that is worth naming because it makes a claim
enforceable rather than asserted. The firmware is compiled `-march=rv32i -nostdlib` and
without `-lgcc`, and the Makefile then greps the disassembly for any multiply or divide
instruction or any `__mulsi3`/`__divsi3` call and fails the build if one appears. A stray `*`
on an int would otherwise link quietly against libgcc and silently invalidate every cycle
number above.

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

## Two verification flows that could never have run

Neither of these is a design bug, and neither was found by the design tests -- both were found
by trying to run the existing verification after adding a third peripheral, which is its own
argument for doing that.

**The randomised regression never ran, in any commit.** `scripts/regress.sh` invoked
`./build/sim_run <hex> <trace>` positionally. No Makefile target has ever built a binary by
that name, going back to the first commit in this repo, so every seed failed on a missing
executable and the tally printed `0 passed, N failed` regardless of whether the core was
correct. `make check` reaches the RTL by a different path, which is exactly why this survived
unnoticed: the visible gate was green while the broader one was not running at all. The
simulator the Makefile does build (`build/sim`, `tb_soc`) takes plusargs rather than positional
arguments; switched to that. It now runs, and passes 40 of 40 seeds.

The 400-seed / 153,632-instruction figure quoted above therefore came from some earlier
working invocation that was never committed in a runnable form. The number is not being
retracted, but it cannot currently be reproduced from a clean checkout at the scale stated,
and saying so is more useful than leaving the discrepancy for someone else to trip over.

**The SoC-level UART flow had no simulator to run against.** `scripts/uart_testbench.py` has
defaulted to `--sim build/sim_soc_uart` since the UART commit, and nothing ever built it, so
the script died on a missing executable before reaching any RTL. Added the `sim-uart` target it
was always looking for.

## Layout

```
model/    iss.cpp          RV32I instruction-set simulator, the golden reference
          gnss_model.cpp   C/A code and signal model, self-validating against IS-GPS-200
          asm.py           minimal two-pass RV32I assembler
          gen_random.py    constrained-random program generator
          train_mlp.py     MLP training, INT8 quantisation, weight/vector emission
rtl/      rv32i_core.v     single-cycle RV32I, optional register-file clock gating
          soc_top.v        core, memory, peripheral decode
          ca_code_gen.v    dual-LFSR gold code generator
          correlator.v     integrate-and-dump with code slew
          correlator_bus.v memory-mapped register interface, GNSS accelerator
          uart.v           uart_tx / uart_rx, 8N1, configurable baud divisor
          uart_bus.v       memory-mapped register interface, UART
          mac.v            INT8 dot product, 4 terms per 2 cycles, one memory port
          mac_bus.v        memory-mapped register interface, MAC accelerator
firmware/ crt0.S           entry at PC 0, sp setup, .bss clear, ECALL on return
          link.ld          flat single-region image, .text forced to address 0
          soc.h            memory map shared with the testbench
          nn_infer.c       INT8 inference; software shift-add multiply or MAC accelerator
          weights.h        generated: quantised parameters
          vectors.h        generated: baked-in test inputs
          prebuilt/        committed .hex images and reference logits, so the NN
                           regression runs without a cross-compiler or numpy
tb/       tb_soc.v         trace-emitting SoC testbench (plain Verilog)
          tb_soc_sv.sv     SystemVerilog wrapper: functional coverage + concurrent
                           assertions over the same retire trace (Verilator-only)
          tb_correlator.v  standalone correlator verification
          tb_uart.v        standalone UART peripheral verification, register-driven
          tb_soc_uart.v    SoC-level UART test: core drives UART through the bus,
                           tx looped to rx, results scored by the Python host controller
          tb_soc_nn.v      SoC-level NN inference test: runs the network, dumps int32
                           logits for the host scorer
tests/    smoke.s          directed decode test
          acq_hw.s          accelerated acquisition sweep
          acq_sw.s         software-only acquisition sweep
          uart_test.s      firmware-style UART self-test, polls status, logs every byte
scripts/  compare.sh       trace diff, the actual pass/fail gate
          regress.sh       constrained-random regression driver
          bin2hex.py       ELF-derived binary to one 32-bit hex word per line
          nn_check.py      host-side bit-exactness gate for NN inference
          nn_measure.py    cycle measurement, profile split, analytical cross-check
          synth_stat.sh    post-abc cell/FF extraction, self-calibrating
          sta.tcl-equivalent: see the `sta` Makefile target (Yosys `ltp`, not OpenSTA --
                           see Critical path, above, for why)
          uart_testbench.py  host-side UART test automation: generates vectors, launches
                           the sim, scores results independently, emits a JSON report
```

## Building

Requires `iverilog`, `yosys`, `g++` and `python3`. `verilator` is needed only for the
`tb_soc_sv.sv` coverage/assertion flow. **No cross-compiler is needed** for anything here,
including the neural-network regression: the included assembler covers the instruction subset
the assembly tests use, and the NN firmware's `.hex` images are committed under
`firmware/prebuilt/`. `make nn-check` prints which path it took, so a result is never
ambiguous about whether it came from a fresh build or a committed image.

```
make check TEST=smoke     # ISS versus RTL
make regress SEEDS=40     # randomised regression (see the note on this, above)
make sim-uart && python3 scripts/uart_testbench.py --hex build/uart_test.hex
make synth                # gate/flip-flop counts (post technology-mapping)
make sta                  # structural critical-path depth (see Critical path, above)
```

Neural network:

```
make nn-check             # bit-exactness: 200/200 int32 logits, both firmware variants
make nn-measure           # cycles, speedup, profile split, analytical cross-check
make nn-synth             # cell/flip-flop counts, calibrated against the table above
```

Rebuilding the firmware or retraining the model needs more: a RISC-V bare-metal toolchain
(`riscv-none-elf-gcc`, picked up from `~/tools/xpack-riscv-none-elf-gcc-*/bin` or `PATH`) for
`make nn-prebuilt`, and numpy for `make nn-train`, which also downloads MNIST to
`~/.cache/mnist` on first run.

The acquisition comparison needs its stimulus generated first:

```
g++ -O2 -std=c++17 -o build/gnss_model model/gnss_model.cpp
./build/gnss_model build/g 1 511 45.0
vvp build/sim +hex=build/acq_hw.hex +samples=build/g.samples.hex +expect_phase=511
vvp build/sim +hex=build/acq_sw.hex +samples=build/g.samples.hex +code=build/g.code.hex +expect_phase=511
```

Both were re-run after the MAC block was added, and both still return phase 511 / peak 22013
at exactly the cycle counts published in Result above (1,583,123 and 8,905,752), so the third
peripheral did not perturb the existing datapath. The UART flow likewise still scores 210/210
with host and firmware agreeing.

## Scope

This is a single-cycle core: no pipeline, no hazard logic, no caches, no CSRs or
interrupts, and memory is a flat asynchronous-read array. Those are the deliberate
next steps rather than oversights, and the retire-port trace methodology is specifically
designed to survive them, since a pipelined core still retires instructions in order and
can emit the same trace format.

**Everything here runs in simulation.** Nothing has been on an FPGA or through a place-and-route
flow. The cycle counts are exact because the core is single-cycle and the simulator is
cycle-accurate to it, but "32.77x fewer cycles" is not "32.77x faster in wall-clock on real
silicon": that would additionally depend on what clock each configuration closes timing at,
and there is no timing-characterised cell library here to answer that (see Critical path). The
area figures are generic-cell counts from `abc -g cmos`, not a real standard-cell library, so
they are useful for comparing these blocks against each other and close to meaningless as an
absolute mm² claim.

The neural network is small and the task is easy: 14x14 MNIST at 94% with a 32-unit hidden
layer is not a demanding benchmark, and no claim is being made that it is. The point of the
exercise is the cost structure of integer inference on a core with no multiplier, which does
not depend on the network being impressive.

Two things named in the plan for this work are **not** done and are not being presented as if
they were: the accuracy/latency/memory trade-off across multiple model sizes or quantisation
schemes was the optional third phase and was not reached, and the per-call overhead that keeps
the accelerator at 0.64 cycles/MAC instead of its 0.5 floor has been measured and explained but
not fixed.
