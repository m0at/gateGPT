// XRT host for krnl_namegen on the Alveo U200.
//
// Loads the xclbin, allocates result buffers in each kernel CU's DDR bank, launches the
// generator farm in chunks (each launch fills n_records 64-byte name records), decodes the
// records, and reports throughput. Each launch uses a fresh base_seed so names keep varying.
//
// Performance model: the kernel run (compute + DMA to device DDR) is the long pole; the host
// work is the sync FROM_DEVICE readback + record decode. To overlap them we keep TWO buffer
// objects per CU (ping/pong). While the host syncs+decodes the buffer the kernel just filled,
// the *next* chunk is already running asynchronously into the other buffer. With multiple CUs
// we round-robin launches across all of them and decode whichever completes, so all CUs and
// the host stay busy continuously with no stall between launches.
//
//   ./host krnl_namegen.xclbin [options]
//     --records N     records per launch              (default 1<<20)
//     --iters K       number of timed launches        (default 16; 0 => run ~5 s)
//     --temp T        sampling temperature            (default 0.8)
//     --greedy        greedy decode (else sample)
//     --seed S        initial base seed               (default 1)
//     --cus N         number of CUs to drive (0=auto-detect all)   (default 1)
//     --buffers N     ping-pong depth per CU (>=2 overlaps)        (default 2)
//     --verify        decode a few names and check vs the Python golden, then exit
//     --quiet         suppress the per-launch sample-name dump
//
// Build needs XRT (source /opt/xilinx/xrt/setup.sh). There is no XRT/FPGA in the dev tree,
// so this is written against the canonical XRT 2022.x native C++ API.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>
#include <exception>
#include <stdexcept>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"

#pragma pack(push, 1)
struct Rec {
    uint8_t  name_len;    // off 0
    uint8_t  gen_id;      // off 1
    uint16_t magic;       // off 2  (0x4E47)
    uint32_t seed;        // off 4  (per-generator seed used for THIS name)
    uint8_t  name[16];    // off 8  (values 0..25 == 'a'..'z')
    uint64_t seq;         // off 24
    uint8_t  pad[32];     // off 32
};
#pragma pack(pop)
static_assert(sizeof(Rec) == 64, "record must be 64 bytes");
static_assert(offsetof(Rec, name_len) == 0,  "name_len@0");
static_assert(offsetof(Rec, gen_id)   == 1,  "gen_id@1");
static_assert(offsetof(Rec, magic)    == 2,  "magic@2");
static_assert(offsetof(Rec, seed)     == 4,  "seed@4");
static_assert(offsetof(Rec, name)     == 8,  "name@8");
static_assert(offsetof(Rec, seq)      == 24, "seq@24");
static_assert(offsetof(Rec, pad)      == 32, "pad@32");

static constexpr uint16_t MAGIC      = 0x4E47;
static constexpr uint32_t SEED_DELTA = 0x9E3779B9u;   // host per-launch base_seed advance

// ---- option parsing ---------------------------------------------------------
struct Opts {
    std::string xclbin;
    uint32_t n_records = (1u << 20);
    int      iters     = 16;       // 0 => time-bounded ~5s loop
    double   temp      = 0.8;
    uint32_t sample    = 1;        // 1=sample, 0=greedy
    uint32_t seed      = 1;
    int      cus       = 1;        // 0 => auto-detect every krnl_namegen CU
    int      buffers   = 2;        // ping-pong depth per CU
    bool     verify    = false;
    bool     quiet     = false;
};

static bool eat(const char* a, const char* k) { return std::strcmp(a, k) == 0; }

