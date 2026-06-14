#!/usr/bin/env python3
"""pyxrt host for krnl_namegen on the Alveo U200 (convenience / quick checks).

  python3 run_namegen.py krnl_namegen.xclbin [--records N] [--iters K]
                         [--temp T] [--greedy] [--seed S]

Decodes the 64-byte name records the kernel streams to device DDR and reports the rate.
Needs XRT's python bindings on PYTHONPATH (source /opt/xilinx/xrt/setup.sh).
"""
import argparse, time
import numpy as np
import pyxrt

REC = np.dtype([
    ("len",  "u1"), ("gid", "u1"), ("magic", "u2"), ("seed", "u4"),
    ("name", "u1", 16), ("seq", "u8"), ("pad", "u1", 32),
])
assert REC.itemsize == 64
MAGIC = 0x4E47


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xclbin")
    ap.add_argument("--records", type=int, default=1 << 20, help="records per launch")
    ap.add_argument("--iters",   type=int, default=16, help="number of launches")
    ap.add_argument("--temp",    type=float, default=0.8)
    ap.add_argument("--greedy",  action="store_true")
    ap.add_argument("--seed",    type=lambda s: int(s, 0), default=1)
    args = ap.parse_args()

    sample   = 0 if args.greedy else 1
    inv_temp = int(2048.0 / max(args.temp, 0.05) + 0.5)
    nbytes   = args.records * REC.itemsize

    dev  = pyxrt.device(0)
    uuid = dev.load_xclbin(args.xclbin)
    krnl = pyxrt.kernel(dev, uuid, "krnl_namegen")
    bo   = pyxrt.bo(dev, nbytes, pyxrt.bo.normal, krnl.group_id(0))

    print(f"xclbin   : {args.xclbin}")
    print(f"config   : records={args.records}/launch iters={args.iters} "
          f"mode={'greedy' if sample == 0 else 'sample'} temp={args.temp} inv_temp={inv_temp}")
    print(f"buffer   : {nbytes/1048576:.1f} MiB in bank group_id={krnl.group_id(0)}")

    base_seed = args.seed & 0xFFFFFFFF

    def launch(seed):
        run = krnl(bo, args.records, seed, inv_temp, sample)
        run.wait()
        bo.sync(pyxrt.xclBOSyncDirection.XCL_BO_SYNC_BO_FROM_DEVICE)
        return np.frombuffer(bo.read(nbytes, 0), dtype=REC, count=args.records)

    launch(base_seed)  # warm-up (untimed)

    total_names = total_tokens = bad = 0
    samples = []
    t0 = time.perf_counter()
    for _ in range(args.iters):
        base_seed = (base_seed + 0x9E3779B9) & 0xFFFFFFFF
        arr = launch(base_seed)
        ok = (arr["magic"] == MAGIC) & (arr["len"] >= 1) & (arr["len"] <= 16)
        bad += int((~ok).sum())
        good = arr[ok]
        total_names += int(good.shape[0])
        total_tokens += int(good["len"].astype(np.int64).sum())
        for r in good[:max(0, 20 - len(samples))]:
            samples.append("".join(chr(ord("a") + c) for c in r["name"][:r["len"]] if c < 26))
    secs = time.perf_counter() - t0

    print("\nsample names:")
    for i in range(0, len(samples), 10):
        print("  " + " ".join(samples[i:i + 10]))
    print(f"\nnames    : {total_names}  ({bad} invalid)")
    print(f"elapsed  : {secs:.3f} s")
    print(f"RATE     : {total_names/secs/1e6:.2f} M names/s, {total_tokens/secs/1e6:.2f} M tokens/s")


if __name__ == "__main__":
    main()
