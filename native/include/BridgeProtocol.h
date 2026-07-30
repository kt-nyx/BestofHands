// SPDX-License-Identifier: Unlicense
#pragma once

#include <array>
#include <charconv>
#include <cstdint>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace best_of_hands {

inline constexpr std::string_view kProtocolVersion = "7";
inline constexpr std::string_view kPluginVersion = "2.1.1";

enum class ActionKind {
    Lockpick,
    Disarm,
};

struct ActionRecord {
    std::uint64_t id{};
    ActionKind kind{};
    std::uint64_t initiator{};
    std::uint64_t specialist{};
    std::uint64_t target{};
    std::uint64_t roll{};
    std::uint64_t finishedEvent{};
    std::string rollUuid;
    std::uint8_t presentationAdvantage{ 0xff };
};

struct BridgeDocument {
    bool valid{ false };
    bool trace{ false };
    std::string probe;
    std::string nativeSession;
    std::vector<ActionRecord> records;
};

struct ClientActionRecord {
    std::uint64_t id{};
    std::string rollUuid;
    std::uint64_t initiator{};
    std::uint64_t specialist{};
    std::uint64_t target{};
};

struct QuickLockpickRequest {
    std::string request;
    std::uint64_t initiator{};
    std::uint64_t target{};
    std::uint64_t targetNetId{};
};

struct LeftClickInitiator {
    std::uint64_t initiator{};
    bool eligible{};
};

struct LockedTarget {
    std::uint64_t target{};
    std::uint64_t netId{};
};

struct ClientBridgeDocument {
    bool valid{ false };
    bool trace{ false };
    std::string nativeSession;
    std::vector<ClientActionRecord> records;
    std::vector<QuickLockpickRequest> quickLockpicks;
    std::vector<LeftClickInitiator> leftClickInitiators;
    std::vector<LockedTarget> lockedTargets;
};

