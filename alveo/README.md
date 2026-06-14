# gateGPT on Alveo U200

Run gateGPT's microGPT name generator on an **AMD/Xilinx Alveo U200** PCIe card as a
**Vitis RTL kernel**, driven from a Linux host over **XRT**. The inference `core/` RTL is
reused unchanged; this directory adds a PCIe wrapper and replicates the generator into a
**throughput farm** that streams name records back to host memory.

See [SPEC.md](SPEC.md) for the full design. TL;DR:

- The model is tiny (62 DSP, ~16.5k LUT, 2 BRAM per instance). The U200 has 6840 DSP and
  1.18M LUT, so we instantiate **`NUM_GEN` independent generators** (default 32) and run
  that many autoregressive streams at once.
- Each finished name becomes a **64-byte record** (`name`, `len`, `gen_id`, `seed`, `seq`,
  magic) written over a 512-bit AXI master to a DDR bank; the host reads it back via XRT.
- Generation is **chunked**: each kernel launch fills `n_records`, the host reads/decodes,
  and re-launches with a fresh seed. The result stream (~64–140 MB/s) is a rounding error
  against PCIe Gen3 x16 (~16 GB/s), so this *is* effectively continuous streaming.

| NUM_GEN | DSP | LUT | est. names/s @300 MHz |
|--:|--:|--:|--:|
| 8  | 7%  | 11% | ~0.27M |
| 32 | 29% | 45% | ~1.1M  |
| 48 | 43% | 67% | ~1.6M  |
| 64 | 58% | 90% | ~2.2M  |

## Requirements

- **Linux** (Ubuntu 20.04/22.04 or RHEL). Alveo XRT and the U200 deployment shell are
  Linux-only in practice — see *Windows* below.
- **Vitis + XRT** (2021.2 or newer recommended) and the **U200 development + deployment
  platforms** installed. Find your exact platform string with `platforminfo -l` and the
  card status with `xbutil examine`.
- For the local self-tests only: **Icarus Verilog** (`iverilog`). No FPGA tooling needed.

## 0. Validate the RTL locally (no card, no Vitis)

The reused core + the new farm/arbiter/FIFO/writer are checked bit-exactly in simulation:

```bash
cd alveo
make sim
```

- `tb_farm` — drives the farm, decodes records. **Greedy** mode is seed-independent and
  every name must be `alaya` (matches the Python golden in `tools/fixedpoint.py`); **sampled**
  mode (`+sample`) must produce varied valid names.
- `tb_kernel` — drives `s_axi_control` like XRT (the exact register map), models global
  memory as an AXI4 slave, and checks the 64-byte records, the `ap_ctrl_hs` handshake, and
  clean re-arm across two launches.

## 1. Build the xclbin (on the card host)

```bash
source /opt/xilinx/Vitis/2022.2/settings64.sh
source /opt/xilinx/xrt/setup.sh

cd alveo
PLATFORM=xilinx_u200_gen3x16_xdma_2_202110_1 NUM_GEN=32 FREQ=300 ./build_xclbin.sh
```

This runs `prep_sources.py` → `package_kernel.tcl` (RTL → `build/krnl_namegen.xo`) →
`v++ -l` (→ `build/krnl_namegen.xclbin`). A full `hw` place-and-route takes roughly an hour.

Knobs (env vars): `PLATFORM`, `PART` (default `xcu200-fsgd2104-2-e`), `TARGET`
(`hw`/`hw_emu`/`sw_emu`), `NUM_GEN`, `FREQ`, `BANK` (default `DDR[1]`).
`build/MANIFEST.txt` records the git SHA + settings for the run.

> Start bring-up with `NUM_GEN=2` (fast build) to confirm the end-to-end path, then scale up.

## 2. Build the host

```bash
cd alveo
make host          # cmake -> host/build/host  (needs XRT on PATH)
```

## 3. Run

```bash
# host <xclbin> [n_records] [iters] [temp] [sample] [seed]
./host/build/host build/krnl_namegen.xclbin 1048576 16 0.8 1 1
```

Example output:

```
config   : n_records=1048576/launch  iters=16  mode=sample  temp=0.800 (inv_temp=2560)
buffer   : 64.0 MiB in bank group_id=1
sample names:
  greslyn dakeella maran elika arren lyndie desis makin ...
names    : 16777216  (0 invalid)
RATE     : 1.14 M names/s,  7.0 M tokens/s
```

Or with the Python binding:

```bash
python3 host/run_namegen.py build/krnl_namegen.xclbin --records 1048576 --iters 16 --temp 0.8
python3 host/run_namegen.py build/krnl_namegen.xclbin --greedy        # -> all 'alaya'
```

## Record format (64 bytes, little-endian)

| offset | field | |
|--:|---|---|
| 0  | `name_len` (u8)  | valid chars, 0..16 |
| 1  | `gen_id` (u8)    | which generator |
| 2  | `magic` (u16)    | `0x4E47`, record-valid sentinel |
| 4  | `seed` (u32)     | seed used — content is reproducible from it |
| 8  | `name[16]` (u8)  | values 0..25 = `a`..`z` |
| 24 | `seq` (u64)      | global write index |
| 32 | pad |

## Tuning

- **`NUM_GEN`** — more parallel streams = more throughput, until LUT-bound (~64 on the U200).
  Baked at package time; rebuild the xclbin to change it.
- **`FREQ`** — UltraScale+ closes much higher than the original 80 MHz Virtex-5; 300 MHz is a
  safe default, push higher if timing allows.
- **`BANK`** — spread to other `DDR[n]` banks if you replicate the kernel (`nk=...:N`).

## Windows

Not supported for the U200. Alveo XRT and the data-center XDMA shell are Linux-only; Vitis
runs on Windows but cannot deploy/run on these cards there. Use a Linux host (a dual-boot or
a spare SSD is enough). The RTL and xclbin themselves are OS-independent.

## What changed vs. the board design

| Virtex-5 XUPV5 (`board/`) | Alveo U200 (`alveo/`) |
|---|---|
| 1 core, LCD + rotary I/O, DCM | `NUM_GEN` cores, PCIe/XRT, platform clock |
| ISE 14.7, `$readmemh` workarounds | Vitis/Vivado (handles them); ROMs reused as-is |
| absolute `/home/hermes` includes | `prep_sources.py` inlines them (self-contained) |
| ~60k tokens/s (one stream) | ~7M tokens/s (32 streams), streamed over PCIe |

Nothing under `core/` is modified — the original board flow still builds.
