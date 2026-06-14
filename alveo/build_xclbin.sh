#!/usr/bin/env bash
# Build krnl_namegen.xclbin for the Alveo U200.
#   1. prep self-contained RTL   2. package_xo (Vivado)   3. v++ link (-> xclbin)
#
# Requires a Vitis/XRT install with the U200 development platform. Run on Linux.
#
# Override via env:
#   PLATFORM  Vitis platform name (default below; check: platforminfo -l)
#   PART      FPGA part for packaging (default xcu200 part)
#   TARGET    hw | hw_emu | sw_emu              (default hw)
#   NUM_GEN   number of parallel generators     (default 32; LUT-bound ~64)
#   FREQ      target kernel clock MHz           (default 300)
#   BANK      DDR bank for results              (default DDR[1])
#
#   ./alveo/build_xclbin.sh
set -euo pipefail
cd "$(dirname "$0")"                       # -> alveo/

PLATFORM="${PLATFORM:-xilinx_u200_gen3x16_xdma_2_202110_1}"
PART="${PART:-xcu200-fsgd2104-2-e}"
TARGET="${TARGET:-hw}"
NUM_GEN="${NUM_GEN:-32}"
FREQ="${FREQ:-300}"
BANK="${BANK:-DDR[1]}"
BUILD="build"
mkdir -p "$BUILD"

command -v vivado >/dev/null || { echo "ERROR: vivado not on PATH (source Vitis settings64.sh)"; exit 1; }
command -v v++    >/dev/null || { echo "ERROR: v++ not on PATH (source Vitis settings64.sh)";    exit 1; }

# reproducibility manifest (per the SHA-pinning workflow)
SHA="$(git -C .. rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "$BUILD/MANIFEST.txt" <<EOF
git_sha   $SHA
platform  $PLATFORM
part      $PART
target    $TARGET
num_gen   $NUM_GEN
freq_mhz  $FREQ
bank      $BANK
EOF
echo "=== build manifest ==="; cat "$BUILD/MANIFEST.txt"; echo "======================"

# 1. self-contained RTL
python3 scripts/prep_sources.py

# 2. package RTL kernel -> .xo
vivado -mode batch -notrace -source package_kernel.tcl \
       -tclargs "$PART" "$NUM_GEN" "$BUILD/krnl_namegen.xo"

# 3. connectivity: one kernel instance, m_axi_gmem -> chosen DDR bank
cat > "$BUILD/link.cfg" <<EOF
[connectivity]
nk=krnl_namegen:1:krnl_namegen_1
sp=krnl_namegen_1.m_axi_gmem:$BANK
EOF

# 4. link -> xclbin
v++ -l -t "$TARGET" --platform "$PLATFORM" \
    --kernel_frequency "$FREQ" \
    --config "$BUILD/link.cfg" \
    --save-temps \
    -o "$BUILD/krnl_namegen.xclbin" "$BUILD/krnl_namegen.xo"

echo "DONE: $BUILD/krnl_namegen.xclbin  (sha=$SHA num_gen=$NUM_GEN)"