inline bool ParseUnsigned(std::string_view text, int base, std::uint64_t& value)
{
    value = 0;
    if (text.empty()) {
        return false;
    }
    auto const result = std::from_chars(text.data(), text.data() + text.size(), value, base);
    return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

inline bool IsBridgeToken(std::string_view value)
{
    if (value.empty() || value.size() > 128) {
        return false;
    }
    for (auto const character : value) {
        auto const valid = (character >= 'a' && character <= 'z')
            || (character >= 'A' && character <= 'Z')
            || (character >= '0' && character <= '9')
            || character == '.'
            || character == '-'
            || character == '_';
        if (!valid) {
            return false;
        }
    }
    return true;
}

template <std::size_t Count>
inline std::optional<std::array<std::string_view, Count>> SplitExact(
    std::string_view value, char delimiter)
{
    std::array<std::string_view, Count> parts{};
    std::size_t index = 0;
    std::size_t start = 0;
    while (start <= value.size()) {
        if (index == Count) {
            return {};
        }
        auto const end = value.find(delimiter, start);
        if (end == std::string_view::npos) {
            parts[index++] = value.substr(start);
            return index == Count
                ? std::optional{parts}
                : std::nullopt;
        }
        parts[index++] = value.substr(start, end - start);
        start = end + 1;
    }
    return {};
}

inline BridgeDocument ParseBridgeDocument(std::string_view text)
{
    BridgeDocument document;
    bool protocolOk = false;
    bool versionOk = false;
    bool complete = false;

    std::size_t start = 0;
    while (start <= text.size()) {
        auto const end = text.find('\n', start);
        auto line = text.substr(start, end == std::string_view::npos ? text.size() - start : end - start);
        if (!line.empty() && line.back() == '\r') {
            line.remove_suffix(1);
        }

        if (line.starts_with("protocol=")) {
            protocolOk = line.substr(9) == kProtocolVersion;
        } else if (line.starts_with("pak_version=")) {
            versionOk = line.substr(12) == kPluginVersion;
        } else if (line.starts_with("probe=")) {
            document.probe.assign(line.substr(6));
        } else if (line.starts_with("native_session=")) {
            document.nativeSession.assign(line.substr(15));
        } else if (line.starts_with("trace=")) {
            document.trace = line.substr(6) == "1";
        } else if (line.starts_with("record=")) {
            auto const parsedFields =
                SplitExact<12>(line.substr(7), '\t');
            if (!parsedFields.has_value()) {
                return {};
            }
            auto const& fields = *parsedFields;
            ActionRecord record;
            if (!ParseUnsigned(fields[0], 10, record.id)
                || record.id == 0) {
                return {};
            }
            if (fields[1] == "lockpick") {
                record.kind = ActionKind::Lockpick;
            } else if (fields[1] == "disarm") {
                record.kind = ActionKind::Disarm;
            } else {
                return {};
            }
            if (!ParseUnsigned(fields[2], 16, record.initiator)
                || !ParseUnsigned(fields[3], 16, record.specialist)
                || !ParseUnsigned(fields[4], 16, record.target)
                || !ParseUnsigned(fields[5], 16, record.roll)
                || !ParseUnsigned(fields[6], 16, record.finishedEvent)
                || record.initiator == 0
                || record.specialist == 0
                || record.target == 0) {
                return {};
            }
            if (fields[7] != "0") {
                record.rollUuid.assign(fields[7]);
            }
            std::uint64_t advantage{};
            if (!ParseUnsigned(fields[11], 10, advantage)
                || advantage > 2) {
                if (fields[11] != "-1") {
                    return {};
                }
            } else {
                record.presentationAdvantage = static_cast<std::uint8_t>(advantage);
            }
            document.records.push_back(record);
        } else if (line == "end=1") {
            complete = true;
        }

        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }

    document.valid = protocolOk && versionOk && complete && !document.probe.empty();
    if (!document.valid) {
        document.records.clear();
    }
    return document;
}

inline ClientBridgeDocument ParseClientBridgeDocument(std::string_view text)
{
    ClientBridgeDocument document;
    bool protocolOk = false;
    bool versionOk = false;
    bool complete = false;

    std::size_t start = 0;
    while (start <= text.size()) {
        auto const end = text.find('\n', start);
        auto line = text.substr(start,
            end == std::string_view::npos ? text.size() - start : end - start);
        if (!line.empty() && line.back() == '\r') {
            line.remove_suffix(1);
        }

        if (line.starts_with("protocol=")) {
            protocolOk = line.substr(9) == kProtocolVersion;
        } else if (line.starts_with("pak_version=")) {
            versionOk = line.substr(12) == kPluginVersion;
        } else if (line.starts_with("native_session=")) {
            document.nativeSession.assign(line.substr(15));
        } else if (line.starts_with("trace=")) {
            document.trace = line.substr(6) == "1";
        } else if (line.starts_with("record=")) {
            auto const parsedFields =
                SplitExact<5>(line.substr(7), '\t');
            if (!parsedFields.has_value()) {
                return {};
            }
            auto const& fields = *parsedFields;
            ClientActionRecord record;
            if (!ParseUnsigned(fields[0], 10, record.id)
                || fields[1].empty()
                || !ParseUnsigned(fields[2], 16, record.initiator)
                || !ParseUnsigned(fields[3], 16, record.specialist)
                || !ParseUnsigned(fields[4], 16, record.target)
                || record.id == 0
                || record.initiator == 0
                || record.specialist == 0
                || record.target == 0) {
                return {};
            }
            record.rollUuid.assign(fields[1]);
            document.records.push_back(std::move(record));
        } else if (line.starts_with("quick=")) {
            auto const parsedFields =
                SplitExact<4>(line.substr(6), '\t');
            if (!parsedFields.has_value()) {
                return {};
            }
            auto const& fields = *parsedFields;
            QuickLockpickRequest request;
            request.request.assign(fields[0]);
            if (!IsBridgeToken(fields[0])
                || !ParseUnsigned(fields[1], 16, request.initiator)
                || !ParseUnsigned(fields[2], 16, request.target)
                || !ParseUnsigned(fields[3], 10, request.targetNetId)
                || request.initiator == 0
                || request.target == 0
                || request.targetNetId == 0) {
                return {};
            }
            document.quickLockpicks.push_back(std::move(request));
        } else if (line.starts_with("eligible=")) {
            auto const parsedFields =
                SplitExact<2>(line.substr(9), '\t');
            if (!parsedFields.has_value()) {
                return {};
            }
            auto const& fields = *parsedFields;
            LeftClickInitiator initiator;
            std::uint64_t eligible{};
            if (!ParseUnsigned(fields[0], 16, initiator.initiator)
                || !ParseUnsigned(fields[1], 10, eligible)
                || initiator.initiator == 0
                || eligible > 1) {
                return {};
            }
            initiator.eligible = eligible == 1;
            document.leftClickInitiators.push_back(initiator);
        } else if (line.starts_with("locked=")) {
            auto const parsedFields =
                SplitExact<2>(line.substr(7), '\t');
            if (!parsedFields.has_value()) {
                return {};
            }
            auto const& fields = *parsedFields;
            LockedTarget target;
            if (!ParseUnsigned(fields[0], 16, target.target)
                || !ParseUnsigned(fields[1], 10, target.netId)
                || target.target == 0
                || target.netId == 0) {
                return {};
            }
            document.lockedTargets.push_back(target);
        } else if (line == "end=1") {
            complete = true;
        }

        if (end == std::string_view::npos) {
            break;
        }
        start = end + 1;
    }

    document.valid = protocolOk && versionOk && complete
        && !document.nativeSession.empty();
    if (!document.valid) {
        document.records.clear();
        document.quickLockpicks.clear();
        document.leftClickInitiators.clear();
        document.lockedTargets.clear();
    }
    return document;
}

inline std::string ActionName(ActionKind kind)
{
    return kind == ActionKind::Lockpick ? "lockpick" : "disarm";
}

} // namespace best_of_hands
