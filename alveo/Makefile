# gateGPT on Alveo U200 — convenience targets.
#   make sim       run RTL self-tests locally (needs iverilog; no FPGA tooling)
#   make prep      generate self-contained RTL (alveo/gen_src/*.v)
#   make xclbin    full hardware build (needs Vitis/XRT; runs build_xclbin.sh)
#   make host      build the XRT C++ host (needs XRT)
#   make clean
#
# Hardware knobs pass straight through to build_xclbin.sh, e.g.
#   make xclbin NUM_GEN=48 PLATFORM=xilinx_u200_gen3x16_xdma_2_202110_1 FREQ=300

NUM_GEN ?= 32
IVERILOG ?= iverilog
VVP      ?= vvp

GEN  := gen_src
RTL  := rtl
SIM  := sim

# Core (reused, untouched) module list. These are the self-contained files that
# scripts/prep_sources.py emits into gen_src/. We list them EXPLICITLY rather than
# $(wildcard gen_src/*.v): on a clean tree gen_src/ does not exist yet, and a wildcard
# is expanded once at parse time -- before the `prep` prerequisite has run -- so the
# first `make sim` would link an empty core set and fail with "Unknown module type:
# name_generator". An explicit list is independent of parse-time directory state and
# keeps a clean `make sim` working first try. Must stay in sync with prep_sources.py
# (CORE_V + name_generator); `verify-core` below asserts that invariant.
CORE_MODULES := attn embed exp_unit grom isqrt matvec microgpt_core norm sampler \
                udiv vecop vmem vmem2 wrom name_generator
CORE := $(addprefix $(GEN)/,$(addsuffix .v,$(CORE_MODULES)))

.PHONY: sim sim-farm sim-kernel prep verify-core xo xclbin host clean

prep:
	python3 scripts/prep_sources.py

# Guard against the explicit CORE list silently drifting from prep_sources.py.
verify-core: prep
	@missing=""; for f in $(CORE); do [ -f "$$f" ] || missing="$$missing $$f"; done; \
	  if [ -n "$$missing" ]; then \
	    echo "ERROR: prep did not produce expected core files:$$missing"; \
	    echo "       (CORE_MODULES in Makefile is out of sync with scripts/prep_sources.py)"; \
	    exit 1; \
	  fi; \
	  echo "verify-core: all $(words $(CORE_MODULES)) core files present"

# ---- local simulation (Icarus Verilog) ----
sim: sim-farm sim-kernel

sim-farm: verify-core
	@mkdir -p build
	$(IVERILOG) -g2012 -o build/tb_farm -s tb_farm \
	  $(SIM)/tb_farm.v $(RTL)/record_fifo.v $(RTL)/namegen_farm.v $(CORE)
	@echo "== greedy =="  && $(VVP) build/tb_farm
	@echo "== sampled ==" && $(VVP) build/tb_farm +sample

sim-kernel: verify-core
	@mkdir -p build
	$(IVERILOG) -g2012 -o build/tb_kernel -s tb_kernel \
	  $(SIM)/tb_kernel.v $(RTL)/krnl_namegen.v $(RTL)/krnl_namegen_control_s_axi.v \
	  $(RTL)/namegen_farm.v $(RTL)/axi_write_master.v $(RTL)/record_fifo.v $(CORE)
	$(VVP) build/tb_kernel

# ---- hardware build (Vitis/XRT) ----
PART ?= xcu200-fsgd2104-2-e
xo: verify-core
	@mkdir -p build
	vivado -mode batch -notrace -source package_kernel.tcl \
	       -tclargs $(PART) $(NUM_GEN) build/krnl_namegen.xo

xclbin:
	NUM_GEN=$(NUM_GEN) ./build_xclbin.sh

host:
	cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release
	cmake --build host/build -j

clean:
	rm -rf build host/build gen_src
