#!/usr/bin/env bash
# Build krnl_namegen.xclbin for the Alveo U200.
#   1. prep self-contained RTL   2. package_xo (Vivado)   3. v++ link (-> xclbin)
#
# Requires a Vitis/XRT install with the U200 development platform. Run on Linux.
#
# Override via env:
#   PLATFORM  Vitis platform name      (default below; auto-detected if installed)
#   PART      FPGA part for packaging   (default xcu200 part)
#   TARGET    hw | hw_emu | sw_emu      (default hw)
#   NUM_GEN   generators per CU         (default 32; LUT-bound ~64)
#   NUM_CU    number of kernel instances/compute units (default 1; max 4 on U200,
#             one per DDR bank/SLR). >1 multiplies throughput across DDR/SLRs.
#   FREQ      target kernel clock MHz   (default 300)
#   BANK      DDR bank for the single-CU build (default DDR[1]); ignored when NUM_CU>1.
#
# Single CU (default):   ./alveo/build_xclbin.sh
# 4 CUs, 4 banks/SLRs:   NUM_CU=4 ./alveo/build_xclbin.sh
# Hardware emulation:    TARGET=hw_emu NUM_GEN=4 ./alveo/build_xclbin.sh
set -euo pipefail
cd "$(dirname "$0")"                       # -> alveo/

PLATFORM="${PLATFORM:-xilinx_u200_gen3x16_xdma_2_202110_1}"
PART="${PART:-xcu200-fsgd2104-2-e}"
TARGET="${TARGET:-hw}"
NUM_GEN="${NUM_GEN:-32}"
NUM_CU="${NUM_CU:-1}"
FREQ="${FREQ:-300}"
BANK="${BANK:-DDR[1]}"
BUILD="build"
mkdir -p "$BUILD"

command -v vivado >/dev/null || { echo "ERROR: vivado not on PATH (source Vitis settings64.sh)"; exit 1; }
command -v v++    >/dev/null || { echo "ERROR: v++ not on PATH (source Vitis settings64.sh)";    exit 1; }

case "$TARGET" in hw|hw_emu|sw_emu) ;; *) echo "ERROR: TARGET must be hw|hw_emu|sw_emu (got '$TARGET')"; exit 1;; esac
[[ "$NUM_CU" =~ ^[0-9]+$ ]] || { echo "ERROR: NUM_CU must be an integer (got '$NUM_CU')"; exit 1; }
if (( NUM_CU < 1 || NUM_CU > 4 )); then
    echo "ERROR: NUM_CU must be 1..4 (U200 has 4 DDR banks across 3 SLRs); got $NUM_CU"; exit 1
fi

# ---- platform auto-detect / validation -------------------------------------------------
# If the requested PLATFORM is not installed, fall back to the first U200 platform that is,
# so the build does not fail late inside v++ with an opaque message. Fail loudly if none.
if command -v platforminfo >/dev/null 2>&1; then
    if ! platforminfo --json "$PLATFORM" >/dev/null 2>&1 && ! platforminfo "$PLATFORM" >/dev/null 2>&1; then
        echo "WARN: platform '$PLATFORM' not found via platforminfo; searching installed U200 platforms..."
        AUTO="$(platforminfo -l 2>/dev/null | grep -oE 'xilinx_u200[a-z0-9_]*' | sort -u | head -n1 || true)"
        if [[ -n "$AUTO" ]]; then
            echo "INFO: using auto-detected platform: $AUTO"
            PLATFORM="$AUTO"
        else
            echo "ERROR: no installed U200 platform found. Available platforms:"
            platforminfo -l 2>/dev/null || true
            echo "Set PLATFORM=<name> to one of the above (or install the U200 dev platform)."
            exit 1
        fi
    else
        echo "INFO: platform '$PLATFORM' validated via platforminfo."
    fi
else
    echo "WARN: platforminfo not on PATH; skipping platform validation (proceeding with '$PLATFORM')."
fi

# reproducibility manifest (per the SHA-pinning workflow)
SHA="$(git -C .. rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "$BUILD/MANIFEST.txt" <<EOF
git_sha   $SHA
platform  $PLATFORM
part      $PART
target    $TARGET
num_gen   $NUM_GEN
num_cu    $NUM_CU
freq_mhz  $FREQ
bank      $BANK
EOF
echo "=== build manifest ==="; cat "$BUILD/MANIFEST.txt"; echo "======================"

# 1. self-contained RTL
python3 scripts/prep_sources.py

# 2. package RTL kernel -> .xo
vivado -mode batch -notrace -source package_kernel.tcl \
       -tclargs "$PART" "$NUM_GEN" "$BUILD/krnl_namegen.xo"

# 3. connectivity
# U200 DDR<->SLR map (xilinx_u200_gen3x16_xdma): DDR[0]=SLR0, DDR[1]=SLR1,
# DDR[2]=SLR1, DDR[3]=SLR2. We pin each CU's m_axi_gmem to a distinct bank and place
# the CU in the SLR that owns that bank, so the AXI master stays SLR-local (best timing,
# no inter-SLR crossing for the data path) and the four DDR controllers run in parallel.
DDR_FOR_CU=(DDR[0] DDR[1] DDR[2] DDR[3])
SLR_FOR_CU=(SLR0   SLR1   SLR1   SLR2)

{
    echo "[connectivity]"
    if (( NUM_CU == 1 )); then
        # single CU keeps the historical default: one instance on the chosen BANK.
        echo "nk=krnl_namegen:1:krnl_namegen_1"
        echo "sp=krnl_namegen_1.m_axi_gmem:$BANK"
    else
        echo "nk=krnl_namegen:${NUM_CU}"
        for ((i=1; i<=NUM_CU; i++)); do
            idx=$((i-1))
            echo "sp=krnl_namegen_${i}.m_axi_gmem:${DDR_FOR_CU[$idx]}"
            echo "slr=krnl_namegen_${i}:${SLR_FOR_CU[$idx]}"
        done
    fi
} > "$BUILD/link.cfg"

echo "=== link.cfg ==="; cat "$BUILD/link.cfg"; echo "================"

# 4. link -> xclbin
v++ -l -t "$TARGET" --platform "$PLATFORM" \
    --kernel_frequency "$FREQ" \
    --config "$BUILD/link.cfg" \
    --save-temps \
    -o "$BUILD/krnl_namegen.xclbin" "$BUILD/krnl_namegen.xo"

# 5. emulation config (hw_emu / sw_emu)
# v++ for an emulation target needs an emconfig.json describing the platform, and the
# runtime must see XCL_EMULATION_MODE set to the same target. Generate it next to the
# xclbin and remind the operator how to run.
if [[ "$TARGET" == "hw_emu" || "$TARGET" == "sw_emu" ]]; then
    if command -v emconfigutil >/dev/null 2>&1; then
        ( cd "$BUILD" && emconfigutil --platform "$PLATFORM" --nd 1 )
        echo "NOTE: emulation build. Before running the host, in the SAME shell do:"
        echo "        export XCL_EMULATION_MODE=$TARGET"
        echo "      and run the host from $BUILD (emconfig.json must be in the run dir),"
        echo "      pointing it at $BUILD/krnl_namegen.xclbin."
    else
        echo "WARN: emconfigutil not on PATH; emconfig.json not generated."
        echo "      Generate it manually: emconfigutil --platform $PLATFORM --nd 1"
        echo "      and export XCL_EMULATION_MODE=$TARGET before running the host."
    fi
fi

echo "DONE: $BUILD/krnl_namegen.xclbin  (sha=$SHA num_gen=$NUM_GEN num_cu=$NUM_CU target=$TARGET)"
