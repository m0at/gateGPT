#!/usr/bin/env python3
"""pyxrt host for krnl_namegen on the Alveo U200 (convenience / quick checks).

  python3 run_namegen.py krnl_namegen.xclbin [--records N] [--iters K]
                         [--temp T] [--greedy] [--seed S]
                         [--cus N] [--buffers N] [--verify]

Decodes the 64-byte name records the kernel streams to device DDR and reports the rate.
Needs XRT's python bindings on PYTHONPATH (source /opt/xilinx/xrt/setup.sh).

Streaming is double-buffered (ping-pong): while the host syncs+decodes the chunk a CU just
filled, the next chunk is already running asynchronously into the other buffer, so there is no
stall between launches. Multiple CUs are driven concurrently (one pyxrt.kernel per CU) when the
xclbin packs them; rate is reported per-CU and aggregate.
"""
import argparse, os, sys, time
import numpy as np
import pyxrt

REC = np.dtype([
    ("len",  "u1"), ("gid", "u1"), ("magic", "u2"), ("seed", "u4"),
    ("name", "u1", 16), ("seq", "u8"), ("pad", "u1", 32),
])
assert REC.itemsize == 64, REC.itemsize
MAGIC = 0x4E47
SEED_DELTA = 0x9E3779B9
GEN_DELTA  = 0x9E3779B1   # per-generator seed offset baked into the RTL: base ^ (g*GEN_DELTA)


def make_kernels(dev, uuid, requested_cus):
    """Return a list of pyxrt.kernel, one per CU we will drive concurrently.

    Vitis names RTL-kernel CUs krnl_namegen_1, krnl_namegen_2, ... (1-based). Binding a kernel
    to a specific CU uses the "kernel:{cu}" syntax; the bare "krnl_namegen" binds to all CUs and
    lets XRT pick one per run (fine for single-CU)."""
    if requested_cus == 1:
        return [pyxrt.kernel(dev, uuid, "krnl_namegen")]
    kernels, limit = [], (64 if requested_cus == 0 else requested_cus)
    for n in range(1, limit + 1):
        try:
            kernels.append(pyxrt.kernel(dev, uuid, f"krnl_namegen:{{krnl_namegen_{n}}}"))
        except Exception:
            break
    if not kernels:
        kernels = [pyxrt.kernel(dev, uuid, "krnl_namegen")]
    if requested_cus > 0 and len(kernels) < requested_cus:
        print(f"NOTE: requested {requested_cus} CUs, found {len(kernels)} in xclbin")
    return kernels


def decode(rec):
    return "".join(chr(ord("a") + c) for c in rec["name"][:rec["len"]] if c < 26)


