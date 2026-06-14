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
| 8 | 16| `name`     | chars as values 0..25 = 'a'..'z' for `k < name_len`; bytes past `name_len` are the generator's raw `name_flat` residue (UNSPECIFIED — host MUST ignore them) |
| 24| 8 | `seq`      | uint64 global record index (write order) |
| 32| 32| pad        | not zeroed by the writer — UNSPECIFIED (host MUST ignore) |

> Correction: the shipped `axi_write_master` writes the generator's `name_flat[127:0]` and a
> seq field straight into the beat. It does **not** fill `name[k>=name_len]` with `0xFF`, and it
> does **not** zero the [256:511] pad region (those bits are constant `0` only because the writer
> happens to pad with zeros today — do not rely on it). The host already reads only
> `name[0..name_len-1]`, so this is correct, but any consumer that scans the full 16-byte name
> field or the pad must key off `name_len`, never a `0xFF`/zero sentinel.

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

## Does this actually meet the goal? — skeptical assessment

Goal restated: *generate names stupid-fast on a U200 and stream/chunk them back to a Linux
host, correctly and ready to build first-try.*

**What is genuinely proven (local Icarus sims, bit-exact):** the reused core is untouched and
greedy decodes to `alaya` matching the Python golden; the farm/arbiter/FIFO/writer move records
without loss, duplication, or seed collision under hard back-pressure; record *content* is
deterministic per `(gen_id, seed)` independent of buffer order; the AXI4-Lite register offsets,
`ap_ctrl_hs` handshake, AXI4 write protocol, single-launch beat count, and clean re-arm across
launches all hold against a stalling AXI slave. That is a strong logical foundation.

**What is NOT proven and gates "first-try":** *none of the hardware path is executed here.* There
is no Vitis/XRT on this machine, so `package_xo`, `v++ -l`, timing closure, the real XDMA shell
handshake, DDR behaviour, and on-card throughput are all **unvalidated**. The honest verdict:
the **RTL logic is very likely correct**; the **build/packaging/host integration is the real
risk** and should be treated as unproven until a `hw_emu` run and a first `NUM_GEN=2` on-card
bring-up pass. "Stupid-fast" is plausible from the resource math (PCIe is <1% utilised, so the
farm rate is the ceiling), but the **300 MHz target is an assumption** — the combinational
weight-ROM `case` functions are deep logic that may not close timing at NUM_GEN=32/300 MHz, and
the achievable clock is the single biggest unknown for the throughput claim.

## Risk register (what's unverified without hardware; likely failure modes)

| # | Risk | Severity | Why / evidence | Mitigation / who |
|---|---|---|---|---|
| R1 | **Auto-restart (`AP_CTRL[7]`) deadlocks.** A host launch with bit7 set runs once then hangs in `S_FIN` forever and never returns to IDLE. | High (if used) | `krnl_namegen.v` `S_FIN: if(!ap_start)`; control slave holds `ap_start` high while `auto_restart=1` (`int_ap_start<=int_auto_restart` on ready). The two fight → no 2nd run, no IDLE. `tb_kernel` launch 6 demonstrates it (non-fatal WARNING). | Don't set bit7 on the host (chunked re-launch instead). **Fix is Agent 1's** (top FSM must re-pulse `srst`/`run_en` on auto-restart). |
| R2 | **Timing closure at 300 MHz is assumed, not shown.** | High | Weight/embedding ROMs are deep combinational `case` funcs replicated NUM_GEN×; long carry/mux chains. No STA here. | Bring up at a conservative `FREQ` (e.g. 200 MHz), read the post-route WNS, then push up. Shared-ROM rework (Agent 3) also shortens these paths. |
| R3 | **Vitis packaging / connectivity first-build snags.** | High | `package_kernel.tcl` + `build_xclbin.sh` + `krnl_namegen.xml` are **never executed** (no Vitis here). `nk=`/`sp=` bank string, clock association, `sdx_kernel` props, arg offsets must all line up. | Run `TARGET=hw_emu` first; validate arg offsets against the XML (they currently match the control slave: out@0x10, n_records@0x1C, seed@0x24, itemp@0x2C, smode@0x34). Agent 4's domain. |
| R4 | **`srst` is a single-cycle synchronous reset to the cores.** | Medium | `namegen_farm` drives `ng_resetn = resetn & ~srst`; top pulses `srst` for exactly 1 cycle. If any `core/` sub-block (KV-cache `vmem2`, accumulators) needs a multi-cycle or async clear, a 1-cycle pulse may leave stale state on the *first* launch after configuration. Sims pass because they reset cleanly, but post-config power-on state on real silicon differs. | Confirm on-card that launch 1 after fresh program is bit-exact; if not, widen `srst`. Cross-cutting (Agent 1/3). |
| R5 | **Record `name[k>=len]` and pad bytes are unspecified residue** (NOT `0xFF`/zero — see Record format correction). | Low | `axi_write_master` writes raw `name_flat`+seq; no sentinel fill. | Host already reads only `name[0..len-1]`. Any new consumer must key off `name_len`. Doc fixed. |
| R6 | **Single-outstanding single-beat writer caps DMA at ~30M rec/s.** | Low (today) | `axi_write_master` is 1 outstanding, 1 beat/record by design. Far above the farm's ~2M rec/s, so not a bottleneck *now*. | Fine at shipped NUM_GEN. If Agent 2 adds bursts/multi-outstanding, **the 4 KB AXI boundary becomes a real correctness risk** — bursts must not cross 4 KB (64 records = 4 KB exactly, so batch ≤64 and keep `out_ptr` 4 KB-aligned). `tb_kernel`'s slave already models multi-outstanding (OSTD=8). |
| R7 | **Multi-CU / multi-SLR / multi-bank is unbuilt.** | Medium (for scale) | `build_xclbin.sh` ships `nk=krnl_namegen:1`. Scaling beyond one SLR's LUTs needs multiple CUs pinned to different DDR banks/SLRs, and the host must launch them concurrently. | Agent 4 (connectivity knob) + Agent 5 (concurrent runs). Until then, throughput is one-SLR-bound. |
| R8 | **Seed diversification quality on real corpora.** | Low | Per-gen seed = `base_seed ^ (g*0x9E3779B1)` then Weyl `+0x9E3779B9` per name. Sims show no collisions and good spread, but cross-launch (host re-seed) overlap isn't formally bounded. | Host should advance `base_seed` by a large odd stride per launch (not +1) to avoid inter-launch seed overlap. Agent 5. |
| R9 | **`make sim` proves logic, not the host round-trip.** | Medium | No XRT here; `host.cpp`/`run_namegen.py` are reasoned, not run. BO group_id, `sync(FROM_DEVICE)`, arg index order (`0=out…4=sample_mode`) are conventions, not tested. | `hw_emu` exercises the full host↔kernel path in software; add `--verify` (Agent 5) to check a few decoded names vs the Python golden. |

