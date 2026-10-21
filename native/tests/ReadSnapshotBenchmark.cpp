// SPDX-License-Identifier: Unlicense
#include "SafeMemory.h"
#include <chrono>
#include <cstdint>
#include <iostream>

// Isolated Windows microbenchmark, not a prediction of BG3 frame times.
// Both paths perform the same guarded read; only the old region preflight differs.
int main()
{
    constexpr std::size_t allocationSize = 64 * 1024 * 1024;
    constexpr unsigned repetitions = 2000;
    auto* memory = VirtualAlloc(nullptr, allocationSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!memory) return 1;
    *static_cast<std::uint64_t*>(memory) = 7;
    best_of_hands::ReadOnlySnapshot<0x68> snapshot;
    std::uint64_t checksum{};
    auto run = [&](bool preflight) {
        auto const start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < repetitions; ++i) {
            if (preflight) {
                MEMORY_BASIC_INFORMATION info{};
                if (!VirtualQuery(memory, &info, sizeof(info)) || info.State != MEM_COMMIT
                    || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) return -1.0;
                auto const begin = reinterpret_cast<std::uintptr_t>(memory);
                auto const end = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
                if (begin + 0x68 > end) return -1.0;
            }
            if (!snapshot.Capture(memory)) return -1.0;
            checksum += snapshot.Field<std::uint64_t, 0>();
        }
        return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
    };
    // Warm both paths, then alternate to reduce order bias.
    if (run(true) < 0 || run(false) < 0) return 2;
    double before{}, after{};
    for (unsigned i = 0; i < 3; ++i) {
        before += run(true); after += run(false);
        after += run(false); before += run(true);
    }
    auto const freed = VirtualFree(memory, 0, MEM_RELEASE);
    std::cout << "isolated_windows_read_benchmark|allocation_bytes=" << allocationSize
        << "|reads_per_path=" << repetitions * 6 << "|before_query_calls=" << repetitions * 6
        << "|after_query_calls=0|before_total_us=" << before << "|after_total_us=" << after
        << "|checksum=" << checksum << '\n';
    return freed && before >= 0 && after >= 0 && checksum == repetitions * 14ULL * 7 ? 0 : 3;
}