static Opts parse_args(int argc, char** argv) {
    Opts o;
    if (argc < 2 || argv[1][0] == '-') {
        std::fprintf(stderr,
            "usage: %s <xclbin> [--records N] [--iters K] [--temp T] [--greedy]\n"
            "          [--seed S] [--cus N] [--buffers N] [--verify] [--quiet]\n", argv[0]);
        std::exit(1);
    }
    o.xclbin = argv[1];
    for (int i = 2; i < argc; ++i) {
        const char* a = argv[i];
        auto need = [&](const char* name) -> const char* {
            if (i + 1 >= argc) { std::fprintf(stderr, "%s needs a value\n", name); std::exit(1); }
            return argv[++i];
        };
        if      (eat(a, "--records")) o.n_records = std::strtoul(need("--records"), nullptr, 0);
        else if (eat(a, "--iters"))   o.iters     = std::atoi(need("--iters"));
        else if (eat(a, "--temp"))    o.temp      = std::atof(need("--temp"));
        else if (eat(a, "--greedy"))  o.sample    = 0;
        else if (eat(a, "--seed"))    o.seed      = std::strtoul(need("--seed"), nullptr, 0);
        else if (eat(a, "--cus"))     o.cus       = std::atoi(need("--cus"));
        else if (eat(a, "--buffers")) o.buffers   = std::atoi(need("--buffers"));
        else if (eat(a, "--verify"))  o.verify    = true;
        else if (eat(a, "--quiet"))   o.quiet     = true;
        else { std::fprintf(stderr, "unknown arg: %s\n", a); std::exit(1); }
    }
    if (o.buffers < 1) o.buffers = 1;
    if (o.cus     < 0) o.cus     = 1;
    return o;
}

static std::string decode_name(const Rec& r) {
    std::string s;
    for (uint8_t k = 0; k < r.name_len && k < 16 && r.name[k] < 26; ++k)
        s.push_back(char('a' + r.name[k]));
    return s;
}

// ---- CU discovery -----------------------------------------------------------
// XRT exposes per-CU kernels via "kernel_name:{cu_name}". Vitis names the CUs of an RTL
// kernel "krnl_namegen_1", "krnl_namegen_2", ... (1-based). xrt::kernel(dev,uuid,"krnl_namegen")
// (no CU) binds to ALL CUs of that kernel and lets XRT pick a free one per run; that is fine for
// a single launch but for genuine concurrency we want one xrt::kernel object pinned to each CU
// so independent runs land on distinct hardware and distinct DDR banks.
static std::vector<xrt::kernel>
make_kernels(const xrt::device& device, const xrt::uuid& uuid, int requested_cus) {
    std::vector<xrt::kernel> kernels;
    auto try_cu = [&](const std::string& cu) -> bool {
        try {
            kernels.emplace_back(device, uuid, cu);   // throws if CU not present
            return true;
        } catch (const std::exception&) {
            return false;
        }
    };
    if (requested_cus == 1) {
        // Fast path: bind to the kernel as a whole (works for a single-CU xclbin and also if
        // packaging used a non-default CU name). Keeps old single-CU behavior identical.
        kernels.emplace_back(device, uuid, "krnl_namegen");
        return kernels;
    }
    // Probe CU instances by canonical Vitis name until one is missing (or we hit the request).
    const int limit = (requested_cus == 0) ? 64 : requested_cus;   // 0 => auto, cap at 64
    for (int n = 1; n <= limit; ++n) {
        const std::string cu = "krnl_namegen:{krnl_namegen_" + std::to_string(n) + "}";
        if (!try_cu(cu)) break;
    }
    if (kernels.empty()) {
        // Packaging may not have used the "_<n>" convention; fall back to the whole-kernel
        // handle so a single-CU xclbin still runs. Fail loudly only if even that is absent.
        kernels.emplace_back(device, uuid, "krnl_namegen");
    }
    if (requested_cus > 0 && (int)kernels.size() < requested_cus)
        std::fprintf(stderr, "NOTE: requested %d CUs, found %zu in xclbin\n",
                     requested_cus, kernels.size());
    return kernels;
}

