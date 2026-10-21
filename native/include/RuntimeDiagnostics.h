// SPDX-License-Identifier: Unlicense
#pragma once
#include <Windows.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <sstream>
#include <string_view>

namespace best_of_hands {
// Opt-in aggregate timings; no output, allocation or diagnostic locks in hooks.
enum class RuntimeMetric : std::size_t {
    ActionRefresh, Handshake, ClientRefresh, LeftClickRefresh, WorldObservation,
    InstalledValidation, GameRefresh, RefreshLockWait, FileTimestamp, FileRead,
    MemoryRegion, StatusWrite, ControllerCheck, SnapshotRead, Count
};
inline constexpr std::array<std::string_view, static_cast<std::size_t>(RuntimeMetric::Count)>
    kRuntimeNames{"actions", "handshake", "client", "leftclick", "world",
        "installed_validation", "game_refresh", "refresh_lock_wait", "timestamp",
        "read", "memory_region", "status_write", "controller_check", "snapshot_read"};
struct RuntimeCounter {
    std::atomic<std::uint64_t> calls{}, ticks{}, maximum{};
};
inline std::array<RuntimeCounter, kRuntimeNames.size()> runtimeCounters{};
inline std::uint64_t RuntimeNow() noexcept
{
    LARGE_INTEGER time{};
    QueryPerformanceCounter(&time);
    return static_cast<std::uint64_t>(time.QuadPart);
}
class RuntimeScope {
public:
    explicit RuntimeScope(RuntimeMetric metric) noexcept : metric_(metric)
    {
        if constexpr (BEST_OF_HANDS_PERF_DIAGNOSTICS != 0) start_ = RuntimeNow();
    }
    ~RuntimeScope() noexcept
    {
        if constexpr (BEST_OF_HANDS_PERF_DIAGNOSTICS != 0) {
            auto const elapsed = RuntimeNow() - start_;
            auto& counter = runtimeCounters[static_cast<std::size_t>(metric_)];
            counter.calls.fetch_add(1, std::memory_order_relaxed);
            counter.ticks.fetch_add(elapsed, std::memory_order_relaxed);
            auto maximum = counter.maximum.load(std::memory_order_relaxed);
            while (maximum < elapsed && !counter.maximum.compare_exchange_weak(
                maximum, elapsed, std::memory_order_relaxed)) {}
        }
    }
private:
    RuntimeMetric metric_;
    std::uint64_t start_{};
};
// Called by the worker only. Counts are diagnostic interval totals; a scope
// completing at the interval edge may appear in the adjacent interval.
template<class Logger>
void FlushRuntimeDiagnostics(Logger&& logger)
{
    if constexpr (BEST_OF_HANDS_PERF_DIAGNOSTICS != 0) {
        static ULONGLONG previousTime{};
        static std::uint64_t previousKernel{}, previousUser{};
        auto const now = GetTickCount64();
        if (now - previousTime < 10000) return;
        FILETIME created{}, exited{}, kernel{}, user{};
        if (!GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user)) return;
        auto number = [](FILETIME value) {
            return (static_cast<std::uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime;
        };
        auto const kernelTime = number(kernel), userTime = number(user);
        LARGE_INTEGER frequency{};
        QueryPerformanceFrequency(&frequency);
        std::ostringstream fields;
        fields << "thread=" << GetCurrentThreadId() << "|interval_ms=" << (previousTime ? now - previousTime : 0)
               << "|worker_kernel_us=" << (kernelTime - previousKernel) / 10
               << "|worker_user_us=" << (userTime - previousUser) / 10;
        previousTime = now; previousKernel = kernelTime; previousUser = userTime;
        for (std::size_t i = 0; i < runtimeCounters.size(); ++i) {
            auto& counter = runtimeCounters[i];
            auto const calls = counter.calls.exchange(0, std::memory_order_relaxed);
            auto const ticks = counter.ticks.exchange(0, std::memory_order_relaxed);
            auto const maximum = counter.maximum.exchange(0, std::memory_order_relaxed);
            fields << '|' << kRuntimeNames[i] << '=' << calls << ','
                   << ticks * 1000000 / frequency.QuadPart << ','
                   << maximum * 1000000 / frequency.QuadPart;
        }
        logger(fields.str());
    }
}
} // namespace best_of_hands