def run_verify(args, dev, uuid, inv_temp):
    """Launch one chunk and compare a few generators' first names to the Python golden."""
    sys.path.insert(0, os.environ.get("GATEGPT_TOOLS", "tools"))
    from model import ModelConfig
    from fixedpoint import QModel, generate
    sd = dict(np.load(os.path.join(os.environ.get("GATEGPT_TOOLS", "tools"), "weights.npz")))
    golden = QModel(sd, ModelConfig())

    krnl = pyxrt.kernel(dev, uuid, "krnl_namegen")
    n = min(args.records, 4096)
    nbytes = n * REC.itemsize
    bo = pyxrt.bo(dev, nbytes, pyxrt.bo.normal, krnl.group_id(0))
    base = args.seed & 0xFFFFFFFF
    greedy = args.greedy

    run = krnl(bo, n, base, inv_temp, 0 if greedy else 1)
    run.wait()
    bo.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
    arr = np.frombuffer(bo.read(nbytes, 0), dtype=REC, count=n)

    print(f"verify: base_seed={base:#x} mode={'greedy' if greedy else 'sample'} "
          f"temp={args.temp} inv_temp={inv_temp}")
    ok = True
    for g in range(4):
        seed_g = (base ^ ((g * GEN_DELTA) & 0xFFFFFFFF)) & 0xFFFFFFFF
        hit = arr[(arr["magic"] == MAGIC) & (arr["gid"] == g) & (arr["seed"] == seed_g)]
        hw = decode(hit[0]) if len(hit) else None
        _, gold = generate(golden, seed_g, inv_temp, greedy=greedy)
        mark = "OK" if hw == gold else ("<not found>" if hw is None else "MISMATCH")
        ok = ok and (hw == gold)
        print(f"  gen {g} seed={seed_g:#010x} golden={gold!r} hw={hw!r} {mark}")
    if greedy:
        assert all(decode(r) == "alaya" for r in arr[arr["magic"] == MAGIC][:64]), \
            "greedy must be 'alaya'"
        print("  greedy invariant: all names == 'alaya'  OK")
    print("PASS" if ok else "FAIL")
    return 0 if ok else 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xclbin")
    ap.add_argument("--records", type=int, default=1 << 20, help="records per launch")
    ap.add_argument("--iters",   type=int, default=16, help="number of timed launches")
    ap.add_argument("--temp",    type=float, default=0.8)
    ap.add_argument("--greedy",  action="store_true")
    ap.add_argument("--seed",    type=lambda s: int(s, 0), default=1)
    ap.add_argument("--cus",     type=int, default=1, help="CUs to drive (0=auto-detect all)")
    ap.add_argument("--buffers", type=int, default=2, help="ping-pong depth per CU (>=2 overlaps)")
    ap.add_argument("--verify",  action="store_true", help="check decoded names vs Python golden")
    ap.add_argument("--quiet",   action="store_true")
    args = ap.parse_args()

    sample   = 0 if args.greedy else 1
    inv_temp = int(2048.0 / max(args.temp, 0.05) + 0.5)
    nbytes   = args.records * REC.itemsize
    depth    = max(1, args.buffers)

    dev  = pyxrt.device(0)
    uuid = dev.load_xclbin(args.xclbin)

    if args.verify:
        sys.exit(run_verify(args, dev, uuid, inv_temp))

    kernels = make_kernels(dev, uuid, args.cus)
    ncu = len(kernels)

    # per-(CU, slot) buffers for ping-pong overlap
    bos   = [[pyxrt.bo(dev, nbytes, pyxrt.bo.normal, kernels[c].group_id(0))
              for _ in range(depth)] for c in range(ncu)]
    runs  = [[None] * depth for _ in range(ncu)]   # in-flight run handles
    seeds = [[0] * depth for _ in range(ncu)]

    print(f"xclbin   : {args.xclbin}")
    print(f"config   : records={args.records}/launch iters={args.iters} "
          f"mode={'greedy' if sample == 0 else 'sample'} temp={args.temp} inv_temp={inv_temp}")
    print(f"topology : {ncu} CU(s), {depth} buffer(s)/CU "
          f"({'ping-pong overlap' if depth >= 2 else 'no overlap (--buffers>=2)'})")
    print(f"buffer   : {nbytes/1048576:.1f} MiB/buf  bank group_id={kernels[0].group_id(0)}")

    base_seed = args.seed & 0xFFFFFFFF

    def next_seed():
        nonlocal base_seed
        base_seed = (base_seed + SEED_DELTA) & 0xFFFFFFFF
        return base_seed

    def start(c, b):
        seeds[c][b] = next_seed()
        runs[c][b] = kernels[c](bos[c][b], args.records, seeds[c][b], inv_temp, sample)

    # warm-up: one synchronous launch per CU, excluded from timing
    for c in range(ncu):
        r = kernels[c](bos[c][0], args.records, next_seed(), inv_temp, sample)
        r.wait()

    # prime every (CU, slot) so all are in flight before harvesting
    for c in range(ncu):
        for b in range(depth):
            start(c, b)

    cu_names   = [0] * ncu
    cu_tokens  = [0] * ncu
    cu_launch  = [0] * ncu
    bad = 0
    samples = []

    target = args.iters if args.iters > 0 else None
    deadline = time.perf_counter() + 5.0
    harvested = 0
    draining = False
    t0 = time.perf_counter()

    c = b = 0
    while True:
        if runs[c][b] is not None:
            runs[c][b].wait()
            bos[c][b].sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
            arr = np.frombuffer(bos[c][b].read(nbytes, 0), dtype=REC, count=args.records)
            runs[c][b] = None

            ok = (arr["magic"] == MAGIC) & (arr["len"] >= 1) & (arr["len"] <= 16)
            bad += int((~ok).sum())
            good = arr[ok]
            cu_names[c]  += int(good.shape[0])
            cu_tokens[c] += int(good["len"].astype(np.int64).sum())
            cu_launch[c] += 1
            harvested += 1
            if not args.quiet and len(samples) < 20:
                for r in good[:20 - len(samples)]:
                    samples.append(decode(r))

            more = (not draining) and (
                (harvested < target) if target is not None else (time.perf_counter() < deadline))
            if more:
                start(c, b)
            else:
                draining = True

        b += 1
        if b >= depth:
            b = 0
            c = (c + 1) % ncu

        if draining and not any(runs[cc][bb] is not None
                                for cc in range(ncu) for bb in range(depth)):
            break

    secs = time.perf_counter() - t0

    total_names  = sum(cu_names)
    total_tokens = sum(cu_tokens)
    total_launch = sum(cu_launch)
    rec_bytes = total_launch * args.records * REC.itemsize

    if not args.quiet:
        print("\nsample names:")
        for i in range(0, len(samples), 10):
            print("  " + " ".join(samples[i:i + 10]))

    print(f"\nlaunches : {total_launch}  ({ncu} warm-up excluded)")
    print(f"names    : {total_names}  ({bad} invalid)")
    print(f"elapsed  : {secs:.3f} s")
    if ncu > 1:
        print("per-CU   :")
        for cc in range(ncu):
            print(f"  CU{cc:<2d}   {cu_launch[cc]:6d} launches  "
                  f"{cu_names[cc]/secs/1e6:8.2f} M names/s  "
                  f"{cu_tokens[cc]/secs/1e6:8.2f} M tokens/s")
    print(f"RATE     : {total_names/secs/1e6:.2f} M names/s, "
          f"{total_tokens/secs/1e6:.2f} M tokens/s, {rec_bytes/secs/1e9:.2f} GB/s (records)")
    sys.exit(2 if bad else 0)


if __name__ == "__main__":
    main()