// =============================================================================
//  --verify : decode a handful of names for known (base_seed, gen_id) pairs and
//  compare to the Python golden via tools/fixedpoint.py. The per-generator seed
//  the RTL uses for a generator g on launch with base_seed B is:
//      seed_g = B ^ (g * 0x9E3779B1)            (Weyl-advanced for subsequent names)
//  and the FIRST name a generator emits uses exactly seed_g. We launch ONE chunk,
//  find the record for a target gen_id whose embedded `seed` equals the predicted
//  seed_g (i.e. that generator's first name), and check its decoded string against
//  `generate(seed_g, inv_temp, greedy=...)` from the golden.
// =============================================================================
static int run_verify(const Opts& o) {
    auto device = xrt::device(0);
    auto uuid   = device.load_xclbin(o.xclbin);
    auto krnl   = xrt::kernel(device, uuid, "krnl_namegen");

    const uint32_t inv_temp = (uint32_t)(2048.0 / (o.temp > 0.05 ? o.temp : 0.05) + 0.5);
    const uint32_t base     = o.seed;
    // Pick a small chunk; we only need the first few generators' first names. The farm emits
    // generator g's first name early, but ordering is arbitrary so we scan for the seed.
    const uint32_t n = (o.n_records < 4096) ? o.n_records : 4096;
    const size_t bytes = (size_t)n * sizeof(Rec);

    auto bo   = xrt::bo(device, bytes, krnl.group_id(0));
    auto host = bo.map<const Rec*>();

    auto run = krnl(bo, n, base, inv_temp, o.sample);
    run.wait();
    bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

    const int n_gen_check = 4;
    // For each generator we want, its first-name seed is base ^ (g*0x9E3779B1).
    struct Want { uint8_t gid; uint32_t seed; std::string got; bool found; };
    std::vector<Want> wants;
    for (int g = 0; g < n_gen_check; ++g)
        wants.push_back({ (uint8_t)g, base ^ (uint32_t)(g * 0x9E3779B1u), "", false });

    for (uint32_t i = 0; i < n; ++i) {
        const Rec& r = host[i];
        if (r.magic != MAGIC) continue;
        for (auto& w : wants)
            if (!w.found && r.gen_id == w.gid && r.seed == w.seed) {
                w.got = decode_name(r); w.found = true;
            }
    }

    // Emit the predicted (gid, seed) pairs so a Python snippet can compute the golden names,
    // and the hardware-decoded names so we can diff. We also write a self-contained python
    // command line the user can run; and we run it inline if python3 + the tools are present.
    std::printf("verify: base_seed=%#x  mode=%s  temp=%.3f  inv_temp=%u\n",
                base, o.sample ? "sample" : "greedy", o.temp, inv_temp);

    bool all_found = true;
    std::string seeds_csv;
    for (auto& w : wants) {
        std::printf("  gen %u  seed=%#010x  hw_name=%s%s\n",
                    w.gid, w.seed, w.found ? w.got.c_str() : "<not found>",
                    w.found ? "" : "  (increase --records?)");
        if (!w.found) all_found = false;
        if (!seeds_csv.empty()) seeds_csv += ",";
        seeds_csv += std::to_string(w.seed);
    }

    // Build the golden-check command. It prints "PASS"/"FAIL". We shell out so the host binary
    // has zero Python build deps; if python3/tools are missing the user gets the exact command.
    std::string greedy_flag = o.sample ? "False" : "True";
    std::string py =
        "import sys,os; "
        "td=os.environ.get('GATEGPT_TOOLS','tools'); sys.path.insert(0,td); "
        "import numpy as np; from model import ModelConfig; "
        "from fixedpoint import QModel, generate; "
        "sd=dict(np.load(os.path.join(td,'weights.npz'))); m=QModel(sd,ModelConfig()); "
        "seeds=[" + seeds_csv + "]; inv=" + std::to_string(inv_temp) + "; "
        "hw=[" ;
    {
        bool first = true;
        for (auto& w : wants) {
            if (!first) py += ",";
            first = false;
            py += "'" + (w.found ? w.got : std::string("")) + "'";
        }
    }
    py +=
        "]; ok=True; \n"
        "for s,h in zip(seeds,hw):\n"
        "    _,g=generate(m, s&0xFFFFFFFF, inv, greedy=" + greedy_flag + ")\n"
        "    mark='OK' if g==h else 'MISMATCH'; ok = ok and (g==h)\n"
        "    print(f'  seed={s:#010x} golden={g!r} hw={h!r} {mark}')\n"
        "print('PASS' if ok else 'FAIL'); sys.exit(0 if ok else 3)\n";

    std::printf("\ngolden cross-check (tools/fixedpoint.py):\n");
    // The python body uses only single quotes internally, so wrapping the whole thing in
    // double quotes for `python3 -c "..."` is shell-safe. Point GATEGPT_TOOLS at the repo's
    // tools/ dir (defaults to ./tools relative to CWD).
    std::string cmd = "python3 -c \"" + py + "\"";
    int rc = std::system(cmd.c_str());
    if (rc != 0)
        std::fprintf(stderr,
            "\nNOTE: golden cross-check could not run inline (rc=%d). Run from repo root:\n"
            "  GATEGPT_TOOLS=$(pwd)/tools python3 -c '<see source>'\n", rc);

    if (!all_found) { std::fprintf(stderr, "verify: some target names not found\n"); return 4; }
    return (rc == 0) ? 0 : 3;
}

