// SPDX-License-Identifier: Unlicense
#pragma once

#include "BridgeProtocol.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

namespace best_of_hands {

#pragma pack(push, 1)
struct StockLockpickTaskConfiguration {
    std::uint64_t target{};
    std::uint64_t targetNetId{};
    std::uint8_t lockpickingStarted{};
    std::uint8_t targetSelected{ 1 };
    std::uint8_t canLockpick{};
};
#pragma pack(pop)
static_assert(sizeof(StockLockpickTaskConfiguration) == 0x13);
static_assert(offsetof(StockLockpickTaskConfiguration, target) == 0x00);
static_assert(offsetof(StockLockpickTaskConfiguration, targetNetId) == 0x08);
static_assert(offsetof(
    StockLockpickTaskConfiguration, lockpickingStarted) == 0x10);
static_assert(offsetof(
    StockLockpickTaskConfiguration, targetSelected) == 0x11);
static_assert(offsetof(
    StockLockpickTaskConfiguration, canLockpick) == 0x12);
static_assert(std::is_trivially_copyable_v<StockLockpickTaskConfiguration>);

struct LeftClickRoutingSnapshot {
    bool valid{};
    std::string nativeSession;
    std::unordered_map<std::uint64_t, bool> initiators;
    std::unordered_map<std::uint64_t, std::uint64_t> targets;
};

inline LeftClickRoutingSnapshot BuildLeftClickRoutingSnapshot(
    ClientBridgeDocument const& document)
{
    if (!document.valid || document.nativeSession.empty()) {
        return {};
    }

    LeftClickRoutingSnapshot snapshot;
    snapshot.nativeSession = document.nativeSession;
    snapshot.initiators.reserve(document.leftClickInitiators.size());
    snapshot.targets.reserve(document.lockedTargets.size());
    for (auto const& initiator : document.leftClickInitiators) {
        if (!snapshot.initiators.emplace(
                initiator.initiator, initiator.eligible).second) {
            return {};
        }
    }
    for (auto const& target : document.lockedTargets) {
        if (!snapshot.targets.emplace(target.target, target.netId).second) {
            return {};
        }
    }
    snapshot.valid = true;
    return snapshot;
}

inline std::optional<std::uint64_t> ResolveLeftClickTarget(
    LeftClickRoutingSnapshot const& snapshot,
    std::string_view nativeSession,
    std::uint64_t initiator,
    std::uint64_t target) noexcept
{
    if (!snapshot.valid || snapshot.nativeSession != nativeSession) {
        return {};
    }
    auto const initiatorIt = snapshot.initiators.find(initiator);
    if (initiatorIt == snapshot.initiators.end() || !initiatorIt->second) {
        return {};
    }
    auto const targetIt = snapshot.targets.find(target);
    return targetIt == snapshot.targets.end()
        ? std::optional<std::uint64_t>{}
        : std::optional<std::uint64_t>{ targetIt->second };
}

inline void PruneConsumedQuickLockpicks(
    std::unordered_set<std::string>& consumed,
    std::span<QuickLockpickRequest const> active)
{
    std::erase_if(consumed, [&active](std::string const& request) {
        return std::ranges::none_of(active,
            [&request](QuickLockpickRequest const& candidate) {
                return candidate.request == request;
            });
    });
}

} // namespace best_of_hands
