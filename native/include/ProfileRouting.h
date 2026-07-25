// SPDX-License-Identifier: Unlicense
#pragma once

#include "BridgeProtocol.h"

#include <array>
#include <cstdio>
#include <cstdint>
#include <optional>
#include <span>
#include <string>

namespace best_of_hands {

struct RequestedRollIdentity {
    std::uint64_t roll{};
    std::uint64_t roller{};
    std::uint64_t subject{};
    std::string rollUuid;
};

enum class ProfileScope {
    Server,
    Client,
};

struct ProfileSelection {
    ActionRecord record;
    std::uint64_t specialist{};
    ProfileScope scope{ ProfileScope::Server };
};

inline std::optional<std::uint8_t> ClientPresentationAdvantage(
    ProfileSelection const& selection)
{
    if (selection.scope != ProfileScope::Client
        || selection.record.presentationAdvantage > 2) {
        return {};
    }
    return selection.record.presentationAdvantage;
}

inline bool MatchesClientPresentationLease(
    RequestedRollIdentity const& identity,
    std::string_view leaseRollUuid,
    std::uint64_t leaseRoller,
    std::uint64_t leaseSubject,
    std::uint64_t leaseSpecialist)
{
    return !identity.rollUuid.empty()
        && identity.rollUuid == leaseRollUuid
        && identity.roller == leaseRoller
        && identity.subject == leaseSubject
        && leaseSpecialist != 0
        && leaseSpecialist != identity.roller;
}

inline bool ShouldPreserveTransientRollBonus(
    bool exactDelegatedLease,
    bool enabled,
    bool selected,
    std::uint8_t diceCount,
    bool presentInPrimaryDynamicSet,
    bool presentInSelectedDynamicSet)
{
    return exactDelegatedLease
        && enabled
        && selected
        && diceCount != 0
        && presentInPrimaryDynamicSet
        && presentInSelectedDynamicSet;
}

inline bool ShouldPromoteMissingSelectedRollBonus(
    bool exactDelegatedLease,
    bool invisible,
    bool enabled,
    bool selected,
    std::uint8_t diceCount,
    bool missingFromSelectedDynamicSet)
{
    return exactDelegatedLease
        && invisible
        && enabled
        && selected
        && diceCount != 0
        && missingFromSelectedDynamicSet;
}

inline bool ShouldPreserveAdvantageModifierPresentation(
    std::uint8_t expectedAdvantage,
    std::uint8_t advantageType,
    std::uint8_t disabled,
    std::uint8_t state)
{
    return expectedAdvantage >= 1
        && expectedAdvantage <= 2
        && advantageType == expectedAdvantage
        && disabled == 0
        && state != 3;
}

inline bool ShouldPreserveAdvantageSourceModifier(
    std::uint8_t expectedAdvantage,
    std::uint8_t boostType,
    std::uint8_t disabled,
    std::uint8_t state,
    bool hasSourceViewModel)
{
    return expectedAdvantage >= 1
        && expectedAdvantage <= 2
        && boostType == 3
        && disabled == 0
        && state != 3
        && hasSourceViewModel;
}

inline std::string FormatGuid(std::array<std::uint8_t, 16> const& bytes)
{
    char value[37]{};
    std::snprintf(value, sizeof(value),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[3], bytes[2], bytes[1], bytes[0],
        bytes[5], bytes[4],
        bytes[7], bytes[6],
        bytes[9], bytes[8],
        bytes[11], bytes[10], bytes[13], bytes[12], bytes[15], bytes[14]);
    return value;
}

inline std::optional<ActionRecord> MatchProfileSource(
    std::span<ActionRecord const> records,
    RequestedRollIdentity const& identity)
{
    std::optional<ActionRecord> match;
    for (auto const& record : records) {
        if (record.roll == 0
            || record.roll != identity.roll
            || record.initiator != identity.roller
            || record.target != identity.subject
            || record.specialist == 0
            || record.specialist == record.initiator) {
            continue;
        }
        if (match.has_value()) {
            // An ambiguous bridge document must never redirect an engine read.
            return {};
        }
        match = record;
    }
    return match;
}

inline std::optional<ProfileSelection> MatchProfileSelection(
    std::span<ActionRecord const> serverRecords,
    std::span<ClientActionRecord const> clientRecords,
    RequestedRollIdentity const& identity)
{
    if (auto const server = MatchProfileSource(serverRecords, identity)) {
        return ProfileSelection{
            .record = *server,
            .specialist = server->specialist,
            .scope = ProfileScope::Server,
        };
    }

    std::optional<ProfileSelection> match;
    for (auto const& server : serverRecords) {
        if (server.rollUuid.empty()
            || server.rollUuid != identity.rollUuid
            || server.specialist == 0
            || server.specialist == server.initiator) {
            continue;
        }
        for (auto const& client : clientRecords) {
            if (client.id != server.id
                || client.rollUuid != identity.rollUuid
                || client.initiator != identity.roller
                || client.target != identity.subject
                || client.specialist == 0
                || client.specialist == client.initiator) {
                continue;
            }
            if (match.has_value()) {
                return {};
            }
            match = ProfileSelection{
                .record = server,
                .specialist = client.specialist,
                .scope = ProfileScope::Client,
            };
        }
    }
    return match;
}

} // namespace best_of_hands
