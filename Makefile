# RV32I SoC build and verification flow.
#
# `make check TEST=smoke` runs the same program on the C++ ISS and on the RTL, then
# diffs the two traces. A clean diff is the pass criterion; nothing here depends on a
# human reading a waveform.

# Prefer a locally-extracted oss-cad-suite, fall back to whatever is on PATH.
OSS_BIN  := $(HOME)/tools/oss-cad-suite/bin
IVERILOG := $(shell if [ -x $(OSS_BIN)/iverilog ]; then echo $(OSS_BIN)/iverilog; else echo iverilog; fi)
VVP      := $(shell if [ -x $(OSS_BIN)/vvp ];      then echo $(OSS_BIN)/vvp;      else echo vvp;      fi)
YOSYS    := $(shell if [ -x $(OSS_BIN)/yosys ];    then echo $(OSS_BIN)/yosys;    else echo yosys;    fi)

CXX      := g++
CXXFLAGS := -O2 -Wall -Wextra -std=c++17

# ---- RISC-V cross toolchain, for the C firmware only ----
# Everything that existed before the NN firmware is still buildable with no cross-compiler
# at all -- model/asm.py covers the instruction subset the assembly tests use, and that
# property is deliberately preserved. Only the `nn*` targets below need this, and the
# generated .hex images are committed so a fresh clone can run the NN regression without
# installing a cross-compiler either.
XPACK    := $(HOME)/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin
RVGCC    := $(shell if [ -x $(XPACK)/riscv-none-elf-gcc ]; then echo $(XPACK)/riscv-none-elf-gcc; \
              elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then echo riscv-none-elf-gcc; \
              else echo riscv64-unknown-elf-gcc; fi)
RVOBJCOPY := $(patsubst %gcc,%objcopy,$(RVGCC))
RVOBJDUMP := $(patsubst %gcc,%objdump,$(RVGCC))

# -march=rv32i: base integer only, no M extension, which is the whole point -- if this ever
# gained 'm' the multiply cost this project measures would vanish into single instructions.
# -nostdlib and no -lgcc: an accidental `*` on an int becomes an undefined __mulsi3 at link
# time instead of silently pulling in a multiply routine that was never measured.
RVCFLAGS := -march=rv32i -mabi=ilp32 -Os -Wall -Wextra -std=c11 \
            -ffreestanding -nostdlib -fno-builtin -fomit-frame-pointer \
            -ffunction-sections -fdata-sections -Ifirmware
RVLDFLAGS := -T firmware/link.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments

# Every RTL source the SoC actually needs to elaborate. This was silently stale (only
# listed rv32i_core.v and soc_top.v) from before the correlator and UART were added --
# `make check` would have failed to elaborate rather than quietly testing less, but it's
# worth naming as a real staleness bug rather than something that was always correct.
# Adding the MAC accelerator to soc_top.v without adding it here reproduced this exact bug
# a second time: every target that elaborates the SoC failed with "Unknown module type:
# mac_bus", which at least fails loudly rather than testing less than it claims to. Any new
# rtl/ file instantiated by soc_top.v must be added to this list.
RTL      := rtl/rv32i_core.v rtl/ca_code_gen.v rtl/correlator.v rtl/correlator_bus.v \
            rtl/uart.v rtl/uart_bus.v rtl/mac.v rtl/mac_bus.v rtl/soc_top.v
TB       := tb/tb_soc.v
BUILD    := build
TEST     ?= smoke
MAXI     ?= 200000

NN_SRC   := firmware/nn_infer.c firmware/crt0.S
NN_DEPS  := $(NN_SRC) firmware/link.ld firmware/soc.h firmware/weights.h firmware/vectors.h
PREBUILT := firmware/prebuilt
PYNN     := $(shell if [ -x $(HOME)/.venvs/nn/bin/python ]; then echo $(HOME)/.venvs/nn/bin/python; else echo python3; fi)

.PHONY: all check iss hex sim sim-uart clean synth sta tools \
        nn nn-train nn-sim nn-check nn-measure nn-synth nn-images nn-prebuilt nn-sweep \
        regress test-all

all: check

$(BUILD):
	@mkdir -p $(BUILD)

# ---- golden reference model ----
iss: $(BUILD)/iss
$(BUILD)/iss: model/iss.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $<

# ---- assemble a test program ----
hex: $(BUILD)/$(TEST).hex
$(BUILD)/$(TEST).hex: tests/$(TEST).s model/asm.py | $(BUILD)
	python3 model/asm.py $< $@

# ---- elaborate the RTL ----
sim: $(BUILD)/sim
$(BUILD)/sim: $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) -g2005 -o $@ -s tb_soc $(RTL) $(TB)