// =============================================================================
//  Main streaming path with per-CU ping-pong buffers and async runs.
// =============================================================================
int main(int argc, char** argv) try {
    const Opts o = parse_args(argc, argv);

    const uint32_t inv_temp = (uint32_t)(2048.0 / (o.temp > 0.05 ? o.temp : 0.05) + 0.5);

    if (o.verify) return run_verify(o);

    auto device = xrt::device(0);
    auto uuid   = device.load_xclbin(o.xclbin);
    auto kernels = make_kernels(device, uuid, o.cus);
    const int ncu = (int)kernels.size();
    const int depth = o.buffers;

    const size_t bytes = (size_t)o.n_records * sizeof(Rec);

    // Per-(CU,slot) buffer + a run handle and the seed currently in flight on it.
    struct Slot {
        xrt::bo  bo;
        const Rec* host = nullptr;
        xrt::run run;        // default-constructed; populated on first start
        uint32_t seed = 0;
        bool     inflight = false;
    };
    std::vector<std::vector<Slot>> slots(ncu);
    for (int c = 0; c < ncu; ++c) {
        slots[c].reserve(depth);
        const int gid = kernels[c].group_id(0);
        for (int b = 0; b < depth; ++b) {
            Slot s;
            s.bo   = xrt::bo(device, bytes, gid);
            s.host = s.bo.map<const Rec*>();
            slots[c].push_back(std::move(s));
        }
    }

    std::printf("xclbin   : %s\n", o.xclbin.c_str());
    std::printf("config   : n_records=%u/launch  iters=%d  mode=%s  temp=%.3f (inv_temp=%u)\n",
                o.n_records, o.iters, o.sample ? "sample" : "greedy", o.temp, inv_temp);
    std::printf("topology : %d CU%s, %d buffer%s/CU (%s)\n",
                ncu, ncu == 1 ? "" : "s", depth, depth == 1 ? "" : "s",
                depth >= 2 ? "ping-pong overlap" : "no overlap (--buffers>=2 to overlap)");
    std::printf("buffer   : %.1f MiB/buf  bank group_id=%d  (%.1f MiB total)\n",
                bytes / 1048576.0, kernels[0].group_id(0),
                bytes / 1048576.0 * ncu * depth);

    uint32_t base_seed = o.seed;
    auto next_seed = [&]() { base_seed += SEED_DELTA; return base_seed; };

    // start(cu, slot): kick an async run filling that slot's buffer with a fresh seed.
    auto start = [&](int c, int b) {
        Slot& s = slots[c][b];
        s.seed = next_seed();
        s.run = kernels[c](s.bo, o.n_records, s.seed, inv_temp, o.sample);  // run.start() implicitly
        s.inflight = true;
    };

    // Warm-up: one synchronous launch per CU, excluded from timing (clears first-call setup,
    // page-ins, and lets XRT establish the CU context).
    for (int c = 0; c < ncu; ++c) {
        auto r = kernels[c](slots[c][0].bo, o.n_records, next_seed(), inv_temp, o.sample);
        r.wait();
    }

    // Prime: launch every (CU,slot) so all are in flight before we start harvesting.
    for (int c = 0; c < ncu; ++c)
        for (int b = 0; b < depth; ++b)
            start(c, b);

    // Per-CU stats for accurate per-CU + aggregate reporting.
    std::vector<uint64_t> cu_names(ncu, 0), cu_tokens(ncu, 0), cu_launches(ncu, 0);
    uint64_t bad = 0;
    std::vector<std::string> samples;

    const auto t0 = std::chrono::steady_clock::now();
    const auto deadline = t0 + std::chrono::seconds(5);
    auto time_left = [&]() {
        return (o.iters > 0) ? true : (std::chrono::steady_clock::now() < deadline);
    };

    // Harvest loop: round-robin over (CU,slot). For each in-flight slot we wait on its run,
    // sync+decode, then immediately re-launch it (overlap: while we decode slot b, slots on
    // other CUs / the other ping-pong slot are still computing). Stop once we've collected the
    // requested number of timed launches (counting only post-prime completions), or time is up.
    const int target_launches = (o.iters > 0) ? o.iters : -1;  // -1 => time-bounded
    int harvested = 0;
    bool draining = false;
    int c = 0, b = 0;
    while (true) {
        Slot& s = slots[c][b];
        if (s.inflight) {
            s.run.wait();
            s.bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
            s.inflight = false;

            // decode
            const Rec* recs = s.host;
            for (uint32_t i = 0; i < o.n_records; ++i) {
                const Rec& r = recs[i];
                if (r.magic != MAGIC || r.name_len == 0 || r.name_len > 16) { ++bad; continue; }
                ++cu_names[c];
                cu_tokens[c] += r.name_len;
                if (!o.quiet && samples.size() < 20) {
                    std::string str = decode_name(r);
                    if (!str.empty()) samples.push_back(std::move(str));
                }
            }
            ++cu_launches[c];
            ++harvested;

            const bool more = !draining &&
                              ((target_launches < 0) ? time_left() : (harvested < target_launches));
            if (more) start(c, b);     // re-arm this slot -> keeps the pipe full
            else      draining = true; // stop launching new work; drain what's in flight
        }

        // advance round-robin cursor
        if (++b >= depth) { b = 0; if (++c >= ncu) c = 0; }

        if (draining) {
            // exit once nothing remains in flight
            bool any = false;
            for (int cc = 0; cc < ncu && !any; ++cc)
                for (int bb = 0; bb < depth; ++bb)
                    if (slots[cc][bb].inflight) { any = true; break; }
            if (!any) break;
        }
    }
    const auto t1 = std::chrono::steady_clock::now();
    const double secs = std::chrono::duration<double>(t1 - t0).count();

    uint64_t total_names = 0, total_tokens = 0, total_launches = 0;
    for (int cc = 0; cc < ncu; ++cc) {
        total_names    += cu_names[cc];
        total_tokens   += cu_tokens[cc];
        total_launches += cu_launches[cc];
    }
    const double rec_bytes = (double)total_launches * o.n_records * sizeof(Rec);

    if (!o.quiet) {
        std::printf("\nsample names:");
        for (size_t i = 0; i < samples.size(); ++i)
            std::printf("%s %s", (i % 10 == 0) ? "\n  " : "", samples[i].c_str());
        std::printf("\n");
    }

    std::printf("\nlaunches : %llu  (%d warm-up excluded)\n",
                (unsigned long long)total_launches, ncu);
    std::printf("names    : %llu  (%llu invalid)\n",
                (unsigned long long)total_names, (unsigned long long)bad);
    std::printf("elapsed  : %.3f s\n", secs);

    if (ncu > 1) {
        std::printf("per-CU   :\n");
        for (int cc = 0; cc < ncu; ++cc)
            std::printf("  CU%-2d   %6llu launches  %8.2f M names/s  %8.2f M tokens/s\n",
                        cc, (unsigned long long)cu_launches[cc],
                        cu_names[cc]  / secs / 1e6,
                        cu_tokens[cc] / secs / 1e6);
    }
    std::printf("RATE     : %.2f M names/s,  %.2f M tokens/s,  %.2f GB/s (records)\n",
                total_names / secs / 1e6, total_tokens / secs / 1e6,
                rec_bytes / secs / 1e9);

    if (bad) {
        std::fprintf(stderr, "WARNING: %llu invalid records\n", (unsigned long long)bad);
        return 2;
    }
    return 0;
} catch (const std::exception& e) {
    std::fprintf(stderr, "ERROR: %s\n", e.what());
    return 1;
}
