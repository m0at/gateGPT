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
CORE := $(wildcard $(GEN)/*.v)

.PHONY: sim sim-farm sim-kernel prep xo xclbin host clean

prep:
	python3 scripts/prep_sources.py

# ---- local simulation (Icarus Verilog) ----
sim: sim-farm sim-kernel

sim-farm: prep
	@mkdir -p build
	$(IVERILOG) -g2012 -o build/tb_farm -s tb_farm \
	  $(SIM)/tb_farm.v $(RTL)/record_fifo.v $(RTL)/namegen_farm.v $(CORE)
	@echo "== greedy =="  && $(VVP) build/tb_farm
	@echo "== sampled ==" && $(VVP) build/tb_farm +sample

sim-kernel: prep
	@mkdir -p build
	$(IVERILOG) -g2012 -o build/tb_kernel -s tb_kernel \
	  $(SIM)/tb_kernel.v $(RTL)/krnl_namegen.v $(RTL)/krnl_namegen_control_s_axi.v \
	  $(RTL)/namegen_farm.v $(RTL)/axi_write_master.v $(RTL)/record_fifo.v $(CORE)
	$(VVP) build/tb_kernel

# ---- hardware build (Vitis/XRT) ----
PART ?= xcu200-fsgd2104-2-e
xo: prep
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
