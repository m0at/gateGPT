# gateGPT U200 — review & improve swarm spec

Six agents, each in its own git worktree, each owning a **disjoint** set of files, each
improving one domain of the Alveo U200 port and keeping the local sims green. Work ONLY from
this spec; do not rely on outside context.

## What this is

`gateGPT` is a Verilog microGPT (Karpathy char-level name generator): 1 transformer block,
n_embed 24, 4 heads, context 16, vocab 27, **Q5.11 fixed point**, bit-exact to the Python
reference in `tools/fixedpoint.py`. The original target was a Virtex-5 XUPV5 board (ISE 14.7,
LCD/rotary, ~60k tok/s, single stream).

`alveo/` ports it to an **AMD/Xilinx Alveo U200** PCIe card as a **Vitis RTL kernel**. The
inference RTL under `core/` is reused UNCHANGED. The port replicates `name_generator` into a
**farm of `NUM_GEN` independent autoregressive streams** (default 32), each writing 64-byte
name records over a 512-bit AXI master to device DDR; an XRT host reads them back. Generation
is **chunked**: each launch fills `n_records`, host reads/decodes, re-launches with a fresh
seed.

**The goal:** generate names *as fast as the U200 allows* and stream/chunk them back to a
Linux host — correctly, and ready to build first-try. Reuse "the guys' stuff" (the gateGPT
core, untouched). Exploit "our superior card": **U200 = 6840 DSP48E2, ~1.18M LUT, 2160
BRAM36, 960 URAM across 3 SLRs, 4×16 GB DDR4 @77 GB/s, PCIe Gen3 x16 (~16 GB/s)**.

## Current validated state (your baseline, already passing)

`cd alveo && make sim` runs three Icarus Verilog self-tests, all PASS:
- `tb_farm` greedy → every record is bit-exact **`alaya`** (matches the Python golden).
- `tb_farm +sample` (T=0.7) → varied valid names (e.g. makin, dalaina, shairah).
- `tb_kernel` → exact control-register offsets, `ap_ctrl_hs` handshake, AXI4 DMA, 64-byte
  record layout, clean re-arm across 2 launches, exactly `n_records` beats/launch.

`iverilog`/`vvp` are installed on this machine. `python3` works. There is NO Vitis/XRT and NO
FPGA here — you cannot run `v++`, `vivado`, or on-card; reason from canonical Vitis/XRT
conventions and keep the Icarus sims green.

## Record format (64 bytes, little-endian) — DO NOT change without updating host + benches

| off | field | | off | field |
|--:|---|---|--:|---|
| 0 | name_len u8 | | 8  | name[16] u8 (0..25='a'..'z') |
| 1 | gen_id u8   | | 24 | seq u64 |
| 2 | magic u16 `0x4E47` | | 32 | pad |
| 4 | seed u32 | | | |

## Hard rules for every agent

1. **Edit ONLY the files your section lists.** Touching another agent's files breaks the
   clean merge. If you believe a change is needed outside your set, put it in your report as
   a recommendation, do not make it.
2. **NEVER change a module's PORT LIST** (names/widths/direction). Internals only. The top
   `krnl_namegen.v` wires modules by their current ports; changing ports breaks integration.
   (Agent 1 owns the top and may add *internal* logic, but keep sub-module instantiations
   compatible with their current ports.)
3. **Do NOT touch** `core/`, `alveo/gen_src/`, `alveo/scripts/prep_sources.py`, or anything
   under `board/`/`tools/`. The reused core stays bit-exact and untouched.
4. **Keep the sims green.** Run the relevant `make sim-*` (or full `make sim`) before you
   finish; if you add a benchmark/feature, extend the bench to cover it. Greedy MUST still be
   `alaya`. If you cannot keep it green, revert that change and report it instead.
5. **No fallbacks / no fakery.** Per project rule: things must fail loudly if wrong, not
   silently degrade. No speculative code you cannot validate.
6. **Stay in your worktree directory** (given in your prompt). Commit your changes there with
   `git add -A alveo && git commit -m "..."` (no Co-Authored-By trailer — author is m0at).
7. **Return a concise report**: what you changed and why, measured/expected impact, what you
   could NOT verify (needs Vitis/hardware), and any risks or cross-agent dependencies.

## Agent domains (disjoint file ownership)

### Agent 1 — RTL correctness & UltraScale+ synthesis hardening
Own: `alveo/rtl/krnl_namegen.v`, `alveo/rtl/krnl_namegen_control_s_axi.v`.
Targets: audit the `ap_ctrl_hs` control slave + top FSM against the canonical Vitis RTL-kernel
behavior XRT expects (ap_start/done/idle/ready/auto_restart, interrupt, ISR toggle-on-write,
read-clear of done). Verify reset/clock usage, no inferred latches, no multi-driver, no
unintended FF inference, correct widths. Confirm a single launch produces exactly one run and
re-arm is clean (the bench already checks beats — keep it). Fix anything that would fail
synthesis or mis-handshake on hardware. Keep `make sim-kernel` green.

