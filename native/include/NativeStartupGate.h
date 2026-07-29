// SPDX-License-Identifier: Unlicense
#pragma once

#include "BridgeProtocol.h"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace best_of_hands {

inline constexpr std::uint32_t kWorldCandidateStableSamples = 4;

inline std::optional<std::size_t> SystemUpdateSlotOffset(
    std::uint32_t index,
    std::uint32_t count,
    std::size_t entrySize,
    std::size_t updateOffset) noexcept
{
    if (count == 0
        || index >= count
        || entrySize < sizeof(std::uintptr_t)
        || updateOffset > entrySize - sizeof(std::uintptr_t)
        || index > ((std::numeric_limits<std::size_t>::max)()
            - updateOffset) / entrySize) {
        return std::nullopt;
    }
    return static_cast<std::size_t>(index) * entrySize + updateOffset;
}

inline bool InstalledSystemHookPointersMatch(
    std::uintptr_t modifierSlotValue,
    std::uintptr_t rollSlotValue,
    std::uintptr_t expectedModifierHook,
    std::uintptr_t expectedRollHook,
    std::uintptr_t modifierOriginal,
    std::uintptr_t rollOriginal) noexcept
{
    return expectedModifierHook != 0
        && expectedRollHook != 0
        && modifierOriginal != 0
        && rollOriginal != 0
        && modifierSlotValue == expectedModifierHook
        && rollSlotValue == expectedRollHook;
}

inline bool ShouldRetireInstalledWorld(
    bool hooksReady,
    std::uintptr_t installedWorld,
    std::uintptr_t observedWorld) noexcept
{
    return hooksReady
        && installedWorld != 0
        && observedWorld != 0
        && observedWorld != installedWorld;
}

struct StableWorldDecision {
    bool ready{};
    std::uintptr_t value{};
};

class StableWorldCandidateGate {
public:
    StableWorldDecision Observe(
        std::uintptr_t candidate,
        bool bridgeReady) noexcept
    {
        if (!bridgeReady) {
            Reset();
            return {};
        }
        if (!observed_ || candidate != candidate_) {
            candidate_ = candidate;
            samples_ = 1;
            observed_ = true;
        } else if (samples_ < kWorldCandidateStableSamples) {
            ++samples_;
        }
        return {
            samples_ >= kWorldCandidateStableSamples,
            candidate_,
        };
    }

    void Reset() noexcept
    {
        candidate_ = 0;
        samples_ = 0;
        observed_ = false;
    }

private:
    std::uintptr_t candidate_{};
    std::uint32_t samples_{};
    bool observed_{};
};

inline bool BridgeDocumentAllowsNativeHooks(
    BridgeDocument const& document,
    bool challengeWrittenAfterStartup) noexcept
{
    return challengeWrittenAfterStartup
        && document.valid
        && !document.probe.empty()
        && document.probe != std::string_view{"not-started"}
        && document.nativeSession.empty();
}

inline bool BridgeDocumentAllowsWorldHooks(
    BridgeDocument const& document,
    std::string_view currentNativeSession) noexcept
{
    return document.valid
        && !document.probe.empty()
        && document.probe != std::string_view{"not-started"}
        && (document.nativeSession.empty()
            || document.nativeSession == currentNativeSession);
}

} // namespace best_of_hands
