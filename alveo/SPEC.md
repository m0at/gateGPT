# gateGPT on Alveo U200 — design spec

Port the existing `microgpt_core` / `name_generator` RTL (originally a Virtex-5 XUPV5
board design, ISE 14.7) onto an **AMD/Xilinx Alveo U200** PCIe accelerator as a
**Vitis RTL kernel**, run on a **Linux** desktop host via **XRT**.

## Goal

Generate names *stupid fast* and stream the results back to the host. The model is a
single-block char-level GPT (vocab 27, n_embed 24, context 16, Q5.11). One instance is
tiny: **62 DSP48, ~16.5k LUT, 2 BRAM36**. The U200 (XCU200) has **6840 DSP48E2,
~1.18M LUT, 2160 BRAM36 across 3 SLRs**. So we **replicate the whole generator N times**
and run N independent autoregressive streams in parallel.

## Why a farm (not a single fast core)

The decoder is autoregressive: token *t+1* depends on token *t* through the KV cache, so a
single stream is latency-bound (sequential). Throughput scales by **replication**, not by
widening one core. Each `name_generator` is fully independent (its own KV cache lives in its
own `vmem2` BRAM), so N copies need no interaction. PCIe is nowhere near the bottleneck:

| N | LUT (~16.5k ea) | DSP (62 ea) | est. names/s @300MHz | result rate (64B/rec) |
|---|---|---|---|---|
| 8  | ~132k (11%) | 496 (7%)  | ~0.27M | ~17 MB/s |
| 32 | ~528k (45%) | 1984 (29%)| ~1.1M  | ~70 MB/s |
| 48 | ~792k (67%) | 2976 (43%)| ~1.6M  | ~100 MB/s |
| 64 | ~1.06M (90%)| 3968 (58%)| ~2.2M  | ~140 MB/s |

PCIe Gen3 x16 is ~16 GB/s, so the result stream is <1% of link bandwidth at any N.
**Default `NUM_GEN = 32`** (comfortable place-and-route, easy routing across SLRs).
LUT-bound ceiling is ~64. Bring up at `NUM_GEN = 2` first to validate the flow.

## Port boundary

`board/name_generator.v` is the clean reuse boundary. It instantiates `microgpt_core` and
runs the autoregressive loop:

```
start, seed, inv_temp, sample_mode  ->  [name_generator]  ->  name_flat[16B], name_len, done
```

We instantiate `NUM_GEN` of these. Everything under `core/` is reused **unchanged** except
the hardcoded `/home/hermes/microgpt_fpga/...` include paths, which `scripts/prep_sources.py`
rewrites into a relocatable `alveo/gen_src/` tree (bare `\`include "file.vh"` + an include dir).
All ROMs are already baked combinational `case` functions (no `$readmemh`), so the weights and
microcode are carried over with zero regeneration and remain bit-exact to `tools/fixedpoint.py`.

## Block diagram

```
                      Alveo U200 (XDMA shell)
  +------------------------------------------------------------------+
  |  krnl_namegen (Vitis RTL kernel, ap_ctrl_hs)                     |
  |                                                                  |
  |  s_axi_control (AXI4-Lite) --- args: out_ptr,n_records,          |
  |        |                            base_seed,inv_temp,sample    |
  |        v                                                          |
  |   [control_s_axi] --ap_start--> [top FSM] --srst/start-->        |
  |                                       |                          |
  |                                       v                          |
  |   +-------------------- namegen_farm ----------------------+     |
  |   |  name_generator x NUM_GEN  (each: own microgpt_core,   |     |
  |   |  own KV-cache BRAM, own evolving seed)                 |     |
  |   |        | done -> per-gen holding reg                   |     |
  |   |        v   round-robin arbiter                         |     |
  |   |   [record_fifo]  (192-bit payload x DEPTH)             |     |
  |   +--------------------------|-----------------------------+     |
  |                              v                                   |
  |                       [axi_write_master] -- m_axi_gmem (512b) ---+--> DDR bank
  |                              | seq counter, 64B/record               (host BO)
  |                              v writer_done -> ap_done                 |
  +------------------------------------------------------------------+   |
                                                                         v
                                            Host (XRT): xrt::bo, sync, decode names
```

## Record format (64 bytes, one 512-bit AXI beat)

Little-endian in memory:

| offset | bytes | field | meaning |
|---|---|---|---|
| 0 | 1 | `name_len` | number of valid chars (0..16) |
| 1 | 1 | `gen_id`   | which generator produced it (0..NUM_GEN-1) |
| 2 | 2 | `magic`    | `0x4E47` ("GN" LE) — record-valid sentinel |
| 4 | 4 | `seed`     | uint32 seed actually used (content is reproducible from this) |
| 8 | 16| `name`     | chars as values 0..25 = 'a'..'z'; byte `0xFF` past `name_len` |
| 24| 8 | `seq`      | uint64 global record index (write order) |
| 32| 32| pad        | zero |

`name[k]` already stores `token-1` (the generator emits `core_tok-1`), so host maps
`'a' + name[k]` directly. Greedy mode (`sample_mode=0`) is seed-independent and every record
spells **`alaya`** (tokens `[1,12,1,25,1]`) — used as the deterministic self-test.

## Control register map (AXI4-Lite, must match `krnl_namegen.xml`)

| offset | reg |
|---|---|
| 0x00 | AP_CTRL (ap_start/ap_done/ap_idle/ap_ready, bit7 auto_restart) |
| 0x04 | GIE |
| 0x08 | IP_IER |
| 0x0C | IP_ISR |
| 0x10 | out_ptr[31:0] |
| 0x14 | out_ptr[63:32] |
| 0x1C | n_records[31:0] |
| 0x24 | base_seed[31:0] |
| 0x2C | inv_temp[31:0]  (used as signed Q5.11 [15:0]) |
| 0x34 | sample_mode[31:0] (0 greedy / 1 sample) |

Kernel arg order (XRT `set_arg` index): `0=out, 1=n_records, 2=base_seed, 3=inv_temp,
4=sample_mode`. Arg 0 is the `m_axi_gmem` pointer.

## Execution model (per launch — chunked streaming)

1. Host allocates a device BO of `n_records * 64` bytes in a DDR bank, sets args.
2. `ap_start` → top latches args, pulses `srst` (resets farm + flushes FIFO,
   re-seeds gen *i* to `base_seed ^ (i*0x9E3779B1)`), pulses `writer_start`.
3. Farm runs all NUM_GEN generators concurrently; each completed name is captured,
   its generator restarts with an LCG-advanced seed; arbiter drains into the FIFO.
4. `axi_write_master` pops the FIFO, formats a 64B record (adding `seq`), single-beat
   512-bit `m_axi` write to `out_ptr + seq*64`, until it has written `n_records`.
5. Writer asserts `writer_done` → top asserts `ap_done`/`ap_ready` → IDLE.
6. Host `sync(FROM_DEVICE)`, decodes records, repeats for continuous streaming.

Record *content* per `(gen_id, seed)` is fully deterministic; buffer *order* depends on
parallel completion timing — each record is self-describing (`gen_id`,`seed`,`seq`), so sort
by those for a reproducible view.

## Files

```
alveo/
  SPEC.md                         this file
  README.md                       build + run instructions
  Makefile                        prep -> xo -> xclbin -> host
  scripts/prep_sources.py         rewrite /home/hermes includes -> gen_src/
  rtl/
    krnl_namegen.v                kernel top (ap_ctrl_hs FSM)
    krnl_namegen_control_s_axi.v  AXI4-Lite control/register slave
    namegen_farm.v                NUM_GEN generators + arbiter + record FIFO
    axi_write_master.v            512-bit AXI4 write-only master (1 beat/record)
    record_fifo.v                 small synchronous FIFO
  krnl_namegen.xml                Vitis kernel description (arg offsets)
  package_kernel.tcl              package RTL -> krnl_namegen.xo
  build_xclbin.sh                 v++ link -> krnl_namegen.xclbin
  host/
    host.cpp                      XRT C++ host (decode + rate)
    CMakeLists.txt
    run_namegen.py                pyxrt host (convenience)
  sim/
    tb_farm.v                     xsim/iverilog farm+writer self-test (greedy -> 'alaya')
```

## Non-goals / future

- Free-running ring buffer with host-polled head pointer (continuous, no per-launch
  re-arm). Chunked launches are shipped instead — simpler, race-free, plenty fast.
- Burst-batching the AXI writer (1024B INCR bursts). Single-beat writes are shipped
  (provably correct, no 4KB-boundary math); DDR is not the bottleneck.
- QDMA host-streaming platform. The XDMA memory-mapped platform is targeted.
- **Shared weight ROM.** Each core bakes the weight/embedding ROMs as combinational `case`
  functions, so they replicate `NUM_GEN`× in LUTs — about half the per-core logic. The
  weights are identical across cores, so a single shared multi-read ROM (or a BRAM-backed
  weight store) would roughly halve LUT use and push the LUT-bound ceiling from ~64 toward
  ~100+ generators. Shipped design replicates (simplest, fits comfortably at NUM_GEN=32).