### Agent 2 — DMA / AXI write-path throughput
Own: `alveo/rtl/axi_write_master.v`, `alveo/rtl/record_fifo.v`.
Targets: the current writer is single-beat, one-outstanding (correct but conservative). Make
it faster while staying provably correct: support **multiple outstanding** writes and/or
**burst-batching** several 64-byte records per AXI INCR burst (respect the 4 KB boundary —
host BOs are page-aligned; keep bursts aligned so they never cross 4 KB). Consider widening
the FIFO/decoupling. Must remain bit-correct: exactly `n_records` records land at
`out_ptr + seq*64`, seq contiguous 0..n-1. Update `tb_kernel`'s slave model in your report if
it needs to model multiple-outstanding (but tb_kernel.v is Agent 6's file — coordinate via
report; keep the CURRENT single-outstanding slave passing). Keep `make sim-kernel` green.

### Agent 3 — Farm scaling & U200 exploitation
Own: `alveo/rtl/namegen_farm.v`.
Targets: review the round-robin arbiter for fairness, record loss under backpressure, and
throughput (can it drain >1 record/cycle, or is 1/cycle fine given the writer?). Verify seed
diversification has no cross-generator collisions and good variety. Improve resource/timing of
the per-generator FSM. MOST IMPORTANT: write a concrete, correct design (in your report, plus
a stub/scaffold module if safe) for a **shared weight ROM** — the weight/embedding ROMs are
baked as combinational `case` functions and replicate `NUM_GEN`× in LUTs (~half the per-core
logic); sharing one multi-read weight source across cores is the key lever to push `NUM_GEN`
from ~64 toward ~100+. Do not break bit-exactness or `core/`. Keep `make sim-farm` green.

### Agent 4 — Vitis packaging & build flow
Own: `alveo/package_kernel.tcl`, `alveo/build_xclbin.sh`, `alveo/krnl_namegen.xml`,
`alveo/Makefile`.
Targets: this is the UNTESTED, highest-risk part. Validate against real Vitis 2022.x RTL-kernel
packaging conventions: the `ipx::package_project` → `package_xo` sequence, clock/reset
association, `sdx_kernel` props, kernel.xml arg offsets (must match
`krnl_namegen_control_s_axi.v`: out@0x10, n_records@0x1C, base_seed@0x24, inv_temp@0x2C,
sample_mode@0x34), and the `v++ -l` connectivity. Add: platform auto-detect/validation,
`hw_emu` support (emconfigutil note), and **multi-instance + multi-SLR/multi-bank**
connectivity (`nk=krnl_namegen:N` with each instance's `m_axi_gmem` pinned to a different
`DDR[i]`/SLR) to multiply throughput — gate it behind a knob. Be explicit in your report about
what cannot be verified without Vitis and where the likely first-build snags are.

### Agent 5 — Host & XRT streaming
Own: `alveo/host/host.cpp`, `alveo/host/run_namegen.py`, `alveo/host/CMakeLists.txt`.
Targets: make streaming genuinely continuous and fast: **double-buffered / ping-pong** BOs and
async runs so the kernel computes the next chunk while the host reads/decodes the previous
(overlap, no stalls). Support **multiple kernel instances** (CU) launched concurrently if
Agent 4 enables them. Verify correct XRT native API usage (xrt::device/kernel/bo,
group_id(0), sync FROM_DEVICE, run.start/wait). Add an optional `--verify` path that checks a
handful of decoded names against the Python golden (`tools/fixedpoint.py`) for given seeds.
Robust, accurate rate reporting (names/s, tokens/s, GB/s). Keep it compiling conceptually
against XRT (no XRT here, so reason carefully; keep includes/links correct).

### Agent 6 — Verification depth + cross-cutting review & docs
Own: `alveo/sim/tb_farm.v`, `alveo/sim/tb_kernel.v`, `alveo/SPEC.md`, `alveo/README.md`.
Targets: strengthen the benches — add **backpressure** (a slow/randomly-stalling AXI slave),
**FIFO-full** stress, multi-launch **determinism** (same seed+mode ⇒ same record content
regardless of order), and a name-length/charset distribution sanity check. Keep greedy=`alaya`.
Then do a hard, skeptical end-to-end review of whether the design actually meets the goal,
and write a concise **risk register** + first-build checklist into SPEC.md/README.md. Keep
`make sim` green (your benches are the gate the other agents rely on — make them stricter, not
flakier).

## Integration

Each agent commits to its own worktree branch. The orchestrator reviews all six diffs, copies
the disjoint changed files into the main `alveo-u200` branch, runs the full `make sim`, and
resolves any port-level inconsistencies. Anything that breaks the sims is dropped.
