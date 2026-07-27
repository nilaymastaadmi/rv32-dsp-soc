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

# Every RTL source the SoC actually needs to elaborate. This was silently stale (only
# listed rv32i_core.v and soc_top.v) from before the correlator and UART were added --
# `make check` would have failed to elaborate rather than quietly testing less, but it's
# worth naming as a real staleness bug rather than something that was always correct.
RTL      := rtl/rv32i_core.v rtl/ca_code_gen.v rtl/correlator.v rtl/correlator_bus.v \
            rtl/uart.v rtl/uart_bus.v rtl/soc_top.v
TB       := tb/tb_soc.v
BUILD    := build
TEST     ?= smoke
MAXI     ?= 200000

.PHONY: all check iss hex sim clean synth sta tools

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

clean:
	rm -rf $(BUILD)