# ---- SoC-level UART testbench ----
# scripts/uart_testbench.py has defaulted to --sim build/sim_soc_uart since the UART commit,
# but no target ever built it, so that whole verification flow could not be run from a clean
# checkout: the script died on a missing executable before it got as far as the RTL. Adding
# the target it was always looking for is the fix.
sim-uart: $(BUILD)/sim_soc_uart
$(BUILD)/sim_soc_uart: $(RTL) tb/tb_soc_uart.v | $(BUILD)
	$(IVERILOG) -g2005 -o $@ -s tb_soc_uart $(RTL) tb/tb_soc_uart.v

# ---- the actual verification step ----
check: $(BUILD)/iss $(BUILD)/$(TEST).hex $(BUILD)/sim
	@echo "=== ISS ==="
	@./$(BUILD)/iss $(BUILD)/$(TEST).hex $(BUILD)/$(TEST).iss.trace $(MAXI)
	@echo "=== RTL ==="
	@$(VVP) $(BUILD)/sim +hex=$(BUILD)/$(TEST).hex +trace=$(BUILD)/$(TEST).rtl.trace +max=$(MAXI)
	@echo "=== DIFF ==="
	@bash scripts/compare.sh $(BUILD)/$(TEST).iss.trace $(BUILD)/$(TEST).rtl.trace

# ---- gate count only (NOT timing -- see the `sta` target for that) ----
# This reports post-synthesis cell and flip-flop counts. It does not analyze timing:
# `stat` ran BEFORE the technology-mapping step in the previous version of this target,
# so it was reporting generic pre-map cell counts and never actually reporting anything
# about the mapped netlist `abc -g cmos` produced -- fixed by reordering.
synth: | $(BUILD)
	$(YOSYS) -p "read_verilog -defer rtl/rv32i_core.v; synth -top rv32i_core; abc -g cmos; stat" \
		2>&1 | tee $(BUILD)/synth.log | tail -40

# ---- structural critical-path depth (honest name: this is NOT calibrated ns timing) ----
# Real static timing analysis needs two things this environment doesn't have: the OpenSTA
# tool itself (no prebuilt binary exists; building from source needs Tcl dev headers,
# swig, and several other packages that require apt, which needs sudo this machine
# doesn't have configured) and a timing-characterized standard-cell library (a real
# .lib file), neither of which is available here. Reporting a nanosecond number without
# either would mean inventing it, so this target reports what Yosys's own `ltp` command
# can genuinely measure instead: the longest topological path through the synthesized
# netlist, in logic levels, naming the actual signals and source lines it passes through.
# That identifies which logic is structurally binding even without a calibrated time unit.
sta: | $(BUILD)
	@for m in rv32i_core correlator; do \
		echo "=== $$m ==="; \
		$(YOSYS) -p "read_verilog -defer $(RTL); hierarchy -check -top $$m; proc; opt; memory; opt; techmap; opt; ltp -noff" \
			2>&1 | tee $(BUILD)/sta_$$m.log | grep -A2 "Longest topological path"; \
	done

# ================================================================ NN edge inference
#
# Three firmware images are built from one source, differing only in a -D:
#   nn_sw    software shift-add multiply (the baseline being measured)
#   nn_mac   dot products issued to the memory-mapped MAC accelerator
#   nn_stub  multiply replaced by a single add, for profiling only -- see nn-measure
#
# Retrain (needs numpy; downloads MNIST to ~/.cache/mnist on first run). The generated
# headers and the reference vectors are committed, so this is only needed to change the
# model, not to build or verify it.
nn-train:
	$(PYNN) model/train_mlp.py firmware/weights.h $(PREBUILT)/nn_vectors.json firmware/vectors.h

# Pick the firmware images. Build from source when a RISC-V cross-compiler is present;
# otherwise fall back to the committed images under firmware/prebuilt/, so a fresh clone can
# run the whole NN regression with only the tools the README already required (iverilog,
# python3, g++) and no cross-compiler. Which path was taken is always printed, so a result is
# never ambiguous about what it was produced from.
nn-images: | $(BUILD)
	@if [ -x "$(RVGCC)" ] || command -v $(RVGCC) >/dev/null 2>&1; then \
		echo "nn-images: cross-compiler found, building firmware from source"; \
		$(MAKE) --no-print-directory $(BUILD)/nn_sw.hex $(BUILD)/nn_mac.hex $(BUILD)/nn_stub.hex; \
	else \
		echo "nn-images: no RISC-V cross-compiler, using committed $(PREBUILT)/nn_*.hex"; \
		cp $(PREBUILT)/nn_sw.hex $(PREBUILT)/nn_mac.hex $(PREBUILT)/nn_stub.hex $(BUILD)/; \
	fi

# Refresh the committed images from a source build. Run after changing the firmware or model.
nn-prebuilt: $(BUILD)/nn_sw.hex $(BUILD)/nn_mac.hex $(BUILD)/nn_stub.hex
	@mkdir -p $(PREBUILT)
	cp $(BUILD)/nn_sw.hex $(BUILD)/nn_mac.hex $(BUILD)/nn_stub.hex $(PREBUILT)/
	@echo "refreshed $(PREBUILT)/nn_*.hex"

