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

RTL      := rtl/rv32i_core.v rtl/soc_top.v
TB       := tb/tb_soc.v
BUILD    := build
TEST     ?= smoke
MAXI     ?= 200000

.PHONY: all check iss hex sim clean synth tools

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

# ---- gate count and critical path ----
synth: | $(BUILD)
	$(YOSYS) -p "read_verilog -defer rtl/rv32i_core.v; synth -top rv32i_core; stat; abc -g cmos" \
		2>&1 | tee $(BUILD)/synth.log | tail -40

clean:
	rm -rf $(BUILD)