## First-build checklist (ordered — check the named thing at each step)

Do these **in order** on the Linux card host. Stop at the first failure; each step de-risks the next.

1. **Sanity the platform.** `xbutil examine` shows the U200 and a flashed shell; `platforminfo -l`
   lists your exact platform string. *Check:* the `PLATFORM=` in `build_xclbin.sh` matches a real
   installed platform (the default `xilinx_u200_gen3x16_xdma_2_202110_1` is a guess — correct it).
2. **Regenerate sources + run local sims.** `cd alveo && make sim`. *Check:* `FARM PASS` (greedy
   `alaya` + sampled variety + backpressure + determinism + length/charset spread) and `KERNEL
   PASS` (offsets, handshake, re-arm, backpressure no-loss/seq-ordered, `(gid,seed)` determinism).
   The auto-restart WARNING is expected (R1) — do **not** use bit7 until Agent 1 fixes it.
3. **Package the .xo at NUM_GEN=2.** `make xo NUM_GEN=2` (or let `build_xclbin.sh` do it). *Check:*
   `package_xo: wrote …krnl_namegen.xo`; no `ipx::check_integrity` errors; the kernel XML arg
   offsets in the packaged core match `krnl_namegen_control_s_axi.v`.
4. **Software/hardware emulation FIRST.** `TARGET=sw_emu` then `TARGET=hw_emu ./build_xclbin.sh
   NUM_GEN=2` and run the host against the emulated xclbin (`emconfigutil` generates `emconfig.json`;
   set `XCL_EMULATION_MODE`). *Check:* host loads the xclbin, allocates the BO in the right bank,
   `ap_start→ap_done` completes, decoded greedy names are all `alaya`, seq is contiguous `0..n-1`.
   This is the cheapest place to catch arg-offset, bank, and handshake mistakes (R3, R9).
5. **First real `hw` build at NUM_GEN=2, conservative clock.** `FREQ=200 NUM_GEN=2 TARGET=hw
   ./build_xclbin.sh`. *Check:* `v++` reports **timing met (WNS ≥ 0)**; note the achieved
   `kernel_frequency`. If WNS < 0, lower FREQ or reduce NUM_GEN before scaling (R2).
6. **On-card bring-up at NUM_GEN=2.** `./host/build/host build/krnl_namegen.xclbin 4096 1 0.0 0 1`
   (greedy, 1 launch). *Check:* every record decodes to `alaya`, `len=5`, `magic=0x4E47`,
   `gen_id<2`, seq `0..4095` contiguous, 0 invalid. This validates the *whole* path end-to-end and
   catches the single-cycle-`srst` first-launch risk (R4).
7. **Sampled correctness + `--verify`.** Run sampled (`temp=0.8 sample=1`) and verify a handful of
   `(seed)`-decoded names against `tools/fixedpoint.py`. *Check:* names are varied, valid (chars
   0..25, len 1..16), and bit-exact to the golden for fixed seeds (Agent 5's `--verify`).
8. **Scale NUM_GEN and push FREQ.** Rebuild at 16 → 32 (→48/64 if LUTs allow), raising FREQ while
   WNS ≥ 0. *Check:* throughput scales ~linearly with NUM_GEN until LUT-bound; rate reporting
   (names/s, tokens/s, GB/s) is sane and PCIe is far from saturated.
9. **Continuous streaming.** Run multi-launch (`iters>1`, ping-pong BOs from Agent 5). *Check:* no
   per-launch stall/gap, base_seed advances by a large odd stride between launches (R8), aggregate
   rate holds across launches.
10. **(Optional) multi-CU scale-out.** Once one CU is solid, enable `nk=krnl_namegen:N` with each
    `m_axi_gmem` pinned to a distinct `DDR[i]`/SLR (Agent 4) and concurrent host runs (Agent 5).
    *Check:* aggregate rate ≈ N× a single CU; each CU's records land in its own BO without aliasing.
