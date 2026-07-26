// SPDX-License-Identifier: Unlicense
#include "BridgeProtocol.h"
#include "FixedSnapshot.h"
#include "ProfileRouting.h"
#include "QuickLockpickState.h"
#include "SafeMemory.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <unordered_set>
#include <vector>

#ifdef NDEBUG
#error Native regression assertions must remain enabled in Release builds.
#endif

using namespace best_of_hands;

namespace {

bool TestSetRunningTask(void* controller, void* task, bool forceClear)
{
    return controller == reinterpret_cast<void*>(0x1234)
        && task == reinterpret_cast<void*>(0x5678)
        && forceClear;
}

void* TestGetCharacterTask(void* controller, std::uint32_t taskType)
{
    return controller == reinterpret_cast<void*>(0x1234)
            && taskType == 15
        ? reinterpret_cast<void*>(0x5678)
        : nullptr;
}

}

int main()
{
    std::uint64_t readableValue = 0x123456789abcdef0ULL;
    std::uint64_t observedValue{};
    assert(SafeRead(&readableValue, observedValue));
    assert(observedValue == readableValue);
    std::uint64_t replacementValue = 0x0fedcba987654321ULL;
    assert(SafeWrite(&readableValue, replacementValue));
    assert(readableValue == replacementValue);
    assert(!SafeRead(nullptr, observedValue));
    assert(!SafeWrite(nullptr, replacementValue));
    bool taskStarted{};
    assert(TryInvokeSetRunningTask(
        reinterpret_cast<std::uintptr_t>(&TestSetRunningTask),
        reinterpret_cast<void*>(0x1234),
        reinterpret_cast<void*>(0x5678),
        true,
        taskStarted));
    assert(taskStarted);
    assert(!TryInvokeSetRunningTask(
        0,
        reinterpret_cast<void*>(0x1234),
        reinterpret_cast<void*>(0x5678),
        true,
        taskStarted));
    void* stockTask{};
    assert(TryGetCharacterTask(
        reinterpret_cast<std::uintptr_t>(&TestGetCharacterTask),
        reinterpret_cast<void*>(0x1234),
        15,
        stockTask));
    assert(stockTask == reinterpret_cast<void*>(0x5678));
    assert(!TryGetCharacterTask(
        0,
        reinterpret_cast<void*>(0x1234),
        15,
        stockTask));
    assert(!TryGetCharacterTask(
        reinterpret_cast<std::uintptr_t>(&TestGetCharacterTask),
        nullptr,
        15,
        stockTask));
    StockLockpickTaskConfiguration lockpickConfiguration{
        .target = 0x123456789abcdef0ULL,
        .targetNetId = 0x0fedcba987654321ULL,
    };
    assert(sizeof(lockpickConfiguration) == 0x13);
    assert(lockpickConfiguration.target == 0x123456789abcdef0ULL);
    assert(lockpickConfiguration.targetNetId == 0x0fedcba987654321ULL);
    assert(lockpickConfiguration.lockpickingStarted == 0);
    assert(lockpickConfiguration.targetSelected == 1);
    assert(lockpickConfiguration.canLockpick == 0);
    auto const* lockpickConfigurationBytes =
        reinterpret_cast<std::uint8_t const*>(&lockpickConfiguration);
    assert(lockpickConfigurationBytes[0x10] == 0);
    assert(lockpickConfigurationBytes[0x11] == 1);
    assert(lockpickConfigurationBytes[0x12] == 0);
    auto* inaccessible = VirtualAlloc(
        nullptr, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
    assert(inaccessible != nullptr);
    observedValue = 0x1122334455667788ULL;
    assert(!SafeRead(inaccessible, observedValue));
    assert(observedValue == 0x1122334455667788ULL);
    assert(!SafeWrite(inaccessible, replacementValue));
    assert(VirtualFree(inaccessible, 0, MEM_RELEASE) != FALSE);

    auto* splitRegion = static_cast<std::byte*>(VirtualAlloc(
        nullptr, 8192, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    assert(splitRegion != nullptr);
    std::uint32_t readablePrefix = 0xa1b2c3d4U;
    std::memcpy(splitRegion + 4092,
        &readablePrefix, sizeof(readablePrefix));
    DWORD splitPreviousProtection{};
    assert(VirtualProtect(splitRegion + 4096, 4096, PAGE_NOACCESS,
        &splitPreviousProtection) != FALSE);
    observedValue = 0x8877665544332211ULL;
    assert(!SafeRead(splitRegion + 4092, observedValue));
    assert(observedValue == 0x8877665544332211ULL);
    assert(VirtualFree(splitRegion, 0, MEM_RELEASE) != FALSE);

    auto* readOnly = VirtualAlloc(
        nullptr, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    assert(readOnly != nullptr);
    assert(SafeWrite(readOnly, replacementValue));
    DWORD previousProtection{};
    assert(VirtualProtect(
        readOnly, 4096, PAGE_READONLY, &previousProtection) != FALSE);
    assert(SafeRead(readOnly, observedValue));
    assert(observedValue == replacementValue);
    assert(!SafeWrite(readOnly, readableValue));
    assert(VirtualFree(readOnly, 0, MEM_RELEASE) != FALSE);

    FixedSnapshot<int, 3> snapshot;
    assert(snapshot.empty());
    assert(snapshot.capacity() == 3);
    assert(snapshot.push_back(10));
    assert(snapshot.push_back(20));
    assert(snapshot.push_back(30));
    assert(!snapshot.push_back(40));
    assert(snapshot.size() == 3);
    assert(snapshot[0] == 10);
    assert(snapshot[2] == 30);
    int snapshotTotal{};
    for (auto const value : snapshot) {
        snapshotTotal += value;
    }
    assert(snapshotTotal == 60);
    snapshot.clear();
    assert(snapshot.empty());
    assert(snapshot.push_back(50));
    assert(snapshot.size() == 1);
    assert(snapshot[0] == 50);
    FixedSnapshot<int, 0> emptySnapshot;
    assert(emptySnapshot.empty());
    assert(emptySnapshot.capacity() == 0);
    assert(!emptySnapshot.push_back(1));

    auto const exactFields = SplitExact<3>("alpha\tbeta\tgamma", '\t');
    assert(exactFields.has_value());
    assert((*exactFields)[0] == "alpha");
    assert((*exactFields)[2] == "gamma");
    assert(!SplitExact<2>("alpha\tbeta\tgamma", '\t').has_value());
    assert(!SplitExact<4>("alpha\tbeta\tgamma", '\t').has_value());
    auto const emptyField = SplitExact<3>("alpha\t\tgamma", '\t');
    assert(emptyField.has_value());
    assert((*emptyField)[1].empty());
    auto const trailingField = SplitExact<3>("alpha\tbeta\t", '\t');
    assert(trailingField.has_value());
    assert((*trailingField)[2].empty());

    std::uint64_t unsignedValue{};
    assert(ParseUnsigned("18446744073709551615", 10, unsignedValue));
    assert(unsignedValue == UINT64_MAX);
    assert(ParseUnsigned("ABCDEF", 16, unsignedValue));
    assert(unsignedValue == 0xabcdefULL);
    assert(!ParseUnsigned("", 10, unsignedValue));
    assert(!ParseUnsigned("-1", 10, unsignedValue));
    assert(!ParseUnsigned("1x", 10, unsignedValue));
    assert(!ParseUnsigned("18446744073709551616", 10, unsignedValue));
    assert(IsBridgeToken("42-1-7"));
    assert(!IsBridgeToken(""));
    assert(!IsBridgeToken("request|unsafe"));

    auto const valid = ParseBridgeDocument(
        "protocol=7\n"
        "pak_version=2.0.0\n"
        "probe=abc-123\n"
        "native_session=44-55\n"
        "trace=1\n"
        "record=7\tlockpick\t0200000100000085\t02000001000000d4\t020000010000f15c\t0200000200000100\t0200000200000200\t4dc3ec09-e11d-e030-cac3-99253090aaf8\t0a80d5b3-b915-5a3f-f1ab-6ed834cc20ac\tc7c13742-bacd-460a-8f65-f864fe41f255\t2c7ce004-0a07-4815-af00-56ed24542567\t1\n"
        "record=8\tdisarm\t0200000100000085\t02000001000000d4\t020000010000ae68\t0\t0\t0\t0a80d5b3-b915-5a3f-f1ab-6ed834cc20ac\tc7c13742-bacd-460a-8f65-f864fe41f255\tc82b2cb9-16d1-4e08-80b5-b4195ffda9c3\t-1\n"
        "end=1\n");
    assert(valid.valid);
    assert(valid.trace);
    assert(valid.probe == "abc-123");
    assert(valid.nativeSession == "44-55");
    assert(valid.records.size() == 2);
    assert(valid.records[0].kind == ActionKind::Lockpick);
    assert(valid.records[0].initiator == 0x0200000100000085ULL);
    assert(valid.records[1].kind == ActionKind::Disarm);
    assert(valid.records[1].target == 0x020000010000ae68ULL);
    assert(valid.records[0].roll == 0x0200000200000100ULL);
    assert(valid.records[0].rollUuid == "4dc3ec09-e11d-e030-cac3-99253090aaf8");
    assert(valid.records[0].presentationAdvantage == 1);
    assert(valid.records[1].roll == 0);
    assert(valid.records[1].rollUuid.empty());
    assert(valid.records[1].presentationAdvantage == 0xff);
    assert(valid.records[0].finishedEvent == 0x0200000200000200ULL);
    assert(valid.records[1].finishedEvent == 0);

    assert(!ParseBridgeDocument("protocol=2\npak_version=2.0.0\nprobe=x\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=1\npak_version=2.0.0\nprobe=x\nend=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\tnot-hex\t2\t3\t0\t0\t0\ta\tb\tc\t-1\nend=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=0\tlockpick\t1\t2\t3\t0\t0\t0\ta\tb\tc\t-1\nend=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\t1\t2\t3\nend=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\t1\t2\t3\t0\t0\t0\ta\tb\tc\t0\textra\n"
        "end=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\t1\t2\t3\t0\t0\t0\ta\tb\tc\t3\n"
        "end=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tunknown\t1\t2\t3\t0\t0\t0\ta\tb\tc\t-1\n"
        "end=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\t1\t2\t3\t0\t0\t0\ta\tb\tc\t-2\n"
        "end=1\n").valid);
    assert(!ParseBridgeDocument(
        "protocol=7\npak_version=2.0.0\nprobe=x\n"
        "record=1\tlockpick\t1\t2\t3\t0\t0\t0\ta\tb\tc\t-1\n").valid);

    RequestedRollIdentity identity{
        .roll = 0x0200000200000100ULL,
        .roller = 0x0200000100000085ULL,
        .subject = 0x020000010000f15cULL,
    };
    auto profile = MatchProfileSource(valid.records, identity);
    assert(profile.has_value());
    assert(profile->id == 7);
    assert(profile->specialist == 0x02000001000000d4ULL);
    identity.roller = profile->specialist;
    assert(!MatchProfileSource(valid.records, identity).has_value());
    identity.roller = profile->initiator;
    identity.subject = 0x020000010000ae68ULL;
    assert(!MatchProfileSource(valid.records, identity).has_value());
    identity.subject = profile->target;
    auto duplicateRecords = valid.records;
    duplicateRecords.push_back(valid.records[0]);
    assert(!MatchProfileSource(duplicateRecords, identity).has_value());

    auto const client = ParseClientBridgeDocument(
        "protocol=7\n"
        "pak_version=2.0.0\n"
        "native_session=44-55\n"
        "trace=1\n"
        "record=7\t4dc3ec09-e11d-e030-cac3-99253090aaf8\t01c0000100000085\t01c00001000000d4\t01c000010000f15c\n"
        "quick=100-2-3\t01c0000100000085\t01c000010000f15c\t1125899906937610\n"
        "eligible=01c0000100000085\t1\n"
        "locked=01c000010000f15c\t1125899906937610\n"
        "end=1\n");
    assert(client.valid);
    assert(client.trace);
    assert(client.nativeSession == "44-55");
    assert(client.records.size() == 1);
    assert(client.quickLockpicks.size() == 1);
    assert(client.quickLockpicks[0].request == "100-2-3");
    assert(client.quickLockpicks[0].initiator == 0x01c0000100000085ULL);
    assert(client.quickLockpicks[0].target == 0x01c000010000f15cULL);
    assert(client.quickLockpicks[0].targetNetId
        == 1125899906937610ULL);
    assert(client.leftClickInitiators.size() == 1);
    assert(client.leftClickInitiators[0].initiator
        == 0x01c0000100000085ULL);
    assert(client.leftClickInitiators[0].eligible);
    assert(client.lockedTargets.size() == 1);
    assert(client.lockedTargets[0].target == 0x01c000010000f15cULL);
    assert(client.lockedTargets[0].netId == 1125899906937610ULL);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "eligible=1\t2\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "eligible=0\t1\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\t0\nend=1\n").valid);
    auto const wideNetId = ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\t4294967296\nend=1\n");
    assert(wideNetId.valid);
    assert(wideNetId.lockedTargets[0].netId == 4294967296ULL);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=bad token\t1\t2\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t0\t2\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t1\t2\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t1\t0\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t1\t2\t0\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t1\t2\t3\textra\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\t1\t2\t18446744073709551616\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "eligible=not-hex\t1\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "eligible=1\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "eligible=1\t1\textra\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=not-hex\t1\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\t1\textra\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\tnot-decimal\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "locked=1\t18446744073709551616\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=6\npak_version=2.0.0\nnative_session=x\n"
        "end=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=1.0.0\nnative_session=x\n"
        "end=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n").valid);
    auto const maximumClientValues = ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "quick=request\tffffffffffffffff\tfffffffffffffffe"
        "\t18446744073709551615\n"
        "eligible=ffffffffffffffff\t0\n"
        "locked=fffffffffffffffe\t18446744073709551615\n"
        "end=1\n");
    assert(maximumClientValues.valid);
    assert(maximumClientValues.quickLockpicks[0].initiator
        == 0xffffffffffffffffULL);
    assert(maximumClientValues.quickLockpicks[0].target
        == 0xfffffffffffffffeULL);
    assert(maximumClientValues.quickLockpicks[0].targetNetId
        == 0xffffffffffffffffULL);
    assert(!maximumClientValues.leftClickInitiators[0].eligible);
    assert(maximumClientValues.lockedTargets[0].netId
        == 0xffffffffffffffffULL);
    auto leftClickSnapshot = BuildLeftClickRoutingSnapshot(client);
    assert(leftClickSnapshot.valid);
    assert(leftClickSnapshot.nativeSession == "44-55");
    assert(leftClickSnapshot.initiators.at(0x01c0000100000085ULL));
    assert(leftClickSnapshot.targets.at(0x01c000010000f15cULL)
        == 1125899906937610ULL);
    auto const resolvedLeftClickTarget = ResolveLeftClickTarget(
        leftClickSnapshot,
        "44-55",
        0x01c0000100000085ULL,
        0x01c000010000f15cULL);
    assert(resolvedLeftClickTarget.has_value());
    assert(*resolvedLeftClickTarget == 1125899906937610ULL);
    assert(!ResolveLeftClickTarget(
        leftClickSnapshot,
        "wrong-session",
        0x01c0000100000085ULL,
        0x01c000010000f15cULL).has_value());
    assert(!ResolveLeftClickTarget(
        leftClickSnapshot,
        "44-55",
        0x01c0000100000999ULL,
        0x01c000010000f15cULL).has_value());
    assert(!ResolveLeftClickTarget(
        leftClickSnapshot,
        "44-55",
        0x01c0000100000085ULL,
        0x01c0000100000999ULL).has_value());
    auto duplicateInitiatorDocument = client;
    duplicateInitiatorDocument.leftClickInitiators.push_back(
        client.leftClickInitiators[0]);
    assert(!BuildLeftClickRoutingSnapshot(
        duplicateInitiatorDocument).valid);
    auto duplicateTargetDocument = client;
    duplicateTargetDocument.lockedTargets.push_back(
        client.lockedTargets[0]);
    assert(!BuildLeftClickRoutingSnapshot(duplicateTargetDocument).valid);
    auto invalidLeftClickDocument = client;
    invalidLeftClickDocument.valid = false;
    assert(!BuildLeftClickRoutingSnapshot(invalidLeftClickDocument).valid);
    auto emptyLeftClickDocument = client;
    emptyLeftClickDocument.leftClickInitiators.clear();
    emptyLeftClickDocument.lockedTargets.clear();
    auto emptyLeftClickSnapshot =
        BuildLeftClickRoutingSnapshot(emptyLeftClickDocument);
    assert(emptyLeftClickSnapshot.valid);
    assert(emptyLeftClickSnapshot.initiators.empty());
    assert(emptyLeftClickSnapshot.targets.empty());
    auto ineligibleLeftClickDocument = client;
    ineligibleLeftClickDocument.leftClickInitiators[0].eligible = false;
    auto ineligibleLeftClickSnapshot =
        BuildLeftClickRoutingSnapshot(ineligibleLeftClickDocument);
    assert(ineligibleLeftClickSnapshot.valid);
    assert(!ineligibleLeftClickSnapshot.initiators.at(
        0x01c0000100000085ULL));
    assert(!ResolveLeftClickTarget(
        ineligibleLeftClickSnapshot,
        "44-55",
        0x01c0000100000085ULL,
        0x01c000010000f15cULL).has_value());

    std::unordered_set<std::string> consumedRequests{
        "active-a",
        "active-b",
        "stale",
    };
    std::vector<QuickLockpickRequest> activeRequests{
        QuickLockpickRequest{ .request = "active-a" },
        QuickLockpickRequest{ .request = "active-b" },
    };
    PruneConsumedQuickLockpicks(consumedRequests, activeRequests);
    assert(consumedRequests.size() == 2);
    assert(consumedRequests.contains("active-a"));
    assert(consumedRequests.contains("active-b"));
    activeRequests.erase(activeRequests.begin());
    PruneConsumedQuickLockpicks(consumedRequests, activeRequests);
    assert(consumedRequests.size() == 1);
    assert(consumedRequests.contains("active-b"));
    activeRequests.clear();
    PruneConsumedQuickLockpicks(consumedRequests, activeRequests);
    assert(consumedRequests.empty());
    for (std::size_t index = 0; index < 128; ++index) {
        auto request = "active-" + std::to_string(index);
        consumedRequests.insert(request);
        activeRequests.push_back(
            QuickLockpickRequest{ .request = std::move(request) });
    }
    consumedRequests.insert("stale-large-set");
    PruneConsumedQuickLockpicks(consumedRequests, activeRequests);
    assert(consumedRequests.size() == 128);
    for (auto const& request : activeRequests) {
        assert(consumedRequests.contains(request.request));
    }
    activeRequests.erase(activeRequests.begin(), activeRequests.begin() + 64);
    PruneConsumedQuickLockpicks(consumedRequests, activeRequests);
    assert(consumedRequests.size() == 64);
    for (auto const& request : activeRequests) {
        assert(consumedRequests.contains(request.request));
    }
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\n"
        "record=7\tuuid\t1\t2\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "record=0\tuuid\t1\t2\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "record=7\tuuid\t1\t0\t3\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "record=7\tuuid\t1\t2\tnot-hex\nend=1\n").valid);
    assert(!ParseClientBridgeDocument(
        "protocol=7\npak_version=2.0.0\nnative_session=x\n"
        "record=7\tuuid\t1\t2\t3\textra\nend=1\n").valid);
    RequestedRollIdentity clientIdentity{
        .roll = 0x01c0000200000100ULL,
        .roller = 0x01c0000100000085ULL,
        .subject = 0x01c000010000f15cULL,
        .rollUuid = "4dc3ec09-e11d-e030-cac3-99253090aaf8",
    };
    auto clientProfile = MatchProfileSelection(
        valid.records,
        client.records,
        clientIdentity);
    assert(clientProfile.has_value());
    assert(clientProfile->scope == ProfileScope::Client);
    assert(clientProfile->specialist == 0x01c00001000000d4ULL);
    assert(ClientPresentationAdvantage(*clientProfile).has_value());
    assert(*ClientPresentationAdvantage(*clientProfile) == 1);
    auto duplicateClientRecords = client.records;
    duplicateClientRecords.push_back(client.records[0]);
    assert(!MatchProfileSelection(
        valid.records,
        duplicateClientRecords,
        clientIdentity).has_value());
    assert(MatchesClientPresentationLease(
        clientIdentity,
        clientProfile->record.rollUuid,
        clientIdentity.roller,
        clientIdentity.subject,
        clientProfile->specialist));
    auto mismatchedLeaseIdentity = clientIdentity;
    mismatchedLeaseIdentity.rollUuid = "00000000-0000-0000-0000-000000000099";
    assert(!MatchesClientPresentationLease(
        mismatchedLeaseIdentity,
        clientProfile->record.rollUuid,
        clientIdentity.roller,
        clientIdentity.subject,
        clientProfile->specialist));
    mismatchedLeaseIdentity = clientIdentity;
    mismatchedLeaseIdentity.roller += 1;
    assert(!MatchesClientPresentationLease(
        mismatchedLeaseIdentity,
        clientProfile->record.rollUuid,
        clientIdentity.roller,
        clientIdentity.subject,
        clientProfile->specialist));
    mismatchedLeaseIdentity = clientIdentity;
    mismatchedLeaseIdentity.subject += 1;
    assert(!MatchesClientPresentationLease(
        mismatchedLeaseIdentity,
        clientProfile->record.rollUuid,
        clientIdentity.roller,
        clientIdentity.subject,
        clientProfile->specialist));
    assert(!MatchesClientPresentationLease(
        clientIdentity,
        clientProfile->record.rollUuid,
        clientIdentity.roller,
        clientIdentity.subject,
        clientIdentity.roller));
    assert(ShouldPreserveTransientRollBonus(
        true, true, true, 1, true, true));
    assert(!ShouldPreserveTransientRollBonus(
        false, true, true, 1, true, true));
    assert(!ShouldPreserveTransientRollBonus(
        true, false, true, 1, true, true));
    assert(!ShouldPreserveTransientRollBonus(
        true, true, false, 1, true, true));
    assert(!ShouldPreserveTransientRollBonus(
        true, true, true, 0, true, true));
    assert(!ShouldPreserveTransientRollBonus(
        true, true, true, 1, false, true));
    assert(!ShouldPreserveTransientRollBonus(
        true, true, true, 1, true, false));
    assert(ShouldPromoteMissingSelectedRollBonus(
        true, true, true, true, 1, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        false, true, true, true, 1, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        true, false, true, true, 1, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        true, true, false, true, 1, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        true, true, true, false, 1, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        true, true, true, true, 0, true));
    assert(!ShouldPromoteMissingSelectedRollBonus(
        true, true, true, true, 1, false));
    assert(ShouldPreserveAdvantageModifierPresentation(
        1, 1, 0, 0));
    assert(ShouldPreserveAdvantageModifierPresentation(
        2, 2, 0, 1));
    assert(!ShouldPreserveAdvantageModifierPresentation(
        0, 1, 0, 0));
    assert(!ShouldPreserveAdvantageModifierPresentation(
        1, 2, 0, 0));
    assert(!ShouldPreserveAdvantageModifierPresentation(
        1, 1, 1, 0));
    assert(!ShouldPreserveAdvantageModifierPresentation(
        1, 1, 0, 3));
    assert(ShouldPreserveAdvantageSourceModifier(
        1, 3, 0, 0, true));
    assert(ShouldPreserveAdvantageSourceModifier(
        2, 3, 0, 1, true));
    assert(!ShouldPreserveAdvantageSourceModifier(
        0, 3, 0, 0, true));
    assert(!ShouldPreserveAdvantageSourceModifier(
        1, 2, 0, 0, true));
    assert(!ShouldPreserveAdvantageSourceModifier(
        1, 3, 1, 0, true));
    assert(!ShouldPreserveAdvantageSourceModifier(
        1, 3, 0, 3, true));
    assert(!ShouldPreserveAdvantageSourceModifier(
        1, 3, 0, 0, false));
    for (int exact = 0; exact <= 1; ++exact) {
        for (int enabled = 0; enabled <= 1; ++enabled) {
            for (int selected = 0; selected <= 1; ++selected) {
                for (int dice = 0; dice <= 1; ++dice) {
                    for (int primary = 0; primary <= 1; ++primary) {
                        for (int selectedSet = 0;
                             selectedSet <= 1; ++selectedSet) {
                            auto const expected = exact && enabled
                                && selected && dice && primary
                                && selectedSet;
                            assert(ShouldPreserveTransientRollBonus(
                                exact != 0, enabled != 0, selected != 0,
                                static_cast<std::uint8_t>(dice),
                                primary != 0, selectedSet != 0)
                                == expected);
                        }
                    }
                }
            }
        }
    }
    for (int exact = 0; exact <= 1; ++exact) {
        for (int invisible = 0; invisible <= 1; ++invisible) {
            for (int enabled = 0; enabled <= 1; ++enabled) {
                for (int selected = 0; selected <= 1; ++selected) {
                    for (int dice = 0; dice <= 1; ++dice) {
                        for (int missing = 0; missing <= 1; ++missing) {
                            auto const expected = exact && invisible
                                && enabled && selected && dice && missing;
                            assert(ShouldPromoteMissingSelectedRollBonus(
                                exact != 0, invisible != 0, enabled != 0,
                                selected != 0,
                                static_cast<std::uint8_t>(dice),
                                missing != 0) == expected);
                        }
                    }
                }
            }
        }
    }
    for (std::uint8_t expected = 0; expected <= 3; ++expected) {
        for (std::uint8_t observed = 0; observed <= 3; ++observed) {
            for (std::uint8_t disabled = 0; disabled <= 1; ++disabled) {
                for (std::uint8_t state = 0; state <= 3; ++state) {
                    auto const preserveExpected = expected >= 1
                        && expected <= 2 && observed == expected
                        && disabled == 0 && state != 3;
                    assert(ShouldPreserveAdvantageModifierPresentation(
                        expected, observed, disabled, state)
                        == preserveExpected);
                    for (int hasSource = 0; hasSource <= 1; ++hasSource) {
                        auto const sourceExpected = expected >= 1
                            && expected <= 2 && observed == 3
                            && disabled == 0 && state != 3
                            && hasSource != 0;
                        assert(ShouldPreserveAdvantageSourceModifier(
                            expected, observed, disabled, state,
                            hasSource != 0) == sourceExpected);
                    }
                }
            }
        }
    }
    auto serverProfile = MatchProfileSelection(
        valid.records,
        std::span<ClientActionRecord const>{},
        identity);
    assert(serverProfile.has_value());
    assert(serverProfile->scope == ProfileScope::Server);
    assert(!ClientPresentationAdvantage(*serverProfile).has_value());
    clientIdentity.subject = 0x01c000010000ae68ULL;
    assert(!MatchProfileSelection(
        valid.records,
        client.records,
        clientIdentity).has_value());

    std::array<std::uint8_t, 16> guidBytes{
        0x09, 0xec, 0xc3, 0x4d,
        0x1d, 0xe1,
        0x30, 0xe0,
        0xc3, 0xca,
        0x25, 0x99, 0x90, 0x30, 0xf8, 0xaa,
    };
    assert(FormatGuid(guidBytes) == "4dc3ec09-e11d-e030-cac3-99253090aaf8");

    std::cout << "Bridge protocol tests passed\n";
    return 0;
}
