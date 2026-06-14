// XRT host for krnl_namegen on the Alveo U200.
// Loads the xclbin, allocates the result buffer in the kernel's DDR bank, launches the
// generator farm in chunks (each launch fills n_records 64-byte name records), decodes the
// records, and reports throughput. Each launch uses a fresh base_seed so names keep varying.
//
//   ./host krnl_namegen.xclbin [n_records] [iters] [temp] [sample] [seed]
//     n_records  records per launch        (default 1<<20)
//     iters      number of launches        (default 16; 0 => loop ~5 s)
//     temp       sampling temperature      (default 0.8)
//     sample     1=sample, 0=greedy        (default 1)
//     seed       initial base seed         (default 1)
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>
#include <exception>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"

#pragma pack(push, 1)
struct Rec {
    uint8_t  name_len;
    uint8_t  gen_id;
    uint16_t magic;       // 0x4E47
    uint32_t seed;
    uint8_t  name[16];    // values 0..25 == 'a'..'z'
    uint64_t seq;
    uint8_t  pad[32];
};
#pragma pack(pop)
static_assert(sizeof(Rec) == 64, "record must be 64 bytes");

static constexpr uint16_t MAGIC = 0x4E47;

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <xclbin> [n_records] [iters] [temp] [sample] [seed]\n", argv[0]);
        return 1;
    }
    const std::string xclbin = argv[1];
    const uint32_t n_records = (argc > 2) ? std::strtoul(argv[2], nullptr, 0) : (1u << 20);
    const int      iters     = (argc > 3) ? std::atoi(argv[3]) : 16;
    const double   temp      = (argc > 4) ? std::atof(argv[4]) : 0.8;
    const uint32_t sample    = (argc > 5) ? std::strtoul(argv[5], nullptr, 0) : 1u;
    uint32_t       base_seed = (argc > 6) ? std::strtoul(argv[6], nullptr, 0) : 1u;

    // 1/temperature in Q5.11 (FRAC=11). Used only when sampling; clamped to >0.
    const uint32_t inv_temp = (uint32_t)(2048.0 / (temp > 0.05 ? temp : 0.05) + 0.5);

    try {
        auto device = xrt::device(0);
        auto uuid   = device.load_xclbin(xclbin);
        auto krnl   = xrt::kernel(device, uuid, "krnl_namegen");

        const size_t bytes = (size_t)n_records * sizeof(Rec);
        // arg 0 (out) is the m_axi pointer; group_id(0) -> its connected DDR bank.
        auto out_bo = xrt::bo(device, bytes, krnl.group_id(0));
        auto* host  = out_bo.map<uint8_t*>();

        std::printf("xclbin   : %s\n", xclbin.c_str());
        std::printf("config   : n_records=%u/launch  iters=%d  mode=%s  temp=%.3f (inv_temp=%u)\n",
                    n_records, iters, sample ? "sample" : "greedy", temp, inv_temp);
        std::printf("buffer   : %.1f MiB in bank group_id=%d\n",
                    bytes / 1048576.0, krnl.group_id(0));

        // optional warm-up launch (excluded from timing)
        {
            auto r = krnl(out_bo, n_records, base_seed, inv_temp, sample);
            r.wait();
        }

        uint64_t total_names = 0, total_tokens = 0, bad = 0;
        std::vector<std::string> samples;
        const auto t0 = std::chrono::steady_clock::now();
        const auto deadline = t0 + std::chrono::seconds(5);

        int launch = 0;
        for (; (iters > 0) ? (launch < iters)
                           : (std::chrono::steady_clock::now() < deadline); ++launch) {
            base_seed += 0x9E3779B9u;                    // fresh stream each launch
            auto run = krnl(out_bo, n_records, base_seed, inv_temp, sample);
            run.wait();
            out_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

            const Rec* recs = reinterpret_cast<const Rec*>(host);
            for (uint32_t i = 0; i < n_records; ++i) {
                const Rec& r = recs[i];
                if (r.magic != MAGIC || r.name_len == 0 || r.name_len > 16) { ++bad; continue; }
                ++total_names;
                total_tokens += r.name_len;
                if (samples.size() < 20) {
                    std::string s;
                    for (uint8_t k = 0; k < r.name_len && r.name[k] < 26; ++k)
                        s.push_back('a' + r.name[k]);
                    samples.push_back(std::move(s));
                }
            }
        }
        const auto t1 = std::chrono::steady_clock::now();
        const double secs = std::chrono::duration<double>(t1 - t0).count();

        std::printf("\nsample names:");
        for (size_t i = 0; i < samples.size(); ++i)
            std::printf("%s %s", (i % 10 == 0) ? "\n  " : "", samples[i].c_str());
        std::printf("\n\nlaunches : %d\n", launch);
        std::printf("names    : %llu  (%llu invalid)\n",
                    (unsigned long long)total_names, (unsigned long long)bad);
        std::printf("elapsed  : %.3f s\n", secs);
        std::printf("RATE     : %.2f M names/s,  %.2f M tokens/s\n",
                    total_names / secs / 1e6, total_tokens / secs / 1e6);
        if (bad) { std::fprintf(stderr, "WARNING: %llu invalid records\n", (unsigned long long)bad); return 2; }
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "ERROR: %s\n", e.what());
        return 1;
    }
}