# --- firmware images ---
# Keep the ELFs: make treats them as intermediates and would delete them, but they are what
# you disassemble to check what the compiler actually emitted for the inner loop.
.PRECIOUS: $(BUILD)/nn_%.elf

$(BUILD)/nn_%.elf: $(NN_DEPS) | $(BUILD)
	$(RVGCC) $(RVCFLAGS) $(NN_VARIANT_$*) $(RVLDFLAGS) -o $@ $(NN_SRC)
	@$(RVOBJDUMP) -h $@ | awk '/\.text|\.rodata|\.data|\.bss/ {printf "  %-10s %6s bytes\n", $$2, "0x" $$3}'
	@# Assert no multiply instruction and no libgcc multiply call slipped in. On rv32i a
	@# MUL would not even encode, but a call to __mulsi3 would link fine if -lgcc were ever
	@# added, and that would silently invalidate every cycle number this project reports.
	@if $(RVOBJDUMP) -d $@ | grep -qE '\b(mul|mulh|mulhu|mulhsu|div|divu|rem|remu)\b|__mulsi3|__divsi3'; then \
		echo "FATAL: $@ contains a multiply/divide instruction or libgcc call"; \
		$(RVOBJDUMP) -d $@ | grep -nE '\b(mul|div|rem)\b|__mulsi3' | head; exit 1; \
	else echo "  verified: no hardware multiply, no libgcc multiply call"; fi

NN_VARIANT_sw   :=
NN_VARIANT_mac  := -DUSE_MAC_ACCEL
NN_VARIANT_stub := -DMUL_STUB

$(BUILD)/nn_%.hex: $(BUILD)/nn_%.elf
	$(RVOBJCOPY) -O binary $< $(BUILD)/nn_$*.bin
	python3 scripts/bin2hex.py $(BUILD)/nn_$*.bin $@

# --- NN testbench: separate from tb_soc.v, the way tb_soc_uart.v is, because it has to
#     preload a vector count and read a logit block back out of memory afterwards ---
nn-sim: $(BUILD)/nn_sim
$(BUILD)/nn_sim: $(RTL) tb/tb_soc_nn.v | $(BUILD)
	$(IVERILOG) -g2005 -o $@ -s tb_soc_nn $(RTL) tb/tb_soc_nn.v

# --- bit-exactness: SoC logits versus the Python quantised reference ---
# Uses python3 rather than the numpy venv on purpose: the check itself needs no numpy, so it
# runs on a clone that never trained anything.
nn-check: nn-images $(BUILD)/nn_sim
	python3 scripts/nn_check.py

# --- cycle measurement and profile breakdown (needs numpy for the analytical model) ---
nn-measure: nn-images $(BUILD)/nn_sim
	$(PYNN) scripts/nn_measure.py

# --- synthesis of the new blocks ---
# Delegates to scripts/synth_stat.sh, which extracts post-abc counts correctly and
# self-calibrates against the figures already in the README. Reading them off the raw log by
# hand double-counts flip-flops on any hierarchical module; the script documents why.
nn-synth: | $(BUILD)
	@bash scripts/synth_stat.sh

# --- accuracy / latency / memory trade-off across hidden widths ---
# Retrains and rebuilds, so it needs numpy and a cross-compiler. It temporarily overwrites the
# generated headers and restores them in a finally block, verifying the restore with git.
nn-sweep: $(BUILD)/nn_sim
	$(PYNN) scripts/nn_sweep.py

nn: nn-check nn-measure

# --- everything, in the order a fresh clone should run it ---
# The NN bit-exactness check is deliberately NOT folded into `make check`: `check` is the fast
# trace-diff gate and should stay fast, while the software NN path is ~2.8M cycles and takes
# minutes. This target is the "run the whole verification suite" entry point instead.
#
# The UART firmware is assembled via a recursive call with TEST overridden rather than named
# as a prerequisite: the hex rule is `$(BUILD)/$(TEST).hex`, which only ever expands to the
# one test named on the command line, so `$(BUILD)/uart_test.hex` matches no rule at all
# unless TEST happens to be uart_test. A first version of this target had exactly that bug.
test-all: check regress sim-uart nn-check
	@$(MAKE) --no-print-directory hex TEST=uart_test
	@python3 scripts/uart_testbench.py --hex $(BUILD)/uart_test.hex
	@echo
	@echo "==================================================================="
	@echo "all verification flows completed -- see individual results above"
	@echo "==================================================================="

# Randomised regression, with its prerequisites made explicit so it cannot be run against a
# stale or missing simulator. SEEDS/BODY override the defaults.
SEEDS ?= 100
BODY  ?= 150
regress: $(BUILD)/sim $(BUILD)/iss
	bash scripts/regress.sh $(SEEDS) $(BODY)

clean:
	rm -rf $(BUILD)
