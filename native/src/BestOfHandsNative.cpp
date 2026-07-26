// SPDX-License-Identifier: Unlicense
#include "BridgeProtocol.h"
#include "FixedSnapshot.h"
#include "ProfileRouting.h"
#include "SafeMemory.h"

#include <Windows.h>
#include <ShlObj.h>
#include <safetyhook.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace boh = best_of_hands;
namespace fs = std::filesystem;

namespace {

using boh::FixedSnapshot;
using SystemUpdateProc = void (*)(void* system, void* world, void* gameTime);
using ClientModifierCollectionAddProc = void (*)(void*, void*);
using ClientModifierCollectionRemoveProc = bool (*)(void*, void*);
using ClientModifierCollectionGetProc = void* (*)(void*, std::int32_t);
using ClientSelectedModifierValueProc = void* (*)(void*);
constexpr std::size_t kWorldSystemsBufferOffset = 0x30;
constexpr std::size_t kWorldSystemsCountOffset = 0x3c;
constexpr std::size_t kSystemEntrySize = 0xf8;
constexpr std::size_t kSystemEntryUpdateOffset = 0x18;
constexpr std::size_t kRequestedRollRollEntityOffset = 0x00;
constexpr std::size_t kRequestedRollRollUuidOffset = 0x08;
constexpr std::size_t kRequestedRollRollerOffset = 0x20;
constexpr std::size_t kRequestedRollAdvantageOffset = 0x40;
constexpr std::size_t kRequestedRollSubjectOffset = 0x60;
constexpr std::size_t kMinimumRequestedRollBytes = 0x68;
constexpr std::size_t kActiveRollStateOffset = 0x7a8;
constexpr std::size_t kActiveRollDisplayedValueOffset = 0x868;
constexpr std::size_t kActiveRollImmediateTotalOffset = 0xd58;
constexpr std::size_t kActiveRollFallbackOffset = 0x8f8;
constexpr std::size_t kActiveRollVmRollOffset = 0x940;
constexpr std::size_t kActiveRollDynamicModifierCollectionOffset = 0xb98;
constexpr std::size_t kVmRollAdvantageOffset = 0x170;
constexpr std::size_t kVmRollDynamicModifierCollectionOffset = 0x178;
constexpr std::size_t kObservableCollectionBackingOffset = 0x18;
constexpr std::size_t kObservableCollectionBackingCountOffset = 0x20;
constexpr std::size_t kRollResultNaturalOffset = 0x42;
constexpr std::size_t kRollResultDiscardedOffset = 0x43;
constexpr std::size_t kRollResultModifierOffset = 0x44;
constexpr std::size_t kMinimumRollResultBytes = 0x45;
constexpr std::size_t kRollResultResolvedBonusesOffset = 0x68;
constexpr std::size_t kRollResultResolvedBonusCapacityOffset = 0x70;
constexpr std::size_t kRollResultResolvedBonusCountOffset = 0x74;
constexpr std::size_t kResolvedRollBonusSize = 0x18;
constexpr std::size_t kResolvedRollBonusDiceSizeOffset = 0x00;
constexpr std::size_t kResolvedRollBonusDiceCountOffset = 0x01;
constexpr std::size_t kResolvedRollBonusValueOffset = 0x04;
constexpr std::size_t kRollModifiersStaticModifiersOffset = 0x20;
constexpr std::size_t kRollModifiersStaticModifierCountOffset = 0x2c;
constexpr std::size_t kStaticModifierDisabledOffset = 0x10;
constexpr std::size_t kRollModifiersDynamicModifiersOffset = 0x08;
constexpr std::size_t kRollModifiersDynamicModifiers2Offset = 0x30;
constexpr std::size_t kRollModifiersDynamicModifiers3Offset = 0x80;
constexpr std::size_t kDynamicModifierIdSize = 0x18;
constexpr std::size_t kDynamicModifierIdTypeOffset = 0x10;
constexpr std::size_t kStaticModifierSize = 0x90;
constexpr std::size_t kDynamicModifierVmVisibilitySourceOffset = 0x60;
constexpr std::size_t kDynamicModifierVmVisibleOffset = 0x68;
constexpr std::size_t kDynamicModifierVmVisibilityMarkerOffset = 0x6c;
// VMBoostModifier, used by DCActiveRoll.SelectedBoostModifierList and the
// nested BoostModifierList entries, is not VMRollModifier. Reflection maps its
// result-facing SourceVM at +048h, DiceTypeSet at +0E0h, Owner at +100h, and
// dynamic identity at +110h. VMRollModifier instead stores DiceTypeSet at
// +110h, BoostType at +130h, SourceType at +148h, SourceVM at +1C8h, and its
// result-facing modifier GUID at +1D8h.
constexpr std::size_t kSelectedBoostVmSourceVmOffset = 0x48;
constexpr std::size_t kSelectedBoostVmDiceTypeSetOffset = 0xe0;
constexpr std::size_t kSelectedBoostVmIdentityOffset = 0x110;
constexpr std::size_t kDynamicModifierVmNamePropertySourceOffset = 0xe0;
constexpr std::size_t kDynamicModifierVmNameValueOffset = 0xe8;
constexpr std::size_t kDynamicModifierVmNamePropertyMarkerOffset = 0xfc;
constexpr std::size_t kDynamicModifierVmValuePropertySourceOffset = 0xb8;
constexpr std::size_t kDynamicModifierVmValueOffset = 0xc0;
constexpr std::size_t kDynamicModifierVmValuePropertyMarkerOffset = 0xc8;
constexpr std::size_t kDynamicModifierVmDiceTypeSetPropertyOffset = 0x100;
constexpr std::size_t kDynamicModifierVmDiceTypeSetOffset = 0x110;
constexpr std::size_t kDynamicModifierVmBoostTypePropertySourceOffset = 0x128;
constexpr std::size_t kDynamicModifierVmBoostTypeOffset = 0x130;
constexpr std::size_t kDynamicModifierVmBoostTypePropertyMarkerOffset = 0x134;
constexpr std::size_t kDynamicModifierVmSourceTypePropertySourceOffset = 0x140;
constexpr std::size_t kDynamicModifierVmSourceTypeOffset = 0x148;
constexpr std::size_t kDynamicModifierVmSourceTypePropertyMarkerOffset = 0x14c;
constexpr std::size_t kDynamicModifierVmPropertySourceOffset = 0x1a8;
constexpr std::size_t kDynamicModifierVmDisabledOffset = 0x1b0;
constexpr std::size_t kDynamicModifierVmPropertyMarkerOffset = 0x1b4;
constexpr std::size_t kDynamicModifierVmSourceVmOffset = 0x1c8;
constexpr std::size_t kDynamicModifierVmGuidOffset = 0x1d8;
constexpr std::size_t kDynamicModifierVmStateOffset = 0x1e8;
// VMAdvantage is the dedicated source row rendered in VMRoll.Advantages. It
// is distinct from VMRollModifier: AdvantageType is at +48h, Disabled at
// +88h, its icon-bearing SourceVM at +A0h, TagReason at +C0h, source identity
// at +D0h, and animation state at +E0h.
constexpr std::size_t kAdvantageVmTypeOffset = 0x48;
constexpr std::size_t kAdvantageVmDisabledOffset = 0x88;
constexpr std::size_t kAdvantageVmSourceVmOffset = 0xa0;
constexpr std::size_t kAdvantageVmTagReasonOffset = 0xc0;
constexpr std::size_t kAdvantageVmIdentityOffset = 0xd0;
constexpr std::size_t kAdvantageVmStateOffset = 0xe0;
constexpr std::size_t kAdvantageVmTraceBytes = 0xe8;
constexpr std::size_t kSelectedModifierResolvedValueOffset = 0xb0;
constexpr std::uint8_t kDynamicModifierRollBonusType = 2;
constexpr std::uint8_t kDynamicModifierRollBonusSourceType = 2;
constexpr std::size_t kDynamicModifierDescriptorDiceSizeOffset = 0x48;
constexpr std::size_t kDynamicModifierDescriptorDiceCountOffset = 0x60;
constexpr std::size_t kModifierRefreshVmRollStackOffset = 0x90;
constexpr std::size_t kMaximumResolvedRollBonuses = 32;
constexpr std::size_t kMaximumObservedDynamicModifierViewModels = 64;
constexpr std::size_t kMaximumClientPresentationLeases = 64;
constexpr std::size_t kMaximumRetainedRollBonusViewModels = 16;
constexpr std::size_t kMaximumCachedRollBonusPresentations = 16;
constexpr std::size_t kMaximumQuickLockpickRequests = 64;
constexpr std::size_t kClientControllerOwnerOffset = 0x08;
constexpr std::size_t kClientControllerRunningTaskOffset = 0x50;
constexpr std::size_t kClientItemUseTargetOffset = 0x258;
constexpr std::size_t kClientLockpickTargetOffset = 0x250;
constexpr std::size_t kClientLockpickTargetNetIdOffset = 0x258;
constexpr std::size_t kClientLockpickStartedOffset = 0x260;
constexpr std::size_t kClientLockpickTargetSelectedOffset = 0x261;
constexpr std::size_t kClientLockpickCanLockpickOffset = 0x262;
constexpr std::uint32_t kClientItemUseTaskType = 7;
constexpr std::uint32_t kClientLockpickTaskType = 15;
constexpr std::size_t kDynamicModifierVmTraceBytes = 0x200;
constexpr std::size_t kDynamicModifierVmNameValueSize = 0x12;
// Noesis 3.1.7 reflection ABI used by BG3. The game subclasses expose
// presentation fields through TypeProperty even when different source
// viewmodel classes place those fields at different native offsets.
constexpr std::size_t kNoesisGetClassTypeVtableIndex = 2;
constexpr std::size_t kNoesisTypePropertyGetContentVtableIndex = 1;
constexpr std::size_t kNoesisTypeClassBaseOffset = 0x28;
constexpr std::size_t kNoesisTypeClassPropertiesOffset = 0x40;
constexpr std::size_t kNoesisVectorSizeOffset = 0x08;
constexpr std::size_t kNoesisTypePropertyNameSymbolOffset = 0x08;
constexpr std::size_t kNoesisTypePropertyContentTypeOffset = 0x10;
constexpr std::size_t kMaximumNoesisClassDepth = 16;
constexpr std::size_t kMaximumNoesisPropertiesPerClass = 512;
constexpr std::string_view kReportedHooks =
    "profile_ui,profile_math,client_roll_presentation,"
    "client_roll_aggregate,client_roll_start,"
    "client_roll_payload_ready,client_roll_post_dispatch,"
    "client_roll_result,"
    "client_roll_bonus_reconcile_start,"
    "client_roll_bonus_reconcile_viewmodel,"
    "client_roll_bonus_preserve_matched,"
    "client_roll_bonus_preserve_missing,"
    "client_advantage_preserve_matched,"
    "client_advantage_preserve_missing,"
    "client_roll_bonus_keep_selected,"
    "client_roll_bonus_renderer_add,"
    "client_roll_bonus_retain_selected,"
    "client_roll_bonus_presentation_transfer,"
    "client_roll_bonus_reconcile_end,"
    "client_roll_finalize";
constexpr std::string_view kReportedFeatures =
    "native_profile_substitution,quick_lockpick_task_adapter";

constexpr std::array<std::byte, 11> kProfileUiSignature{
    std::byte{0x4c}, std::byte{0x89}, std::byte{0x7d}, std::byte{0x10},
    std::byte{0x49}, std::byte{0x8b}, std::byte{0x17}, std::byte{0x49},
    std::byte{0x8b}, std::byte{0x0c}, std::byte{0x24},
};
constexpr std::array<std::byte, 12> kProfileMathSignature{
    std::byte{0x4d}, std::byte{0x8b}, std::byte{0x40}, std::byte{0x20},
    std::byte{0x4c}, std::byte{0x89}, std::byte{0x45}, std::byte{0x88},
    std::byte{0x49}, std::byte{0x8b}, std::byte{0x45}, std::byte{0x60},
};
// gui::DCActiveRoll copies RequestedRoll.AdvantageType from AL into
// VMRoll.RollAdvantageType and then builds the vanilla advantage/modifier
// viewmodels. Hooking the comparison preserves the real component while
// allowing the local presentation value to be replaced before notification.
constexpr std::array<std::byte, 15> kClientRollPresentationSignature{
    std::byte{0x38}, std::byte{0x83}, std::byte{0x70}, std::byte{0x01},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x74}, std::byte{0x20},
    std::byte{0x88}, std::byte{0x83}, std::byte{0x70}, std::byte{0x01},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x4c},
};
constexpr std::array<std::byte, 17> kClientRollStartSignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0xc4}, std::byte{0x55},
    std::byte{0x56}, std::byte{0x57}, std::byte{0x48}, std::byte{0x8d},
    std::byte{0x68}, std::byte{0xa1}, std::byte{0x48}, std::byte{0x81},
    std::byte{0xec}, std::byte{0xa0}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x00},
};
// WaitForStart has already copied the selected roll-bonus payload into the
// detached client command object at this site and is about to enqueue it.
// Preparing the result-facing row here cannot change which boost BG3 submits,
// and reaching this site proves that the successful dispatch branch was
// selected.
constexpr std::array<std::byte, 10> kClientRollPayloadReadySignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0x4b}, std::byte{0x08},
    std::byte{0x8b}, std::byte{0x91}, std::byte{0x18}, std::byte{0x04},
    std::byte{0x00}, std::byte{0x00},
};
// WaitForStart has returned from enqueueing the detached selected-bonus
// command at this site. The request can no longer observe any client
// presentation changes. Restoring the retained SelectedBoostModifierList
// wrapper here mirrors vanilla's two-list UI structure without resubmitting or
// duplicating the authoritative bonus.
constexpr std::array<std::byte, 16> kClientRollPostDispatchSignature{
    std::byte{0x4c}, std::byte{0x8b}, std::byte{0xb4}, std::byte{0x24},
    std::byte{0x98}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x4c}, std::byte{0x8b}, std::byte{0xac}, std::byte{0x24},
    std::byte{0xd8}, std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
};
// DCActiveRoll's modifier aggregation pass recomputes RollAdvantageType after
// the initial RequestedRoll copy and before result presentation. At this site:
//   r13 = DCActiveRoll
//   rdx = VMRoll
//   r14b = advantage reconstructed from the current modifier viewmodels
// Replacing r14b before the existing compare/store preserves BG3's own
// property notification and downstream animation/result path.
constexpr std::array<std::byte, 15> kClientRollAggregateSignature{
    std::byte{0x44}, std::byte{0x3a}, std::byte{0xb2},
    std::byte{0x70}, std::byte{0x01}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x74}, std::byte{0x25},
    std::byte{0x44}, std::byte{0x88}, std::byte{0xb2},
    std::byte{0x70}, std::byte{0x01}, std::byte{0x00},
};
// DCActiveRoll's replicated roll-result handler checks whether the result
// contains a discarded die exactly when VMRoll.RollAdvantageType says it
// should. A delegated RequestedRoll remains initiator-owned and therefore
// replicates its original `None` byte even though the server evaluated the
// specialist profile and returned two dice. That mismatch selects BG3's
// fallback result presentation: one animated die, disabled advantage/roll
// bonus modifiers, and a final value that appears before modifier animation.
//
// At this exact validated site:
//   rdi = DCActiveRoll
//   rax = VMRoll
//   rbx = the replicated roll-result payload
//   cl  = VMRoll.RollAdvantageType
// Correcting CL and the client-local presentation fields lets BG3 run its
// ordinary two-die and sequential-modifier result path without changing any
// numeric result value, server component, roller, target, or callback owner.
constexpr std::array<std::byte, 15> kClientRollResultSignature{
    std::byte{0x84}, std::byte{0xc9},
    std::byte{0x74}, std::byte{0x06},
    std::byte{0x80}, std::byte{0x7b}, std::byte{0x43}, std::byte{0x00},
    std::byte{0x75}, std::byte{0x14},
    std::byte{0x80}, std::byte{0x7b}, std::byte{0x42}, std::byte{0x00},
    std::byte{0x74},
};
// The result handler refreshes modifier viewmodels immediately before it
// reconciles authoritative ResolvedRollBonuses. A roll-UI spell selected for
// the initiator can be retargeted to the specialist by the server bridge; BG3
// then receives the correct resolved bonus under a new StaticModifier identity
// and disables the still-selected client viewmodel solely because its original
// GUID is absent. These three sites bracket that one refresh call and observe
// each dynamic modifier viewmodel returned by BG3's own collection accessor.
constexpr std::array<std::byte, 15> kClientRollBonusReconcileStartSignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0xd0},
    std::byte{0x48}, std::byte{0x8b}, std::byte{0xcf},
    std::byte{0xe8}, std::byte{0xaf}, std::byte{0x4a},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x84},
    std::byte{0xc0}, std::byte{0x74}, std::byte{0x0b},
};
constexpr std::array<std::byte, 15>
kClientRollBonusReconcileViewModelSignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0xf8},
    std::byte{0x48}, std::byte{0x85}, std::byte{0xc0},
    std::byte{0x0f}, std::byte{0x84}, std::byte{0xef},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x4c}, std::byte{0x39}, std::byte{0xa0},
};
// DCActiveRoll refreshes dynamic modifier viewmodels more than once while
// publishing a result. The first refresh can disable a selected initiator-side
// roll bonus after the server retargets it to the specialist, and the nested
// refresh immediately repeats that decision. Guarding the two original
// disable branches keeps the already-selected dice modifier in BG3's own
// collection across both passes. The subsequent vanilla result reconciler can
// then assign the authoritative ResolvedRollBonus and build its ordinary
// modifier animation.
constexpr std::array<std::byte, 15>
kClientRollBonusPreserveMatchedSignature{
    std::byte{0x3a}, std::byte{0xc1},
    std::byte{0x74}, std::byte{0x65},
    std::byte{0x88}, std::byte{0x8f}, std::byte{0xb0},
    std::byte{0x01}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x4c}, std::byte{0x8d}, std::byte{0x87},
    std::byte{0xb4}, std::byte{0x01},
};
constexpr std::array<std::byte, 15>
kClientRollBonusPreserveMissingSignature{
    std::byte{0x84}, std::byte{0xc0},
    std::byte{0x75}, std::byte{0x2b},
    std::byte{0xc6}, std::byte{0x87}, std::byte{0xb0},
    std::byte{0x01}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x01}, std::byte{0x4c}, std::byte{0x8d},
    std::byte{0x87}, std::byte{0xb4},
};
// The same native refresh has a second, type-specific loop for the
// VMAdvantage source rows rendered below the dice. Delegation intentionally
// leaves the initiator-owned modifier component unchanged, so that loop can
// fail to find the specialist's source and mark an otherwise valid Cat's
// Grace-style row disabled. Guarding only the two native disable decisions
// preserves the exact enabled advantage/disadvantage source already built by
// BG3 without touching VMRoll.Modifiers, selected roll bonuses, or result math.
constexpr std::array<std::byte, 15>
kClientAdvantagePreserveMatchedSignature{
    std::byte{0x3a}, std::byte{0xc1},
    std::byte{0x74}, std::byte{0x65},
    std::byte{0x88}, std::byte{0x8f}, std::byte{0x88},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x4c}, std::byte{0x8d}, std::byte{0x87},
    std::byte{0x8c}, std::byte{0x00},
};
constexpr std::array<std::byte, 15>
kClientAdvantagePreserveMissingSignature{
    std::byte{0x84}, std::byte{0xc0},
    std::byte{0x75}, std::byte{0x2b},
    std::byte{0xc6}, std::byte{0x87}, std::byte{0x88},
    std::byte{0x00}, std::byte{0x00}, std::byte{0x00},
    std::byte{0x01}, std::byte{0x4c}, std::byte{0x8d},
    std::byte{0x87}, std::byte{0x8c},
};
// A roll-UI-selected modifier is represented by BG3's original icon-bearing
// dynamic viewmodel. After the server retargets the modifier spell from the
// The native static-modifier renderer has completely populated one
// VMRollModifier at this site and is about to append it to VMRoll.Modifiers:
//   rsi = VMRollModifier
//   r14 = VMRoll.Modifiers
// Repairing a cached roll-bonus SourceVM here gives Noesis the icon before it
// first renders the pre-roll row. The six instruction bytes are identical in
// both supported executables; the executable identity and exact RVA still
// constrain the hook to this one call site.
constexpr std::array<std::byte, 6>
kClientRollBonusRendererAddSignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0xd6},
    std::byte{0x49}, std::byte{0x8b}, std::byte{0xce},
};
constexpr std::array<std::byte, 9> kClientModifierCollectionAddSignature{
    std::byte{0x40}, std::byte{0x53}, std::byte{0x55},
    std::byte{0x56}, std::byte{0x57}, std::byte{0x48},
    std::byte{0x83}, std::byte{0xec}, std::byte{0x28},
};
constexpr std::array<std::byte, 10> kClientModifierCollectionGetSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c},
    std::byte{0x24}, std::byte{0x10}, std::byte{0x57},
    std::byte{0x48}, std::byte{0x83}, std::byte{0xec},
    std::byte{0x20},
};
constexpr std::array<std::byte, 9>
kClientSelectedModifierValueSignature{
    std::byte{0x40}, std::byte{0x53}, std::byte{0x48},
    std::byte{0x83}, std::byte{0xec}, std::byte{0x20},
    std::byte{0x48}, std::byte{0x8b}, std::byte{0x05},
};
constexpr std::array<std::byte, 15> kClientRollBonusReconcileEndSignature{
    std::byte{0x84}, std::byte{0xc0}, std::byte{0x74},
    std::byte{0x0b}, std::byte{0x48}, std::byte{0x8b},
    std::byte{0xd6}, std::byte{0x48}, std::byte{0x8b},
    std::byte{0xcf}, std::byte{0xe8}, std::byte{0xc0},
    std::byte{0x4d}, std::byte{0x00}, std::byte{0x00},
};
// Before the result handler reaches this site it has already copied either the
// natural die or the final total into DCActiveRoll's displayed-value property,
// based on the client fallback flag at +0x8f8. The earlier result hook clears
// that flag for an exact delegated result so the natural value is published.
//
// After reconciling resolved/fixed bonuses against the modifier viewmodels,
// AL, r14b and r15b jointly decide whether to re-enable the "show final total
// immediately" fallback:
//   al   = every resolved/fixed result bonus matched a viewmodel
//   r14b = result modifier total lies within the displayed min/max range
//   r15b = the result's second die agrees with RollAdvantageType
// Delegation can make those client-only consistency checks fail because the
// replicated component remains initiator-owned. An exact delegated VMRoll
// lease plus a valid, internally consistent replicated result is required
// before this guard may preserve the normal path.
constexpr std::array<std::byte, 15> kClientRollFinalizeSignature{
    std::byte{0x84}, std::byte{0xc0},
    std::byte{0x74}, std::byte{0x0a},
    std::byte{0x45}, std::byte{0x84}, std::byte{0xf6},
    std::byte{0x74}, std::byte{0x05},
    std::byte{0x45}, std::byte{0x84}, std::byte{0xff},
    std::byte{0x75}, std::byte{0x59},
    std::byte{0x0f},
};
// DCActiveRoll maps RequestedRoll.Roller to the client-side source context
// used by both the ordinary modifier and VMAdvantage builders. Redirecting
// only this lookup makes status-owned presentation (including its icon)
// resolve against the delegated specialist without changing RequestedRoll,
// DCActiveRoll ownership, or the authoritative roll payload.
constexpr std::array<std::byte, 5> kClientRollSourceContextSignature{
    std::byte{0xe8}, std::byte{0x83}, std::byte{0xa0},
    std::byte{0xea}, std::byte{0xff},
};
constexpr std::array<std::byte, 9> kClientVmRollModifierFactorySignature{
    std::byte{0x48}, std::byte{0x83}, std::byte{0xec}, std::byte{0x28},
    std::byte{0xb9}, std::byte{0xf0}, std::byte{0x01}, std::byte{0x00},
    std::byte{0x00},
};
constexpr std::array<std::byte, 16>
kClientVmDiceTypeSetPropertySetterSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c}, std::byte{0x24},
    std::byte{0x08}, std::byte{0x57}, std::byte{0x48}, std::byte{0x83},
    std::byte{0xec}, std::byte{0x20}, std::byte{0x48}, std::byte{0x8b},
    std::byte{0xfa}, std::byte{0x48}, std::byte{0x8b}, std::byte{0xd9},
};
constexpr std::array<std::byte, 16>
kClientVmRollModifierSourceVmPropertySetterSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c},
    std::byte{0x24}, std::byte{0x08}, std::byte{0x57},
    std::byte{0x48}, std::byte{0x83}, std::byte{0xec},
    std::byte{0x20}, std::byte{0x48}, std::byte{0x8b},
    std::byte{0xfa}, std::byte{0x48}, std::byte{0x8b},
    std::byte{0xd9},
};
constexpr std::array<std::byte, 16>
kClientVmRollModifierNameValueAssignSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c},
    std::byte{0x24}, std::byte{0x10}, std::byte{0x48},
    std::byte{0x89}, std::byte{0x6c}, std::byte{0x24},
    std::byte{0x18}, std::byte{0x56}, std::byte{0x57},
    std::byte{0x41}, std::byte{0x56}, std::byte{0x48},
    std::byte{0x83},
};
constexpr std::array<std::byte, 24> kClientInputControllerUpdateSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c},
    std::byte{0x24}, std::byte{0x20}, std::byte{0x48},
    std::byte{0x89}, std::byte{0x54}, std::byte{0x24},
    std::byte{0x10}, std::byte{0x55}, std::byte{0x56},
    std::byte{0x57}, std::byte{0x41}, std::byte{0x54},
    std::byte{0x41}, std::byte{0x55}, std::byte{0x41},
    std::byte{0x56}, std::byte{0x41}, std::byte{0x57},
    std::byte{0x48}, std::byte{0x83}, std::byte{0xec},
};
// InputController::Update has finished ranking the reusable character tasks.
// At this boundary rsi is the controller and r15 is the selected task. It is
// deliberately before BG3 clears the non-selected tasks' Ready flags, prepares
// the winner, and installs it as RunningTask, so all three lifecycle stages
// observe the same substituted task.
constexpr std::array<std::byte, 16> kClientTaskSelectionSignature{
    std::byte{0x48}, std::byte{0x8b}, std::byte{0x46},
    std::byte{0x30}, std::byte{0x8b}, std::byte{0x4e},
    std::byte{0x3c}, std::byte{0x48}, std::byte{0x8d},
    std::byte{0x0c}, std::byte{0xc8}, std::byte{0x48},
    std::byte{0x3b}, std::byte{0xc1}, std::byte{0x74},
    std::byte{0x1e},
};
constexpr std::array<std::byte, 24> kClientSetRunningTaskSignature{
    std::byte{0x48}, std::byte{0x89}, std::byte{0x5c},
    std::byte{0x24}, std::byte{0x08}, std::byte{0x48},
    std::byte{0x89}, std::byte{0x74}, std::byte{0x24},
    std::byte{0x18}, std::byte{0x48}, std::byte{0x89},
    std::byte{0x7c}, std::byte{0x24}, std::byte{0x20},
    std::byte{0x55}, std::byte{0x41}, std::byte{0x54},
    std::byte{0x41}, std::byte{0x55}, std::byte{0x41},
    std::byte{0x56}, std::byte{0x41}, std::byte{0x57},
};
// ecl::InputController::GetCharacterTask(type) indexes the controller's
// native CharacterTask pointer array after rejecting the -1 sentinel.
constexpr std::array<std::byte, 16> kClientGetCharacterTaskSignature{
    std::byte{0x83}, std::byte{0xfa}, std::byte{0xff}, std::byte{0x74},
    std::byte{0x0c}, std::byte{0x48}, std::byte{0x8b}, std::byte{0x41},
    std::byte{0x30}, std::byte{0x48}, std::byte{0x63}, std::byte{0xd2},
    std::byte{0x48}, std::byte{0x8b}, std::byte{0x04}, std::byte{0xd0},
};

struct BuildSpec {
    wchar_t const* executable;
    std::uint32_t timestamp;
    std::uint32_t imageSize;
    std::uintptr_t serverGlobalRva;
    std::size_t serverWorldOffset;
    std::uintptr_t modifierSystemIndexRva;
    std::uintptr_t rollSystemIndexRva;
    std::uintptr_t profileUiHookRva;
    std::uintptr_t profileMathHookRva;
    std::uintptr_t clientRollPresentationHookRva;
    std::uintptr_t clientRollSourceContextHookRva;
    std::uintptr_t clientRollAggregateHookRva;
    std::uintptr_t clientRollStartHookRva;
    std::uintptr_t clientRollPayloadReadyHookRva;
    std::uintptr_t clientRollPostDispatchHookRva;
    std::uintptr_t clientRollResultHookRva;
    std::uintptr_t clientRollBonusReconcileStartHookRva;
    std::uintptr_t clientRollBonusReconcileViewModelHookRva;
    std::uintptr_t clientRollBonusPreserveMatchedHookRva;
    std::uintptr_t clientRollBonusPreserveMissingHookRva;
    std::uintptr_t clientAdvantagePreserveMatchedHookRva;
    std::uintptr_t clientAdvantagePreserveMissingHookRva;
    std::uintptr_t clientRollBonusPreserveSelectedHookRva;
    std::uintptr_t clientRollBonusRendererAddHookRva;
    std::uintptr_t clientRollBonusReconcileEndHookRva;
    std::uintptr_t clientRollFinalizeHookRva;
    std::uintptr_t clientPropertyChangedRva;
    std::uintptr_t clientModifierDisabledPropertyRva;
    std::uintptr_t clientModifierCollectionAddRva;
    std::uintptr_t clientModifierCollectionRemoveRva;
    std::uintptr_t clientModifierCollectionGetRva;
    std::uintptr_t clientVmRollModifierCollectionAddRva;
    std::uintptr_t clientVmRollModifierCollectionRemoveRva;
    std::uintptr_t clientVmRollModifierCollectionGetRva;
    std::uintptr_t clientSelectedModifierValueRva;
    std::uintptr_t clientVmRollModifierFactoryRva;
    std::uintptr_t clientVmDiceTypeSetPropertySetterRva;
    std::uintptr_t clientVmRollModifierSourceVmPropertySetterRva;
    std::uintptr_t clientVmRollModifierNameValueAssignRva;
    std::uintptr_t clientTaskSelectionHookRva;
    std::uintptr_t clientInputControllerUpdateRva;
    std::uintptr_t clientGetCharacterTaskRva;
    std::uintptr_t clientSetRunningTaskRva;
};

// Patch 8 / Hotfix 36, game version v4.72.9.685. Each entry is guarded by
// executable identity, PE timestamp, SizeOfImage and exact hook-site bytes.
// Unknown or changed binaries remain completely unmodified.
constexpr BuildSpec kBuilds[] = {
    {
        L"bg3_dx11.exe", 0x69b45801, 0x06592000,
        0x05fcf2d0, 0x2b0,
        0x060b7d04, 0x0602ef7c,
        0x032cb8fa, 0x0328e0d4,
        0x01540996, 0x01540a28, 0x01546449, 0x015414d0,
        0x015418f6, 0x01541905,
        0x01541f7e,
        0x01541f56, 0x01546a70, 0x01546b02, 0x01546b3c,
        0x01546c96, 0x01546cd0,
        0x0154694c, 0x01690292,
        0x01541f61, 0x01542128,
        0x020e6fb0, 0x05fee9e8, 0x015485c0,
        0x015486e0, 0x01548530, 0x0133ae40, 0x0133a790,
        0x01548420, 0x01549880, 0x01222c60,
        0x012e6990, 0x0147f980, 0x040f3040,
        0x01b3a29f,
        0x01b38780, 0x01b37d00, 0x01b37d20,
    },
    {
        L"bg3.exe", 0x69b455b9, 0x0681c000,
        0x06258c38, 0x2b0,
        0x063416c4, 0x062b8934,
        0x032cb3ea, 0x0328dbc4,
        0x01541896, 0x01541928, 0x01547349, 0x015423d0,
        0x015427f6, 0x01542805,
        0x01542e7e,
        0x01542e56, 0x01547970, 0x01547a02, 0x01547a3c,
        0x01547b96, 0x01547bd0,
        0x0154784c, 0x01691172,
        0x01542e61, 0x01543028,
        0x020e7c70, 0x062782a0, 0x015494c0,
        0x015495e0, 0x01549430, 0x0133bd50, 0x0133b6a0,
        0x01549320, 0x0154a780, 0x01223b70,
        0x012e78a0, 0x01480880, 0x04128e60,
        0x01b3b4bf,
        0x01b399a0, 0x01b38f20, 0x01b38f40,
    },
};

struct ClientPresentationLease {
    std::shared_ptr<boh::ProfileSelection const> selection;
    std::uint64_t roller{};
    std::uint64_t subject{};
    std::uintptr_t vmRoll{};
    std::uint8_t frozenAdvantage{ 0xff };
    bool presentationFrozen{};
    std::array<std::uintptr_t, kMaximumRetainedRollBonusViewModels>
        retainedRollBonusViewModels{};
    std::size_t retainedRollBonusViewModelCount{};
    bool selectedRemovalGuardArmed{};
    std::uint64_t lastUsedTick{};
};

struct ClientPresentationLeaseSnapshot {
    std::shared_ptr<boh::ProfileSelection const> selection;
    std::uint8_t frozenAdvantage{ 0xff };
    bool presentationFrozen{};
    std::size_t retainedRollBonusViewModelCount{};
};

struct CachedRollBonusPresentation {
    std::uint64_t specialist{};
    std::uintptr_t selectedViewModel{};
    std::array<std::uint64_t, 2> identityGuid{};
    std::uint8_t identityType{};
    std::uint8_t diceSize{};
    std::uint8_t diceCount{};
    std::uint64_t lastUsedTick{};
};

using CachedRollBonusPresentationSnapshot =
    FixedSnapshot<CachedRollBonusPresentation,
        kMaximumCachedRollBonusPresentations>;
using ClientModifierCollectionSnapshot =
    FixedSnapshot<std::uintptr_t,
        kMaximumObservedDynamicModifierViewModels>;

HMODULE g_gameModule{};
BuildSpec const* g_build{};
std::atomic_bool g_stop{false};
std::atomic_bool g_codeHooksReady{false};
std::atomic_bool g_hooksReady{false};
std::atomic<void*> g_serverWorld{};

constexpr bool TraceEnabled() noexcept
{
    return false;
}

SystemUpdateProc g_modifierOriginal{};
SystemUpdateProc g_rollOriginal{};
void** g_modifierUpdateSlot{};
void** g_rollUpdateSlot{};
safetyhook::MidHook g_profileUiHook{};
safetyhook::MidHook g_profileMathHook{};
safetyhook::MidHook g_clientRollPresentationHook{};
safetyhook::MidHook g_clientRollSourceContextHook{};
safetyhook::MidHook g_clientRollAggregateHook{};
safetyhook::MidHook g_clientRollStartHook{};
safetyhook::MidHook g_clientRollPayloadReadyHook{};
safetyhook::MidHook g_clientRollPostDispatchHook{};
safetyhook::MidHook g_clientRollResultHook{};
safetyhook::MidHook g_clientRollBonusReconcileStartHook{};
safetyhook::MidHook g_clientRollBonusReconcileViewModelHook{};
safetyhook::MidHook g_clientRollBonusPreserveMatchedHook{};
safetyhook::MidHook g_clientRollBonusPreserveMissingHook{};
safetyhook::MidHook g_clientAdvantagePreserveMatchedHook{};
safetyhook::MidHook g_clientAdvantagePreserveMissingHook{};
safetyhook::InlineHook g_clientRollBonusKeepSelectedHook{};
safetyhook::MidHook g_clientRollBonusRendererAddHook{};
safetyhook::MidHook g_clientRollBonusReconcileEndHook{};
safetyhook::MidHook g_clientRollFinalizeHook{};
safetyhook::MidHook g_clientTaskSelectionHook{};
safetyhook::InlineHook g_clientInputControllerUpdateHook{};
std::atomic_bool g_quickLockpickPending{false};
std::mutex g_quickLockpickMutex;
std::unordered_set<std::string> g_consumedQuickLockpicks;
std::deque<std::string> g_consumedQuickLockpickOrder;
struct ResolvedBonusObservation {
    std::uint8_t diceSize{};
    std::uint8_t diceCount{};
    std::int32_t value{};
    bool consumed{};
};

struct DynamicModifierViewModelObservation {
    std::uintptr_t viewModel{};
    std::array<std::uint64_t, 2> guid{};
    // The tracing branch retains the full raw viewmodel snapshot. Production
    // builds keep no bytes here, so every modifier no longer adds 512 bytes
    // to the click-boundary reconciliation copy.
    std::array<std::byte,
        TraceEnabled() ? kDynamicModifierVmTraceBytes : 0> raw{};
    std::uint8_t disabledBefore{};
    std::uint8_t stateBefore{};
    std::uint8_t diceSize{};
    std::uint8_t diceCount{};
    bool descriptorReadable{};
    bool rawReadable{};
};
static_assert(TraceEnabled()
    || sizeof(DynamicModifierViewModelObservation) <= 40);

struct DynamicModifierIdentity {
    std::array<std::uint64_t, 2> guid{};
    std::uint8_t type{};
};
static_assert(sizeof(DynamicModifierIdentity) == kDynamicModifierIdSize);

struct RollBonusReconciliationObservation {
    bool active{};
    bool delegated{};
    std::uintptr_t activeRoll{};
    std::uintptr_t resultPayload{};
    std::uintptr_t modifiersComponent{};
    std::uintptr_t vmRoll{};
    std::array<ResolvedBonusObservation,
        kMaximumResolvedRollBonuses> bonuses{};
    std::size_t bonusCount{};
    std::array<DynamicModifierViewModelObservation,
        kMaximumObservedDynamicModifierViewModels> viewModels{};
    std::size_t viewModelCount{};
    boh::ProfileSelection selection;
};
static_assert(TraceEnabled()
    || sizeof(RollBonusReconciliationObservation) <= 4096);

thread_local RollBonusReconciliationObservation
    g_rollBonusReconciliationObservation;
thread_local std::uintptr_t g_pendingRollPayloadActiveRoll{};
thread_local std::uintptr_t g_pendingRollPayloadVmRoll{};
thread_local std::uintptr_t g_pendingRollPostDispatchActiveRoll{};
thread_local std::uintptr_t g_pendingRollPostDispatchVmRoll{};
std::wstring g_session;
std::string g_sessionUtf8;
fs::path g_actionPath;
fs::path g_clientActionPath;
fs::path g_leftClickActionPath;
fs::path g_statusPath;
fs::path g_logPath;
std::mutex g_logMutex;
std::mutex g_statusMutex;
std::mutex g_documentRefreshMutex;
std::mutex g_clientDocumentRefreshMutex;
std::mutex g_leftClickDocumentRefreshMutex;
std::mutex g_hookFailureMutex;
std::shared_mutex g_documentMutex;
boh::BridgeDocument g_document;
std::shared_mutex g_clientDocumentMutex;
boh::ClientBridgeDocument g_clientDocument;
std::shared_mutex g_leftClickDocumentMutex;
boh::ClientBridgeDocument g_leftClickDocument;
std::string g_hookFailure;
std::optional<fs::file_time_type> g_actionWriteTime;
std::optional<fs::file_time_type> g_clientActionWriteTime;
std::optional<fs::file_time_type> g_leftClickActionWriteTime;
std::mutex g_profileTraceMutex;
std::unordered_map<std::uint64_t, std::uint64_t> g_profilePasses;
std::mutex g_clientPresentationLeaseMutex;
std::unordered_map<std::string, ClientPresentationLease>
    g_clientPresentationLeases;
std::unordered_map<std::uintptr_t, std::string>
    g_clientPresentationLeaseByVmRoll;
std::vector<CachedRollBonusPresentation>
    g_cachedRollBonusPresentations;
std::vector<std::uintptr_t> g_deferredClientViewModelReleases;

// The opt-in profiler touches only fixed atomic storage and
// QueryPerformanceCounter in hot hooks. The worker thread formats and writes
// one summary after the roll finishes. Normal release builds compile it out.
constexpr bool kPerfDiagnostics =
    BEST_OF_HANDS_PERF_DIAGNOSTICS != 0;

enum class PerfMetric : std::size_t {
    MemoryProbe,
    LeaseLookup,
    AdvantageLookup,
    ProfileUi,
    ProfileMath,
    Aggregate,
    RollStart,
    DrainReleases,
    CaptureSelected,
    PayloadReady,
    ArmSelected,
    PostDispatch,
    RestoreSelected,
    Result,
    ReconcileStart,
    ReconcileViewModel,
    PreserveMatched,
    PreserveMissing,
    AdvantageMatched,
    AdvantageMissing,
    RendererAdd,
    ReconcileEnd,
    Finalize,
    SnapshotCollection,
    BindPresentation,
    SetByteProperty,
    SetPresentationType,
    SetNamePresentation,
    SetResolvedValue,
    Count,
};

constexpr std::array<std::string_view,
    static_cast<std::size_t>(PerfMetric::Count)> kPerfMetricNames{
    "memory_probe",
    "lease_lookup",
    "advantage_lookup",
    "profile_ui",
    "profile_math",
    "aggregate",
    "roll_start",
    "drain_releases",
    "capture_selected",
    "payload_ready",
    "arm_selected",
    "post_dispatch",
    "restore_selected",
    "result",
    "reconcile_start",
    "reconcile_view_model",
    "preserve_matched",
    "preserve_missing",
    "advantage_matched",
    "advantage_missing",
    "renderer_add",
    "reconcile_end",
    "finalize",
    "snapshot_collection",
    "bind_presentation",
    "set_byte_property",
    "set_presentation_type",
    "set_name_presentation",
    "set_resolved_value",
};
static_assert(kPerfMetricNames.size()
    == static_cast<std::size_t>(PerfMetric::Count));

struct PerfCounter {
    std::atomic<std::uint32_t> calls{};
    std::atomic<std::int64_t> ticks{};
    std::atomic<std::int64_t> maxTicks{};
    std::atomic<std::int64_t> firstQpc{};
    std::atomic<std::int64_t> lastQpc{};
};

struct PerfRollRecord {
    // 0 = free/flushed, 1 = active, 2 = ready for the worker, 3 = flushing.
    std::atomic<std::uint8_t> state{};
    std::uint64_t sequence{};
    std::atomic<std::uint8_t> delegated{};
    std::atomic<std::uint8_t> abandoned{};
    std::atomic<std::uint8_t> action{ 0xff };
    std::atomic<std::uint64_t> delegationId{};
    std::atomic<std::uintptr_t> vmRoll{};
    std::int64_t startQpc{};
    std::atomic<std::int64_t> endQpc{};
    std::array<PerfCounter,
        static_cast<std::size_t>(PerfMetric::Count)> counters{};
};

constexpr std::size_t kPerfRollRecordCount = 16;
std::array<PerfRollRecord, kPerfRollRecordCount> g_perfRollRecords{};
std::atomic<std::uint64_t> g_perfNextSequence{ 1 };
std::atomic<int> g_perfActiveRecord{ -1 };
std::atomic<std::int64_t> g_perfQpcFrequency{};

std::int64_t PerfNow() noexcept
{
    LARGE_INTEGER value{};
    QueryPerformanceCounter(&value);
    return value.QuadPart;
}

PerfRollRecord* ActivePerfRecord() noexcept
{
    if constexpr (!kPerfDiagnostics) {
        return nullptr;
    }
    auto const index = g_perfActiveRecord.load(std::memory_order_relaxed);
    if (index < 0
        || index >= static_cast<int>(g_perfRollRecords.size())) {
        return nullptr;
    }
    auto& record = g_perfRollRecords[static_cast<std::size_t>(index)];
    return record.state.load(std::memory_order_acquire) == 1
        ? &record : nullptr;
}

class PerfScope {
public:
    explicit PerfScope(PerfMetric metric) noexcept
        : metric_(metric), record_(ActivePerfRecord())
    {
        if (record_ != nullptr) {
            start_ = PerfNow();
        }
    }

    ~PerfScope() noexcept
    {
        if (record_ == nullptr
            || record_->state.load(std::memory_order_relaxed) != 1) {
            return;
        }
        auto const end = PerfNow();
        auto const elapsed = end - start_;
        auto& counter =
            record_->counters[static_cast<std::size_t>(metric_)];
        counter.calls.fetch_add(1, std::memory_order_relaxed);
        counter.ticks.fetch_add(elapsed, std::memory_order_relaxed);
        auto maximum = counter.maxTicks.load(std::memory_order_relaxed);
        while (maximum < elapsed
            && !counter.maxTicks.compare_exchange_weak(maximum, elapsed,
                std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
        std::int64_t unset{};
        counter.firstQpc.compare_exchange_strong(unset, start_,
            std::memory_order_relaxed, std::memory_order_relaxed);
        counter.lastQpc.store(end, std::memory_order_relaxed);
    }

private:
    PerfMetric metric_;
    PerfRollRecord* record_{};
    std::int64_t start_{};
};

void EndActivePerfRoll(bool abandoned = false) noexcept
{
    if constexpr (!kPerfDiagnostics) {
        return;
    }
    auto const index = g_perfActiveRecord.exchange(
        -1, std::memory_order_acq_rel);
    if (index < 0
        || index >= static_cast<int>(g_perfRollRecords.size())) {
        return;
    }
    auto& record = g_perfRollRecords[static_cast<std::size_t>(index)];
    if (record.state.load(std::memory_order_relaxed) != 1) {
        return;
    }
    record.abandoned.store(abandoned ? 1 : 0,
        std::memory_order_relaxed);
    record.endQpc.store(PerfNow(), std::memory_order_relaxed);
    record.state.store(2, std::memory_order_release);
}

void BeginPerfRoll() noexcept
{
    if constexpr (!kPerfDiagnostics) {
        return;
    }
    EndActivePerfRoll(true);
    auto const sequence =
        g_perfNextSequence.fetch_add(1, std::memory_order_relaxed);
    auto const index = static_cast<std::size_t>(
        sequence % g_perfRollRecords.size());
    auto& record = g_perfRollRecords[index];
    record.state.store(0, std::memory_order_release);
    record.sequence = sequence;
    record.delegated.store(0, std::memory_order_relaxed);
    record.abandoned.store(0, std::memory_order_relaxed);
    record.action.store(0xff, std::memory_order_relaxed);
    record.delegationId.store(0, std::memory_order_relaxed);
    record.vmRoll.store(0, std::memory_order_relaxed);
    record.startQpc = PerfNow();
    record.endQpc.store(0, std::memory_order_relaxed);
    for (auto& counter : record.counters) {
        counter.calls.store(0, std::memory_order_relaxed);
        counter.ticks.store(0, std::memory_order_relaxed);
        counter.maxTicks.store(0, std::memory_order_relaxed);
        counter.firstQpc.store(0, std::memory_order_relaxed);
        counter.lastQpc.store(0, std::memory_order_relaxed);
    }
    record.state.store(1, std::memory_order_release);
    g_perfActiveRecord.store(static_cast<int>(index),
        std::memory_order_release);
}

void IdentifyActivePerfRoll(
    std::uintptr_t vmRoll,
    ClientPresentationLeaseSnapshot const& lease) noexcept
{
    auto* record = ActivePerfRecord();
    if (record == nullptr || lease.selection == nullptr) {
        return;
    }
    record->delegated.store(1, std::memory_order_relaxed);
    record->action.store(
        static_cast<std::uint8_t>(lease.selection->record.kind),
        std::memory_order_relaxed);
    record->delegationId.store(
        lease.selection->record.id, std::memory_order_relaxed);
    record->vmRoll.store(vmRoll, std::memory_order_relaxed);
}

class PerfRollCompletion {
public:
    ~PerfRollCompletion() noexcept
    {
        EndActivePerfRoll();
    }
};

std::string Narrow(std::wstring_view value)
{
    if (value.empty()) {
        return {};
    }
    auto const length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<std::size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
        result.data(), length, nullptr, nullptr);
    return result;
}

std::string Hex(std::uint64_t value)
{
    std::ostringstream stream;
    stream << std::hex << std::setfill('0') << std::setw(16) << value;
    return stream.str();
}

template <std::size_t Size>
std::string HexBytes(std::array<std::byte, Size> const& bytes)
{
    static constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.resize(Size * 2);
    for (std::size_t index = 0; index < Size; ++index) {
        auto const value = std::to_integer<std::uint8_t>(bytes[index]);
        result[index * 2] = digits[value >> 4];
        result[index * 2 + 1] = digits[value & 0x0f];
    }
    return result;
}

void Log(std::string_view level, std::string_view event, std::string_view fields = {})
{
    if (level == "TRACE") {
        return;
    }
    std::scoped_lock lock(g_logMutex);
    std::ofstream output(g_logPath, std::ios::app | std::ios::binary);
    if (!output) {
        return;
    }
    output << "[best_of_hands_native]|" << level << '|' << event;
    if (!fields.empty()) {
        output << '|' << fields;
    }
    output << "\r\n";
}

double PerfMicroseconds(std::int64_t ticks) noexcept
{
    auto const frequency =
        g_perfQpcFrequency.load(std::memory_order_relaxed);
    return frequency > 0
        ? static_cast<double>(ticks) * 1'000'000.0
            / static_cast<double>(frequency)
        : 0.0;
}

void FlushCompletedPerfRolls()
{
    if constexpr (!kPerfDiagnostics) {
        return;
    }
    for (auto& record : g_perfRollRecords) {
        std::uint8_t ready = 2;
        if (!record.state.compare_exchange_strong(
                ready, 3, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            continue;
        }

        auto const end = record.endQpc.load(std::memory_order_relaxed);
        std::ostringstream fields;
        fields << std::fixed << std::setprecision(3)
               << "sequence=" << record.sequence
               << "|delegated="
               << static_cast<unsigned>(
                    record.delegated.load(std::memory_order_relaxed))
               << "|abandoned="
               << static_cast<unsigned>(
                    record.abandoned.load(std::memory_order_relaxed))
               << "|action=";
        switch (record.action.load(std::memory_order_relaxed)) {
        case static_cast<std::uint8_t>(boh::ActionKind::Lockpick):
            fields << "lockpick";
            break;
        case static_cast<std::uint8_t>(boh::ActionKind::Disarm):
            fields << "disarm";
            break;
        default:
            fields << "unknown";
            break;
        }
        fields << "|delegation_id="
               << record.delegationId.load(std::memory_order_relaxed)
               << "|vm_roll="
               << Hex(record.vmRoll.load(std::memory_order_relaxed))
               << "|wall_ms="
               << PerfMicroseconds(end - record.startQpc) / 1'000.0
               << "|qpc_start=" << record.startQpc
               << "|qpc_end=" << end
               << "|qpc_frequency="
               << g_perfQpcFrequency.load(std::memory_order_relaxed);

        for (std::size_t index = 0;
             index < record.counters.size(); ++index) {
            auto const& counter = record.counters[index];
            auto const calls =
                counter.calls.load(std::memory_order_relaxed);
            if (calls == 0) {
                continue;
            }
            auto const first =
                counter.firstQpc.load(std::memory_order_relaxed);
            auto const last =
                counter.lastQpc.load(std::memory_order_relaxed);
            fields << '|' << kPerfMetricNames[index]
                   << '=' << calls
                   << ',' << PerfMicroseconds(
                        counter.ticks.load(std::memory_order_relaxed))
                   << ',' << PerfMicroseconds(
                        counter.maxTicks.load(std::memory_order_relaxed))
                   << ',' << PerfMicroseconds(first - record.startQpc)
                   << ',' << PerfMicroseconds(last - record.startQpc);
        }
        Log("PERF", "roll_profile", fields.str());
        record.state.store(0, std::memory_order_release);
    }
}

bool IsReadable(void const* pointer, std::size_t size = 1)
{
    PerfScope perf(PerfMetric::MemoryProbe);
    if (pointer == nullptr || size == 0) {
        return false;
    }
    MEMORY_BASIC_INFORMATION info{};
    if (VirtualQuery(pointer, &info, sizeof(info)) == 0
        || info.State != MEM_COMMIT
        || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) {
        return false;
    }
    auto const start = reinterpret_cast<std::uintptr_t>(pointer);
    auto const end = start + size;
    auto const regionEnd = reinterpret_cast<std::uintptr_t>(info.BaseAddress) + info.RegionSize;
    return end >= start && end <= regionEnd;
}

bool IsExecutableGameAddress(std::uintptr_t address) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr) {
        return false;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    if (address < base || address >= base + g_build->imageSize) {
        return false;
    }
    MEMORY_BASIC_INFORMATION info{};
    if (VirtualQuery(reinterpret_cast<void const*>(address),
            &info, sizeof(info)) == 0
        || info.State != MEM_COMMIT
        || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) {
        return false;
    }
    constexpr DWORD executable =
        PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE
        | PAGE_EXECUTE_WRITECOPY;
    return (info.Protect & executable) != 0;
}

bool IsClientGetCharacterTaskAddress(std::uintptr_t address) noexcept
{
    if (!IsExecutableGameAddress(address)) {
        return false;
    }
    std::array<std::byte, kClientGetCharacterTaskSignature.size()> bytes{};
    return boh::SafeRead(
            reinterpret_cast<void const*>(address), bytes)
        && bytes == kClientGetCharacterTaskSignature;
}

template <class T>
bool Read(void const* pointer, T& value)
{
    return boh::SafeRead(pointer, value);
}

template <class T>
bool Write(void* pointer, T const& value)
{
    // Writes are rare and can otherwise partially cross into an inaccessible
    // region before SEH handles the fault. Preserve the original full-range
    // preflight for mutations; the hot read-only path avoids VirtualQuery.
    if (!IsReadable(pointer, sizeof(T))) {
        return false;
    }
    return boh::SafeWrite(pointer, value);
}

template <class T>
T* At(void* base, std::size_t offset)
{
    return reinterpret_cast<T*>(reinterpret_cast<std::byte*>(base) + offset);
}

void RefreshQuickLockpickPendingFlag()
{
    std::shared_lock documentLock(g_clientDocumentMutex);
    std::scoped_lock quickLock(g_quickLockpickMutex);
    bool pending = false;
    for (auto const& request : g_clientDocument.quickLockpicks) {
        if (!g_consumedQuickLockpicks.contains(request.request)) {
            pending = true;
            break;
        }
    }
    g_quickLockpickPending.store(pending, std::memory_order_release);
}

void MarkQuickLockpickConsumed(std::string const& request)
{
    {
        std::scoped_lock lock(g_quickLockpickMutex);
        if (g_consumedQuickLockpicks.insert(request).second) {
            g_consumedQuickLockpickOrder.push_back(request);
        }
        while (g_consumedQuickLockpickOrder.size()
            > kMaximumQuickLockpickRequests) {
            g_consumedQuickLockpicks.erase(
                g_consumedQuickLockpickOrder.front());
            g_consumedQuickLockpickOrder.pop_front();
        }
    }
    RefreshQuickLockpickPendingFlag();
}

std::optional<boh::QuickLockpickRequest> NextQuickLockpick(
    std::uint64_t initiator)
{
    std::shared_lock documentLock(g_clientDocumentMutex);
    if (!g_clientDocument.valid
        || g_clientDocument.nativeSession != g_sessionUtf8) {
        return {};
    }
    std::scoped_lock quickLock(g_quickLockpickMutex);
    for (auto const& request : g_clientDocument.quickLockpicks) {
        if (request.initiator == initiator
            && !g_consumedQuickLockpicks.contains(request.request)) {
            return request;
        }
    }
    return {};
}

std::optional<std::uintptr_t> FindStockCharacterTask(
    void* controller, std::uint32_t requestedType) noexcept
{
    if (controller == nullptr || g_gameModule == nullptr || g_build == nullptr) {
        return {};
    }
    auto const getCharacterTask =
        reinterpret_cast<std::uintptr_t>(g_gameModule)
        + g_build->clientGetCharacterTaskRva;
    if (!IsClientGetCharacterTaskAddress(getCharacterTask)) {
        return {};
    }
    void* task{};
    if (!boh::TryGetCharacterTask(
            getCharacterTask, controller, requestedType, task)
        || task == nullptr
        || !IsReadable(task, sizeof(void*))) {
        return {};
    }
    return reinterpret_cast<std::uintptr_t>(task);
}

struct LeftClickRedirect {
    std::uintptr_t lockpickTask{};
    std::uint64_t target{};
    std::uint64_t targetNetId{};
    bool alreadyRunning{};
};

std::optional<LeftClickRedirect> ResolveLeftClickRedirect(
    void* controller, void* requestedTask) noexcept
{
    std::uint64_t target{};
    if (controller == nullptr
        || requestedTask == nullptr) {
        return {};
    }
    auto const itemUseTask = FindStockCharacterTask(
        controller, kClientItemUseTaskType);
    if (!itemUseTask.has_value()) {
        return {};
    }
    if (*itemUseTask != reinterpret_cast<std::uintptr_t>(requestedTask)) {
        return {};
    }
    if (!Read(At<std::uint64_t>(
            requestedTask, kClientItemUseTargetOffset), target)
        || target == 0) {
        return {};
    }

    boh::LockedTarget targetRecord;
    std::uint64_t owner{};
    if (!Read(At<std::uint64_t>(
            controller, kClientControllerOwnerOffset), owner)
        || owner == 0) {
        return {};
    }
    {
        std::shared_lock documentLock(g_leftClickDocumentMutex);
        if (!g_leftClickDocument.valid
            || g_leftClickDocument.nativeSession != g_sessionUtf8) {
            return {};
        }
        auto const initiatorIt = std::ranges::find_if(
            g_leftClickDocument.leftClickInitiators,
            [owner](auto const& candidate) {
                return candidate.initiator == owner;
            });
        if (initiatorIt
                == g_leftClickDocument.leftClickInitiators.end()
            || !initiatorIt->eligible) {
            return {};
        }
        auto const targetIt = std::ranges::find_if(
            g_leftClickDocument.lockedTargets,
            [target](auto const& candidate) {
                return candidate.target == target;
            });
        if (targetIt == g_leftClickDocument.lockedTargets.end()) {
            return {};
        }
        targetRecord = *targetIt;
    }

    auto const lockpickTask = FindStockCharacterTask(
        controller, kClientLockpickTaskType);
    std::uintptr_t runningTask{};
    if (!lockpickTask.has_value()) {
        return {};
    }
    if (!Read(At<std::uintptr_t>(
            controller, kClientControllerRunningTaskOffset), runningTask)) {
        return {};
    }
    return LeftClickRedirect{
        *lockpickTask,
        targetRecord.target,
        targetRecord.netId,
        runningTask == *lockpickTask,
    };
}

bool ConfigureStockLockpickTask(
    LeftClickRedirect const& redirect) noexcept
{
    auto* lockpickTask = reinterpret_cast<void*>(redirect.lockpickTask);
    std::uint8_t const no = 0;
    std::uint8_t const yes = 1;
    return Write(At<std::uint64_t>(
            lockpickTask, kClientLockpickTargetOffset), redirect.target)
        && Write(At<std::uint64_t>(
            lockpickTask, kClientLockpickTargetNetIdOffset),
            redirect.targetNetId)
        && Write(At<std::uint8_t>(
            lockpickTask, kClientLockpickStartedOffset), no)
        && Write(At<std::uint8_t>(
            lockpickTask, kClientLockpickTargetSelectedOffset), yes)
        && Write(At<std::uint8_t>(
            lockpickTask, kClientLockpickCanLockpickOffset), no);
}

void ClientTaskSelectionMidHook(safetyhook::Context& context) noexcept
{
    try {
        auto* controller = reinterpret_cast<void*>(context.rsi);
        auto* selectedTask = reinterpret_cast<void*>(context.r15);
        auto const redirect =
            ResolveLeftClickRedirect(controller, selectedTask);
        if (!redirect.has_value()) {
            return;
        }

        // The engine has ranked ItemUse but has not yet retired the other task
        // candidates, prepared the winner, or installed RunningTask. Replacing
        // r15 here makes all three stock lifecycle stages consistently observe
        // Lockpick. In particular, BG3 clears ItemUse.Ready instead of leaving
        // it armed to win the next frame again.
        if (redirect->alreadyRunning) {
            context.r15 = redirect->lockpickTask;
            return;
        }
        if (!ConfigureStockLockpickTask(*redirect)) {
            return;
        }
        context.r15 = redirect->lockpickTask;
    } catch (...) {
        // Preserve BG3's selected task if any intercepted state is unavailable.
    }
}

void ProcessQuickLockpick(void* controller) noexcept
{
    if (!g_quickLockpickPending.load(std::memory_order_acquire)) {
        return;
    }

    std::optional<boh::QuickLockpickRequest> request;
    try {
        std::uint64_t owner{};
        if (!Read(At<std::uint64_t>(
                controller, kClientControllerOwnerOffset), owner)
            || owner == 0) {
            return;
        }
        request = NextQuickLockpick(owner);
        if (!request.has_value()) {
            return;
        }
        auto const controllerAddress =
            reinterpret_cast<std::uintptr_t>(controller);

        auto const lockpickTask = FindStockCharacterTask(
            controller, kClientLockpickTaskType);
        std::uintptr_t runningBefore{};
        if (!lockpickTask.has_value()) {
            Log("ERROR", "native_quick_lockpick_rejected",
                "request=" + request->request
                + "|reason=stock_task_unavailable"
                + "|controller=" + Hex(controllerAddress)
                + "|owner=" + Hex(owner));
            MarkQuickLockpickConsumed(request->request);
            return;
        }
        if (!Read(At<std::uintptr_t>(
                controller, kClientControllerRunningTaskOffset),
                runningBefore)) {
            Log("ERROR", "native_quick_lockpick_rejected",
                "request=" + request->request
                + "|reason=running_task_unreadable"
                + "|controller="
                + Hex(reinterpret_cast<std::uintptr_t>(controller))
                + "|owner=" + Hex(owner));
            MarkQuickLockpickConsumed(request->request);
            return;
        }
        auto const lockpickTaskAddress = *lockpickTask;
        auto* task = reinterpret_cast<void*>(*lockpickTask);
        if (!ConfigureStockLockpickTask(LeftClickRedirect{
                lockpickTaskAddress,
                request->target,
                request->targetNetId,
                false,
            })) {
            Log("ERROR", "native_quick_lockpick_rejected",
                "request=" + request->request
                + "|reason=stock_task_write_failed"
                + "|controller="
                + Hex(reinterpret_cast<std::uintptr_t>(controller))
                + "|task=" + Hex(*lockpickTask));
            MarkQuickLockpickConsumed(request->request);
            return;
        }

        if (runningBefore == *lockpickTask) {
            MarkQuickLockpickConsumed(request->request);
            return;
        }

        // A fallback is a one-shot repair for a completed vanilla ItemUse.
        // Reserve it before entering BG3 so controller-update reentrancy and
        // later frames cannot replay an accepted SetRunningTask call. A fresh
        // player click may publish a fresh request if BG3 declines this one.
        MarkQuickLockpickConsumed(request->request);
        bool started{};
        auto const setRunningTask =
            reinterpret_cast<std::uintptr_t>(g_gameModule)
            + g_build->clientSetRunningTaskRva;
        if (!boh::TryInvokeSetRunningTask(
                setRunningTask,
                controller,
                task,
                true,
                started)) {
            Log("ERROR", "native_quick_lockpick_rejected",
                "request=" + request->request
                + "|reason=set_running_task_fault"
                + "|procedure="
                + Hex(setRunningTask));
            return;
        }
        if (!started) {
            return;
        }

        std::uintptr_t runningAfter{};
        if (!Read(At<std::uintptr_t>(
                controller, kClientControllerRunningTaskOffset),
                runningAfter)
            || runningAfter != *lockpickTask) {
            Log("ERROR", "native_quick_lockpick_rejected",
                "request=" + request->request
                + "|reason=set_running_task_readback_failed"
                + "|running_after=" + Hex(runningAfter)
                + "|expected=" + Hex(*lockpickTask));
            return;
        }

        Log("INFO", "native_quick_lockpick_started",
            "request=" + request->request
            + "|initiator=" + Hex(request->initiator)
            + "|target=" + Hex(request->target)
            + "|task=stock_client_lockpick"
            + "|activation=engine_set_running_task"
            + "|controller="
            + Hex(reinterpret_cast<std::uintptr_t>(controller))
            + "|task_pointer=" + Hex(*lockpickTask));
    } catch (...) {
        Log("ERROR", "native_quick_lockpick_rejected",
            "request=" + (request.has_value()
                    ? request->request
                    : std::string{"unresolved"})
                + "|reason=unexpected_exception");
        if (request.has_value()) {
            MarkQuickLockpickConsumed(request->request);
        } else {
            g_quickLockpickPending.store(false, std::memory_order_release);
        }
    }
}

void ClientInputControllerUpdateDetour(
    void* controller, void const* gameTime) noexcept
{
    g_clientInputControllerUpdateHook.call<void>(controller, gameTime);
    ProcessQuickLockpick(controller);
}

void QueueClientViewModelReleases(ClientPresentationLease& lease)
{
    for (std::size_t index = 0;
         index < lease.retainedRollBonusViewModelCount; ++index) {
        auto const viewModel = lease.retainedRollBonusViewModels[index];
        if (viewModel != 0) {
            g_deferredClientViewModelReleases.push_back(viewModel);
        }
    }
    lease.retainedRollBonusViewModels = {};
    lease.retainedRollBonusViewModelCount = 0;
    lease.selectedRemovalGuardArmed = false;
}

bool RetainClientViewModel(std::uintptr_t viewModel) noexcept
{
    if (viewModel == 0
        || !IsReadable(reinterpret_cast<void const*>(viewModel),
            0x18)) {
        return false;
    }
    __try {
        auto const interfaceObject = viewModel + 0x10;
        auto const vtable = *reinterpret_cast<std::uintptr_t const*>(
            interfaceObject);
        if (vtable == 0
            || !IsReadable(reinterpret_cast<void const*>(vtable + 0x18),
                sizeof(void*))) {
            return false;
        }
        auto const retain = *reinterpret_cast<std::uintptr_t const*>(
            vtable + 0x18);
        if (retain == 0) {
            return false;
        }
        reinterpret_cast<void (*)(void*)>(retain)(
            reinterpret_cast<void*>(interfaceObject));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void ReleaseClientViewModel(std::uintptr_t viewModel) noexcept
{
    if (viewModel == 0
        || !IsReadable(reinterpret_cast<void const*>(viewModel),
            0x18)) {
        return;
    }
    __try {
        auto const interfaceObject = viewModel + 0x10;
        auto const vtable = *reinterpret_cast<std::uintptr_t const*>(
            interfaceObject);
        if (vtable != 0
            && IsReadable(reinterpret_cast<void const*>(vtable + 0x20),
                sizeof(void*))) {
            auto const release = *reinterpret_cast<std::uintptr_t const*>(
                vtable + 0x20);
            if (release != 0) {
                reinterpret_cast<void (*)(void*)>(release)(
                    reinterpret_cast<void*>(interfaceObject));
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // A retained UI reference is diagnostic/presentation state only.
    }
}

void ReleaseClientIntrusiveObject(std::uintptr_t object) noexcept
{
    if (object == 0
        || !IsReadable(reinterpret_cast<void const*>(object),
            sizeof(void*) + sizeof(LONG))) {
        return;
    }
    __try {
        auto* referenceCount = reinterpret_cast<volatile LONG*>(
            object + sizeof(void*));
        auto const previous = InterlockedExchangeAdd(referenceCount, -1);
        if (previous == 1) {
            auto const vtable = *reinterpret_cast<std::uintptr_t const*>(
                object);
            if (vtable != 0
                && IsReadable(reinterpret_cast<void const*>(
                        vtable + 0x20), sizeof(void*))) {
                auto const destroy = *reinterpret_cast<std::uintptr_t const*>(
                    vtable + 0x20);
                if (destroy != 0) {
                    reinterpret_cast<void (*)(void*)>(destroy)(
                        reinterpret_cast<void*>(object));
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // A result-facing UI object must fail open if its release ABI changed.
    }
}

bool RememberCachedRollBonusPresentation(
    boh::ProfileSelection const& selection,
    std::uintptr_t selectedViewModel,
    DynamicModifierIdentity const& identity,
    std::uint8_t diceSize, std::uint8_t diceCount) noexcept
{
    if (selectedViewModel == 0 || diceCount == 0
        || !RetainClientViewModel(selectedViewModel)) {
        return false;
    }

    bool stored{};
    {
        std::scoped_lock lock(g_clientPresentationLeaseMutex);
        auto const sameShape = [&](CachedRollBonusPresentation const& entry) {
            return entry.specialist == selection.specialist
                && entry.diceSize == diceSize
                && entry.diceCount == diceCount;
        };
        auto const existing = std::find_if(
            g_cachedRollBonusPresentations.begin(),
            g_cachedRollBonusPresentations.end(), sameShape);
        if (existing != g_cachedRollBonusPresentations.end()) {
            if (existing->selectedViewModel != selectedViewModel) {
                g_deferredClientViewModelReleases.push_back(
                    existing->selectedViewModel);
            } else {
                // The cache already owns this exact reference. Balance the
                // speculative retain above and update only its identity/time.
                g_deferredClientViewModelReleases.push_back(
                    selectedViewModel);
            }
            *existing = CachedRollBonusPresentation{
                .specialist = selection.specialist,
                .selectedViewModel = selectedViewModel,
                .identityGuid = identity.guid,
                .identityType = identity.type,
                .diceSize = diceSize,
                .diceCount = diceCount,
                .lastUsedTick = GetTickCount64(),
            };
            stored = true;
        } else {
            if (g_cachedRollBonusPresentations.size()
                >= kMaximumCachedRollBonusPresentations) {
                auto const oldest = std::min_element(
                    g_cachedRollBonusPresentations.begin(),
                    g_cachedRollBonusPresentations.end(),
                    [](auto const& left, auto const& right) {
                        return left.lastUsedTick < right.lastUsedTick;
                    });
                if (oldest != g_cachedRollBonusPresentations.end()) {
                    g_deferredClientViewModelReleases.push_back(
                        oldest->selectedViewModel);
                    g_cachedRollBonusPresentations.erase(oldest);
                }
            }
            g_cachedRollBonusPresentations.push_back(
                CachedRollBonusPresentation{
                    .specialist = selection.specialist,
                    .selectedViewModel = selectedViewModel,
                    .identityGuid = identity.guid,
                    .identityType = identity.type,
                    .diceSize = diceSize,
                    .diceCount = diceCount,
                    .lastUsedTick = GetTickCount64(),
                });
            stored = true;
        }
    }
    return stored;
}

CachedRollBonusPresentationSnapshot
FindCachedRollBonusPresentations(
    boh::ProfileSelection const& selection) noexcept
{
    CachedRollBonusPresentationSnapshot result;
    std::scoped_lock lock(g_clientPresentationLeaseMutex);
    for (auto& entry : g_cachedRollBonusPresentations) {
        if (entry.specialist == selection.specialist) {
            entry.lastUsedTick = GetTickCount64();
            result.push_back(entry);
        }
    }
    return result;
}

void DrainDeferredClientViewModelReleases() noexcept
{
    constexpr std::size_t batchCapacity = 256;
    for (;;) {
        FixedSnapshot<std::uintptr_t, batchCapacity> pending;
        {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            while (!g_deferredClientViewModelReleases.empty()
                && pending.size() < pending.capacity()) {
                pending.push_back(
                    g_deferredClientViewModelReleases.back());
                g_deferredClientViewModelReleases.pop_back();
            }
        }
        for (auto const viewModel : pending) {
            ReleaseClientViewModel(viewModel);
        }
        if (pending.size() < pending.capacity()) {
            return;
        }
    }
}

void ClearClientPresentationLeases(std::string_view reason)
{
    std::size_t count{};
    std::size_t queued{};
    {
        std::scoped_lock lock(g_clientPresentationLeaseMutex);
        count = g_clientPresentationLeases.size();
        for (auto& [_, lease] : g_clientPresentationLeases) {
            queued += lease.retainedRollBonusViewModelCount;
            QueueClientViewModelReleases(lease);
        }
        for (auto const& cached : g_cachedRollBonusPresentations) {
            if (cached.selectedViewModel != 0) {
                g_deferredClientViewModelReleases.push_back(
                    cached.selectedViewModel);
                ++queued;
            }
        }
        g_cachedRollBonusPresentations.clear();
        g_clientPresentationLeases.clear();
        g_clientPresentationLeaseByVmRoll.clear();
    }
    if (count != 0 && TraceEnabled()) {
        Log("TRACE", "native_client_presentation_leases_cleared",
            "reason=" + std::string(reason)
            + "|records=" + std::to_string(count)
            + "|deferred_viewmodel_releases=" + std::to_string(queued));
    }
}

void RememberClientPresentationLease(
    boh::ProfileSelection const& selection,
    boh::RequestedRollIdentity const& identity)
{
    if (selection.scope != boh::ProfileScope::Client
        || selection.record.rollUuid.empty()) {
        return;
    }

    std::optional<std::string> evicted;
    bool created{};
    {
        std::scoped_lock lock(g_clientPresentationLeaseMutex);
        auto const existing = g_clientPresentationLeases.find(
            selection.record.rollUuid);
        created = existing == g_clientPresentationLeases.end();
        if (created
            && g_clientPresentationLeases.size()
                >= kMaximumClientPresentationLeases) {
            auto oldest = g_clientPresentationLeases.end();
            for (auto current = g_clientPresentationLeases.begin();
                 current != g_clientPresentationLeases.end(); ++current) {
                if (oldest == g_clientPresentationLeases.end()
                    || current->second.lastUsedTick
                        < oldest->second.lastUsedTick) {
                    oldest = current;
                }
            }
                if (oldest != g_clientPresentationLeases.end()) {
                    evicted = oldest->first;
                    if (oldest->second.vmRoll != 0) {
                        g_clientPresentationLeaseByVmRoll.erase(
                            oldest->second.vmRoll);
                    }
                    QueueClientViewModelReleases(oldest->second);
                    g_clientPresentationLeases.erase(oldest);
            }
        }
        auto& lease = g_clientPresentationLeases[selection.record.rollUuid];
        if (lease.selection == nullptr
            || lease.selection->record.id != selection.record.id
            || lease.selection->record.rollUuid
                != selection.record.rollUuid
            || lease.selection->specialist != selection.specialist) {
            lease.selection =
                std::make_shared<boh::ProfileSelection const>(selection);
        }
        lease.roller = identity.roller;
        lease.subject = identity.subject;
        lease.lastUsedTick = GetTickCount64();
    }
    if (created && TraceEnabled()) {
        Log("TRACE", "native_client_presentation_lease_created",
            "action=" + boh::ActionName(selection.record.kind)
            + "|delegation_id=" + std::to_string(selection.record.id)
            + "|roll_uuid=" + selection.record.rollUuid
            + "|initiator_handle=" + Hex(identity.roller)
            + "|specialist_handle=" + Hex(selection.specialist)
            + "|target_handle=" + Hex(identity.subject)
            + "|evicted_roll_uuid=" + evicted.value_or("none"));
    }
}

std::optional<boh::ProfileSelection> MatchClientPresentationLease(
    boh::RequestedRollIdentity const& identity)
{
    if (identity.rollUuid.empty()) {
        return {};
    }
    std::scoped_lock lock(g_clientPresentationLeaseMutex);
    auto const found = g_clientPresentationLeases.find(identity.rollUuid);
    if (found == g_clientPresentationLeases.end()
        || found->second.selection == nullptr
        || !boh::MatchesClientPresentationLease(
            identity,
            found->first,
            found->second.roller,
            found->second.subject,
            found->second.selection->specialist)) {
        return {};
    }
    found->second.lastUsedTick = GetTickCount64();
    return *found->second.selection;
}

void BindClientPresentationLease(
    boh::ProfileSelection const& selection, std::uintptr_t vmRoll)
{
    if (selection.scope != boh::ProfileScope::Client
        || selection.record.rollUuid.empty()
        || vmRoll == 0) {
        return;
    }
    std::scoped_lock lock(g_clientPresentationLeaseMutex);
    auto const collision = g_clientPresentationLeaseByVmRoll.find(vmRoll);
    if (collision != g_clientPresentationLeaseByVmRoll.end()
        && collision->second != selection.record.rollUuid) {
        auto const previous =
            g_clientPresentationLeases.find(collision->second);
        if (previous != g_clientPresentationLeases.end()) {
            // DCActiveRoll may recycle its VMRoll object for a later action.
            // Keep click-boundary lookup one-to-one with the newest exact UUID.
            QueueClientViewModelReleases(previous->second);
            previous->second.vmRoll = 0;
        }
        g_clientPresentationLeaseByVmRoll.erase(collision);
    }
    auto const found = g_clientPresentationLeases.find(
        selection.record.rollUuid);
    if (found != g_clientPresentationLeases.end()) {
        if (found->second.vmRoll != 0
            && found->second.vmRoll != vmRoll) {
            g_clientPresentationLeaseByVmRoll.erase(
                found->second.vmRoll);
        }
        found->second.vmRoll = vmRoll;
        found->second.lastUsedTick = GetTickCount64();
        g_clientPresentationLeaseByVmRoll[vmRoll] =
            selection.record.rollUuid;
    }
}

std::optional<ClientPresentationLeaseSnapshot>
FindClientPresentationLeaseByVmRoll(
    std::uintptr_t vmRoll)
{
    PerfScope perf(PerfMetric::LeaseLookup);
    if (vmRoll == 0) {
        return {};
    }
    std::scoped_lock lock(g_clientPresentationLeaseMutex);
    auto const indexed = g_clientPresentationLeaseByVmRoll.find(vmRoll);
    if (indexed == g_clientPresentationLeaseByVmRoll.end()) {
        return {};
    }
    auto const found = g_clientPresentationLeases.find(indexed->second);
    if (found == g_clientPresentationLeases.end()
        || found->second.vmRoll != vmRoll
        || found->second.selection == nullptr) {
        g_clientPresentationLeaseByVmRoll.erase(indexed);
        return {};
    }
    found->second.lastUsedTick = GetTickCount64();
    return ClientPresentationLeaseSnapshot{
        .selection = found->second.selection,
        .frozenAdvantage = found->second.frozenAdvantage,
        .presentationFrozen = found->second.presentationFrozen,
        .retainedRollBonusViewModelCount =
            found->second.retainedRollBonusViewModelCount,
    };
}

std::optional<std::uint8_t> CurrentClientPresentationAdvantage(
    ClientPresentationLeaseSnapshot const& lease)
{
    PerfScope perf(PerfMetric::AdvantageLookup);
    if (lease.selection == nullptr) {
        return {};
    }
    if (lease.presentationFrozen && lease.frozenAdvantage <= 2) {
        return lease.frozenAdvantage;
    }

    // Modifier choices can change the server aggregate after the lease was
    // first bound. Prefer the newest exact-roll record while it exists, then
    // retain the last validated lease value through replicated destruction.
    {
        std::shared_lock lock(g_documentMutex);
        if (g_document.valid
            && g_document.nativeSession == g_sessionUtf8) {
            for (auto const& record : g_document.records) {
                if (record.id == lease.selection->record.id
                    && record.rollUuid == lease.selection->record.rollUuid
                    && record.presentationAdvantage <= 2) {
                    return record.presentationAdvantage;
                }
            }
        }
    }
    return boh::ClientPresentationAdvantage(*lease.selection);
}

bool FreezeClientPresentationAdvantage(
    std::uintptr_t vmRoll, std::uint8_t advantage)
{
    if (vmRoll == 0 || advantage > 2) {
        return false;
    }
    std::scoped_lock lock(g_clientPresentationLeaseMutex);
    auto const indexed = g_clientPresentationLeaseByVmRoll.find(vmRoll);
    if (indexed == g_clientPresentationLeaseByVmRoll.end()) {
        return false;
    }
    auto const found = g_clientPresentationLeases.find(indexed->second);
    if (found == g_clientPresentationLeases.end()
        || found->second.vmRoll != vmRoll) {
        g_clientPresentationLeaseByVmRoll.erase(indexed);
        return false;
    }
    auto& lease = found->second;
    if (!lease.presentationFrozen) {
        lease.frozenAdvantage = advantage;
        lease.presentationFrozen = true;
    }
    lease.lastUsedTick = GetTickCount64();
    return lease.frozenAdvantage == advantage;
}

std::optional<fs::file_time_type> LastWrite(fs::path const& path)
{
    std::error_code error;
    auto const value = fs::last_write_time(path, error);
    return error ? std::optional<fs::file_time_type>{} : value;
}

std::string ReadAll(fs::path const& path)
{
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) {
        return {};
    }
    auto const end = input.tellg();
    if (end <= 0) {
        return {};
    }
    std::string contents(static_cast<std::size_t>(end), '\0');
    input.seekg(0, std::ios::beg);
    input.read(contents.data(),
        static_cast<std::streamsize>(contents.size()));
    if (!input) {
        return {};
    }
    return contents;
}

bool AtomicWrite(fs::path const& path, std::string const& contents)
{
    auto temporary = path;
    temporary += L".tmp";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) {
            return false;
        }
        output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
        output.flush();
        if (!output) {
            return false;
        }
    }
    return MoveFileExW(temporary.c_str(), path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}

void WriteStatus(std::string_view state, std::string_view detail, std::string_view ack)
{
    std::scoped_lock lock(g_statusMutex);
    std::ostringstream status;
    status << "protocol=" << boh::kProtocolVersion << "\n"
           << "version=" << boh::kPluginVersion << "\n"
           << "state=" << state << "\n"
           << "session=" << Narrow(g_session) << "\n"
           << "pid=" << GetCurrentProcessId() << "\n"
           << "hooks=" << (g_hooksReady.load() ? kReportedHooks : "none") << "\n"
           << "features=" << kReportedFeatures << "\n"
           << "ack=" << ack << "\n"
           << "detail=" << detail << "\n"
           << "end=1\n";
    AtomicWrite(g_statusPath, status.str());
}

void SetHookFailure(std::string value)
{
    std::scoped_lock lock(g_hookFailureMutex);
    g_hookFailure = std::move(value);
}

void WriteCurrentStatus(std::string_view ack)
{
    if (g_hooksReady.load()) {
        WriteStatus("ready",
            "validated server profile, roll-math, and client presentation hooks installed",
            ack);
        return;
    }
    std::string failure;
    {
        std::scoped_lock lock(g_hookFailureMutex);
        failure = g_hookFailure;
    }
    if (!failure.empty()) {
        WriteStatus("hook_install_failed", failure, ack);
    } else if (!g_codeHooksReady.load()) {
        WriteStatus("installing_hooks",
            "installing validated profile and client presentation hooks", ack);
    } else {
        WriteStatus("waiting_for_server",
            "waiting for the server entity world; client presentation hook validated",
            ack);
    }
}

void RefreshDocument(bool force, bool waitForLock = true)
{
    std::unique_lock refreshLock(
        g_documentRefreshMutex, std::defer_lock);
    if (waitForLock) {
        refreshLock.lock();
    } else if (!refreshLock.try_lock()) {
        return;
    }
    auto const writeTime = LastWrite(g_actionPath);
    if (!force && writeTime == g_actionWriteTime) {
        return;
    }
    g_actionWriteTime = writeTime;
    auto parsed = boh::ParseBridgeDocument(ReadAll(g_actionPath));
    if (!parsed.valid) {
        std::unique_lock lock(g_documentMutex);
        g_document = {};
        return;
    }

    auto const ack = parsed.probe;
    bool probeChanged = false;
    {
        std::unique_lock lock(g_documentMutex);
        probeChanged = g_document.probe != parsed.probe;
        g_document = std::move(parsed);
    }
    if (probeChanged) {
        ClearClientPresentationLeases("bridge_probe_changed");
        WriteCurrentStatus(ack);
    }
}

void RefreshClientDocument(bool force)
{
    std::scoped_lock refreshLock(g_clientDocumentRefreshMutex);
    auto const writeTime = LastWrite(g_clientActionPath);
    if (!force && writeTime == g_clientActionWriteTime) {
        return;
    }
    g_clientActionWriteTime = writeTime;
    auto parsed = boh::ParseClientBridgeDocument(ReadAll(g_clientActionPath));
    if (!parsed.valid) {
        {
            std::unique_lock lock(g_clientDocumentMutex);
            g_clientDocument = {};
        }
        g_quickLockpickPending.store(false, std::memory_order_release);
        if (TraceEnabled()) {
            Log("TRACE", "native_client_bridge_cleared",
                "reason=invalid_or_incomplete_document");
        }
        return;
    }
    auto const recordCount = parsed.records.size();
    auto const quickCount = parsed.quickLockpicks.size();
    auto const currentSession = parsed.nativeSession;
    std::string previousSession;
    {
        std::unique_lock lock(g_clientDocumentMutex);
        previousSession = g_clientDocument.nativeSession;
        g_clientDocument = std::move(parsed);
    }
    if (previousSession != currentSession) {
        std::scoped_lock lock(g_quickLockpickMutex);
        g_consumedQuickLockpicks.clear();
        g_consumedQuickLockpickOrder.clear();
    }
    RefreshQuickLockpickPendingFlag();
    if (TraceEnabled()) {
        Log("TRACE", "native_client_bridge_refreshed",
            "records=" + std::to_string(recordCount)
            + "|quick_lockpicks=" + std::to_string(quickCount));
    }
}

void RefreshLeftClickDocument(bool force)
{
    std::scoped_lock refreshLock(g_leftClickDocumentRefreshMutex);
    auto const writeTime = LastWrite(g_leftClickActionPath);
    if (!force && writeTime == g_leftClickActionWriteTime) {
        return;
    }
    g_leftClickActionWriteTime = writeTime;
    auto parsed = boh::ParseClientBridgeDocument(
        ReadAll(g_leftClickActionPath));
    {
        std::unique_lock lock(g_leftClickDocumentMutex);
        g_leftClickDocument = parsed.valid
            ? std::move(parsed)
            : boh::ClientBridgeDocument{};
    }
}

std::optional<boh::ProfileSelection> FindProfileRecord(
    void const* component, bool* usedClientLease = nullptr)
{
    if (usedClientLease != nullptr) {
        *usedClientLease = false;
    }
    if (!IsReadable(component, kMinimumRequestedRollBytes)) {
        return {};
    }
    boh::RequestedRollIdentity identity;
    auto const bytes = static_cast<std::byte const*>(component);
    std::array<std::uint8_t, 16> rollUuid{};
    if (!Read(bytes + kRequestedRollRollEntityOffset, identity.roll)
        || !Read(bytes + kRequestedRollRollUuidOffset, rollUuid)
        || !Read(bytes + kRequestedRollRollerOffset, identity.roller)
        || !Read(bytes + kRequestedRollSubjectOffset, identity.subject)) {
        return {};
    }
    identity.rollUuid = boh::FormatGuid(rollUuid);

    std::optional<boh::ProfileSelection> selection;
    {
        std::shared_lock serverLock(g_documentMutex);
        if (!g_document.valid
            || g_document.nativeSession != g_sessionUtf8) {
            return {};
        }
        std::shared_lock clientLock(g_clientDocumentMutex);
        std::span<boh::ClientActionRecord const> clientRecords;
        if (g_clientDocument.valid
            && g_clientDocument.nativeSession == g_document.nativeSession) {
            clientRecords = g_clientDocument.records;
        }
        selection = boh::MatchProfileSelection(
            g_document.records,
            clientRecords,
            identity);
    }
    if (selection.has_value()) {
        RememberClientPresentationLease(*selection, identity);
        return selection;
    }

    selection = MatchClientPresentationLease(identity);
    if (selection.has_value() && usedClientLease != nullptr) {
        *usedClientLease = true;
    }
    return selection;
}

void TraceProfileSelection(std::string_view stage,
    boh::ProfileSelection const& selection,
    void const* component)
{
    if (!TraceEnabled()) {
        return;
    }
    auto const stageId = stage == "ui" ? 1ULL : 2ULL;
    auto const& record = selection.record;
    auto const scopeId = selection.scope == boh::ProfileScope::Client ? 1ULL : 0ULL;
    auto const key = (record.id << 3U) | (scopeId << 2U) | stageId;
    std::uint64_t pass = 0;
    {
        std::scoped_lock lock(g_profileTraceMutex);
        pass = ++g_profilePasses[key];
    }
    // A normal roll reaches each boundary only a few times. Bound output so a
    // future engine loop can never reproduce the old synchronous trace stall.
    if (pass > 8) {
        return;
    }
    Log("TRACE", "native_profile_source_selected",
        "stage=" + std::string(stage)
        + "|action=" + boh::ActionName(record.kind)
        + "|delegation_id=" + std::to_string(record.id)
        + "|pass=" + std::to_string(pass)
        + "|roll_handle=" + Hex(record.roll)
        + "|initiator_handle=" + Hex(record.initiator)
        + "|specialist_handle=" + Hex(selection.specialist)
        + "|profile_scope="
        + (selection.scope == boh::ProfileScope::Client ? "client" : "server")
        + "|target_handle=" + Hex(record.target)
        + "|component=" + Hex(reinterpret_cast<std::uintptr_t>(component))
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64())
        + "|component_owner_unchanged=1");
}

void ProfileUiMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::ProfileUi);
    try {
        auto const component = reinterpret_cast<void const*>(context.r13);
        auto const selection = FindProfileRecord(component);
        if (!selection) {
            return;
        }
        // The relocated instruction stores r15 and then reads the handle from
        // it several times. Point that local register at stable thread-local
        // storage; RequestedRoll.Roller itself is never written.
        thread_local std::uint64_t specialist{};
        specialist = selection->specialist;
        context.r15 = reinterpret_cast<std::uintptr_t>(&specialist);
        TraceProfileSelection("ui", *selection, component);
    } catch (...) {
        // Never allow diagnostics or bridge parsing to unwind into game code.
    }
}

void ProfileMathMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::ProfileMath);
    try {
        auto const component = reinterpret_cast<void const*>(context.r8);
        auto const selection = FindProfileRecord(component);
        if (!selection) {
            return;
        }
        // The relocated instruction is `mov r8, [r8+20h]`. Redirect only its
        // source address so the evaluator's local actor becomes the specialist
        // while every ownership field in the real component stays initiator-owned.
        thread_local std::array<std::byte,
            kRequestedRollRollerOffset + sizeof(std::uint64_t)> scratch{};
        std::memcpy(scratch.data() + kRequestedRollRollerOffset,
            &selection->specialist, sizeof(selection->specialist));
        context.r8 = reinterpret_cast<std::uintptr_t>(scratch.data());
        TraceProfileSelection("math", *selection, component);
    } catch (...) {
        // Never allow diagnostics or bridge parsing to unwind into game code.
    }
}

void CaptureSelectedRollBonusViewModels(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::uint32_t rollState,
    boh::ProfileSelection const& selection) noexcept;
void ArmSelectedRollBonusPresentationAfterPayload(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::uint32_t rollState) noexcept;
void RestoreSelectedRollBonusList(std::uintptr_t activeRoll,
    std::uintptr_t vmRoll, std::string_view stage) noexcept;

struct SelectedRollBonusBindingResult {
    std::size_t retained{};
    std::size_t cached{};
    std::size_t matched{};
    std::size_t inserted{};
    std::size_t rebound{};
    std::size_t alreadyBound{};
    std::size_t typed{};
    std::size_t sourceVms{};
    std::size_t sourceVmsTransferred{};
    std::size_t sourceVmsAlreadyBound{};
    std::size_t directTargets{};
    std::size_t selectedAuthoritative{};
    std::size_t selectedFallbacks{};
};

SelectedRollBonusBindingResult BindSelectedRollBonusPresentation(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::span<ResolvedBonusObservation const> bonuses) noexcept;

void ClientRollPresentationMidHook(safetyhook::Context& context) noexcept
{
    try {
        // At this validated DCActiveRoll site:
        //   r14 = the replicated client RequestedRoll component
        //   rbx = the client VMRoll instance
        //   al  = RequestedRoll.AdvantageType, loaded by the prior instruction
        auto const component = reinterpret_cast<void const*>(context.r14);
        bool usedClientLease{};
        auto const selection = FindProfileRecord(component, &usedClientLease);
        if (!selection) {
            return;
        }
        auto const expected = boh::ClientPresentationAdvantage(*selection);
        if (!expected) {
            return;
        }

        auto const original = static_cast<std::uint8_t>(context.rax & 0xffU);
        context.rax = (context.rax & ~static_cast<std::uintptr_t>(0xffU))
            | static_cast<std::uintptr_t>(*expected);
        // This is the client-replicated copy only. Keeping its local
        // presentation byte consistent prevents later modifier viewmodels
        // from disabling a valid specialist advantage entry; server state and
        // every ownership/result field remain untouched.
        auto* componentAdvantage = At<std::uint8_t>(
            const_cast<void*>(component), kRequestedRollAdvantageOffset);
        std::uint8_t componentBefore{};
        bool const componentReadable = Read(
            componentAdvantage, componentBefore);
        bool componentCorrected{};
        if (componentReadable && componentBefore != *expected) {
            componentCorrected = Write(componentAdvantage, *expected);
        }
        BindClientPresentationLease(*selection, context.rbx);

        if (!TraceEnabled()) {
            return;
        }
        auto const& record = selection->record;
        auto const key = (record.id << 3U) | 7ULL;
        std::uint64_t pass = 0;
        {
            std::scoped_lock lock(g_profileTraceMutex);
            pass = ++g_profilePasses[key];
        }
        if (pass > 12) {
            return;
        }
        Log("TRACE", "native_client_roll_presentation_selected",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|pass=" + std::to_string(pass)
            + "|roll_handle=" + Hex(record.roll)
            + "|roll_uuid=" + record.rollUuid
            + "|initiator_handle=" + Hex(record.initiator)
            + "|specialist_handle=" + Hex(selection->specialist)
            + "|target_handle=" + Hex(record.target)
            + "|requested_advantage=" + std::to_string(original)
            + "|presentation_advantage=" + std::to_string(*expected)
            + "|corrected=" + std::to_string(original != *expected ? 1 : 0)
            + "|component_advantage_before="
            + (componentReadable
                ? std::to_string(componentBefore) : "unreadable")
            + "|component_advantage_corrected="
            + std::to_string(componentCorrected ? 1 : 0)
            + "|requested_roll_component="
            + Hex(reinterpret_cast<std::uintptr_t>(component))
            + "|vm_roll=" + Hex(context.rbx)
            + "|profile_scope=client"
            + "|presentation_source="
            + (usedClientLease ? "retained_lease" : "active_bridge")
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Presentation must fail open to the unmodified client value.
    }
}

void ClientRollSourceContextMidHook(safetyhook::Context& context) noexcept
{
    try {
        // At the validated call site:
        //   r14 = the replicated client RequestedRoll component
        //   rcx = &RequestedRoll.Roller
        //   rdx = DCActiveRoll's entity-viewmodel lookup context
        //
        // The relocated call consumes RCX after this callback. Stable
        // thread-local storage changes only that lookup argument; no entity
        // handle in either component is written.
        auto const component = reinterpret_cast<void const*>(context.r14);
        auto const selection = FindProfileRecord(component);
        if (!selection.has_value() || selection->specialist == 0) {
            return;
        }

        thread_local std::uint64_t specialist{};
        specialist = selection->specialist;
        auto const originalSource = context.rcx;
        context.rcx = reinterpret_cast<std::uintptr_t>(&specialist);

        if (!TraceEnabled()) {
            return;
        }
        std::uint64_t originalHandle{};
        Read(reinterpret_cast<void const*>(originalSource), originalHandle);
        auto const& record = selection->record;
        Log("TRACE", "native_client_roll_source_context_selected",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|initiator_handle=" + Hex(originalHandle)
            + "|specialist_handle=" + Hex(selection->specialist)
            + "|lookup_context=" + Hex(context.rdx)
            + "|requested_roll=" + Hex(context.r14)
            + "|presentation_only=1"
            + "|requested_roll_owner_unchanged=1"
            + "|authoritative_result_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Source presentation must fail open to the initiator-owned lookup.
    }
}

void ClientRollAggregateMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::Aggregate);
    try {
        // This is the final vanilla modifier-aggregation write before
        // DCActiveRoll notifies Noesis and enters result presentation:
        //   r13 = DCActiveRoll, rdx = VMRoll, r14b = computed advantage.
        // The exact VMRoll lease keeps this local to the delegated roll.
        auto const lease = FindClientPresentationLeaseByVmRoll(context.rdx);
        if (!lease.has_value()) {
            return;
        }
        auto const expected = CurrentClientPresentationAdvantage(*lease);
        if (!expected.has_value()) {
            return;
        }
        auto const computed = static_cast<std::uint8_t>(
            context.r14 & 0xffU);
        context.r14 = (context.r14
                & ~static_cast<std::uintptr_t>(0xffU))
            | static_cast<std::uintptr_t>(*expected);

        if (!TraceEnabled()) {
            return;
        }
        auto const& record = lease->selection->record;
        auto const key = 0x8000000000000000ULL ^ record.id;
        std::uint64_t pass{};
        {
            std::scoped_lock lock(g_profileTraceMutex);
            pass = ++g_profilePasses[key];
        }
        if (pass > 16) {
            return;
        }

        std::uint32_t rollState{};
        auto const activeRoll = reinterpret_cast<void const*>(context.r13);
        Read(At<std::uint32_t>(
            const_cast<void*>(activeRoll), kActiveRollStateOffset),
            rollState);
        std::uint8_t valueBefore{};
        Read(At<std::uint8_t>(
            reinterpret_cast<void*>(context.rdx),
            kVmRollAdvantageOffset),
            valueBefore);

        Log("TRACE", "native_client_roll_aggregate_guard",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|pass=" + std::to_string(pass)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|computed_advantage=" + std::to_string(computed)
            + "|expected_advantage=" + std::to_string(*expected)
            + "|vm_advantage_before=" + std::to_string(valueBefore)
            + "|corrected=" + std::to_string(
                computed != *expected ? 1 : 0)
            + "|vm_roll=" + Hex(context.rdx)
            + "|active_roll=" + Hex(context.r13)
            + "|presentation_source=retained_lease"
            + "|vanilla_notification_preserved=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // The aggregate guard only replaces a local presentation register.
        // It must fail open to vanilla behavior.
    }
}

void ClientRollStartMidHook(safetyhook::Context& context) noexcept
{
    BeginPerfRoll();
    PerfScope perf(PerfMetric::RollStart);
    try {
        // Every command invocation replaces any abandoned pending boundary
        // from the same UI thread.
        g_pendingRollPayloadActiveRoll = 0;
        g_pendingRollPayloadVmRoll = 0;
        g_pendingRollPostDispatchActiveRoll = 0;
        g_pendingRollPostDispatchVmRoll = 0;
        {
            PerfScope drainPerf(PerfMetric::DrainReleases);
            DrainDeferredClientViewModelReleases();
        }
        auto const activeRoll = reinterpret_cast<void*>(context.rcx);
        if (!IsReadable(activeRoll, kActiveRollVmRollOffset + sizeof(void*))) {
            return;
        }

        std::uint32_t rollState{};
        void* vmRoll{};
        if (!Read(At<std::uint32_t>(
                    activeRoll, kActiveRollStateOffset), rollState)
            || !Read(At<void*>(activeRoll, kActiveRollVmRollOffset), vmRoll)
            || vmRoll == nullptr) {
            return;
        }

        auto const lease = FindClientPresentationLeaseByVmRoll(
            reinterpret_cast<std::uintptr_t>(vmRoll));
        if (!lease.has_value()) {
            return;
        }
        IdentifyActivePerfRoll(
            reinterpret_cast<std::uintptr_t>(vmRoll), *lease);
        if (rollState == 1 || rollState == 2) {
            CaptureSelectedRollBonusViewModels(
                context.rcx,
                reinterpret_cast<std::uintptr_t>(vmRoll),
                rollState, *lease->selection);
        }
        if (rollState == 1) {
            // The successful WaitForStart branch later reuses DIL as a local
            // boolean, so the payload-ready site can no longer recover
            // DCActiveRoll from RDI. Carry the exact validated pair across
            // that one native call on the same thread instead.
            g_pendingRollPayloadActiveRoll =
                reinterpret_cast<std::uintptr_t>(activeRoll);
            g_pendingRollPayloadVmRoll =
                reinterpret_cast<std::uintptr_t>(vmRoll);
        }
        auto const expected = CurrentClientPresentationAdvantage(*lease);
        if (!expected.has_value()) {
            return;
        }
        bool const frozen = (rollState == 1 || rollState == 2)
            && FreezeClientPresentationAdvantage(
                reinterpret_cast<std::uintptr_t>(vmRoll), *expected);

        auto* advantage = At<std::uint8_t>(vmRoll, kVmRollAdvantageOffset);
        std::uint8_t observed{};
        if (!Read(advantage, observed)) {
            return;
        }

        // DCActiveRoll states 1 and 2 are WaitForStart and WaitForReRoll.
        // The XAML selects DieAnimation versus DoubleDieAnimation when the
        // command changes this state to StartRoll. Reassert the leased value
        // immediately before that transition as a final local-only guard.
        bool corrected{};
        if ((rollState == 1 || rollState == 2) && observed != *expected) {
            corrected = Write(advantage, *expected);
        }
        std::uint8_t after{};
        if (!Read(advantage, after)) {
            after = observed;
        }

        if (!TraceEnabled()) {
            return;
        }
        auto const& record = lease->selection->record;
        Log("TRACE", "native_client_roll_start_boundary",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|observed_advantage=" + std::to_string(observed)
            + "|expected_advantage=" + std::to_string(*expected)
            + "|presentation_frozen=" + std::to_string(frozen ? 1 : 0)
            + "|advantage_after=" + std::to_string(after)
            + "|corrected=" + std::to_string(corrected ? 1 : 0)
            + "|vm_roll="
            + Hex(reinterpret_cast<std::uintptr_t>(vmRoll))
            + "|active_roll="
            + Hex(reinterpret_cast<std::uintptr_t>(activeRoll))
            + "|presentation_source=retained_lease"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // The click boundary is diagnostics plus a local presentation guard.
        // It must never interfere with vanilla command processing.
    }
}

void ClientRollPayloadReadyMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::PayloadReady);
    try {
        // Reaching this hook proves the successful WaitForStart path has
        // completely materialized the detached command payload.
        (void)context;
        auto const activeRollAddress =
            std::exchange(g_pendingRollPayloadActiveRoll, 0);
        auto const expectedVmRoll =
            std::exchange(g_pendingRollPayloadVmRoll, 0);
        auto const activeRoll =
            reinterpret_cast<void*>(activeRollAddress);
        if (!IsReadable(activeRoll,
                kActiveRollVmRollOffset + sizeof(void*))) {
            return;
        }

        std::uint32_t rollState{};
        void* vmRoll{};
        if (!Read(At<void>(activeRoll, kActiveRollStateOffset), rollState)
            || rollState != 1
            || !Read(At<void*>(activeRoll, kActiveRollVmRollOffset), vmRoll)
            || vmRoll == nullptr
            || reinterpret_cast<std::uintptr_t>(vmRoll) != expectedVmRoll
            || !FindClientPresentationLeaseByVmRoll(
                    reinterpret_cast<std::uintptr_t>(vmRoll)).has_value()) {
            return;
        }

        ArmSelectedRollBonusPresentationAfterPayload(
            activeRollAddress,
            reinterpret_cast<std::uintptr_t>(vmRoll), rollState);
        g_pendingRollPostDispatchActiveRoll = activeRollAddress;
        g_pendingRollPostDispatchVmRoll =
            reinterpret_cast<std::uintptr_t>(vmRoll);
    } catch (...) {
        // Presentation preparation must never interfere with dispatching the
        // already-materialized native roll command.
    }
}

void ClientRollPostDispatchMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::PostDispatch);
    try {
        // The epilogue is shared by early-exit paths, so only a pair armed by
        // the successful payload-ready hook may restore selected UI state.
        (void)context;
        auto const activeRoll =
            std::exchange(g_pendingRollPostDispatchActiveRoll, 0);
        auto const vmRoll =
            std::exchange(g_pendingRollPostDispatchVmRoll, 0);
        if (activeRoll == 0 || vmRoll == 0) {
            return;
        }
        RestoreSelectedRollBonusList(
            activeRoll, vmRoll, "post_dispatch");
    } catch (...) {
        // The authoritative command is already dispatched. Presentation
        // restoration must fail open to the remaining vanilla epilogue.
    }
}

void ClientRollResultMidHook(safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::Result);
    try {
        // This is the result-consistency decision immediately after BG3 loads
        // VMRoll.RollAdvantageType into CL and before it publishes either the
        // natural die or the already-summed total to the visible-value
        // property.
        auto const vmRoll = context.rax;
        auto const lease = FindClientPresentationLeaseByVmRoll(vmRoll);
        if (!lease.has_value()) {
            return;
        }
        auto const expected = CurrentClientPresentationAdvantage(*lease);
        if (!expected.has_value()) {
            return;
        }
        auto const result = reinterpret_cast<void*>(context.rbx);
        if (!IsReadable(result, kMinimumRollResultBytes)) {
            return;
        }
        std::uint8_t natural{};
        std::uint8_t discarded{};
        std::int8_t modifier{};
        if (!Read(At<std::uint8_t>(result, kRollResultNaturalOffset), natural)
            || !Read(At<std::uint8_t>(
                    result, kRollResultDiscardedOffset), discarded)
            || !Read(At<std::int8_t>(
                    result, kRollResultModifierOffset), modifier)) {
            return;
        }

        auto const activeRoll = reinterpret_cast<void*>(context.rdi);
        auto* fallback = At<std::uint8_t>(
            activeRoll, kActiveRollFallbackOffset);
        std::uint8_t fallbackBefore{};
        bool const fallbackReadable = Read(fallback, fallbackBefore);
        bool fallbackReset{};
        if (natural >= 1 && natural <= 20
            && fallbackReadable && fallbackBefore != 0) {
            fallbackReset = Write(fallback, std::uint8_t{ 0 });
        }
        std::uint8_t fallbackAfter{};
        bool const fallbackAfterReadable = Read(fallback, fallbackAfter);
        std::uint8_t displayedBefore{};
        bool const displayedReadable = Read(At<std::uint8_t>(
            activeRoll, kActiveRollDisplayedValueOffset), displayedBefore);
        std::uint8_t immediateTotalBefore{};
        bool const immediateTotalReadable = Read(At<std::uint8_t>(
            activeRoll, kActiveRollImmediateTotalOffset),
            immediateTotalBefore);

        auto const observed = static_cast<std::uint8_t>(
            context.rcx & 0xffU);
        context.rcx = (context.rcx
                & ~static_cast<std::uintptr_t>(0xffU))
            | static_cast<std::uintptr_t>(*expected);

        auto* advantage = At<std::uint8_t>(
            reinterpret_cast<void*>(vmRoll), kVmRollAdvantageOffset);
        std::uint8_t fieldBefore{};
        bool const fieldReadable = Read(advantage, fieldBefore);
        bool fieldCorrected{};
        if (fieldReadable && fieldBefore != *expected) {
            fieldCorrected = Write(advantage, *expected);
        }
        auto* componentAdvantage = At<std::uint8_t>(
            result, kRequestedRollAdvantageOffset);
        std::uint8_t componentBefore{};
        bool const componentReadable = Read(
            componentAdvantage, componentBefore);
        bool componentCorrected{};
        if (componentReadable && componentBefore != *expected) {
            componentCorrected = Write(componentAdvantage, *expected);
        }

        if (!TraceEnabled()) {
            return;
        }
        std::uint32_t rollState{};
        Read(At<std::uint32_t>(
            reinterpret_cast<void*>(context.rdi), kActiveRollStateOffset),
            rollState);
        auto const& record = lease->selection->record;
        Log("TRACE", "native_client_roll_result_consistency",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|observed_advantage=" + std::to_string(observed)
            + "|expected_advantage=" + std::to_string(*expected)
            + "|presentation_frozen="
            + std::to_string(lease->presentationFrozen ? 1 : 0)
            + "|result_natural=" + std::to_string(natural)
            + "|result_discarded=" + std::to_string(discarded)
            + "|result_modifier=" + std::to_string(
                static_cast<int>(modifier))
            + "|result_has_second_die="
            + std::to_string(discarded != 0 ? 1 : 0)
            + "|consistency_before="
            + std::to_string(
                (observed != 0) == (discarded != 0) ? 1 : 0)
            + "|consistency_after="
            + std::to_string(
                (*expected != 0) == (discarded != 0) ? 1 : 0)
            + "|register_corrected="
            + std::to_string(observed != *expected ? 1 : 0)
            + "|field_before="
            + (fieldReadable ? std::to_string(fieldBefore) : "unreadable")
            + "|field_corrected="
            + std::to_string(fieldCorrected ? 1 : 0)
            + "|component_advantage_before="
            + (componentReadable
                ? std::to_string(componentBefore) : "unreadable")
            + "|component_advantage_corrected="
            + std::to_string(componentCorrected ? 1 : 0)
            + "|fallback_before="
            + (fallbackReadable
                ? std::to_string(fallbackBefore) : "unreadable")
            + "|fallback_after="
            + (fallbackAfterReadable
                ? std::to_string(fallbackAfter) : "unreadable")
            + "|fallback_reset="
            + std::to_string(fallbackReset ? 1 : 0)
            + "|displayed_value_before="
            + (displayedReadable
                ? std::to_string(displayedBefore) : "unreadable")
            + "|immediate_total_before="
            + (immediateTotalReadable
                ? std::to_string(immediateTotalBefore) : "unreadable")
            + "|vm_roll=" + Hex(vmRoll)
            + "|active_roll=" + Hex(context.rdi)
            + "|result_payload=" + Hex(context.rbx)
            + "|result_numeric_values_unchanged=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Result correction is presentation-only and must fail open.
    }
}

using ClientPropertyChangedProc = void (*)(void*, void*, void*);
using ClientVmDiceTypeSetPropertySetterProc = void (*)(void*, void*);
using ClientVmRollModifierSourceVmPropertySetterProc = void (*)(void*, void*);
using ClientVmRollModifierNameValueAssignProc = void (*)(void*, void const*);
using ClientVmRollModifierFactoryProc = void* (*)();
using NoesisGetClassTypeProc = void const* (*)(void const*);
using NoesisTypePropertyGetContentProc =
    void const* (*)(void const*, void const*);

struct NoesisPropertyValue {
    std::uintptr_t property{};
    std::uint32_t nameSymbol{};
    std::uintptr_t contentType{};
    std::uintptr_t value{};
};

struct CachedNoesisNameProperty {
    std::uintptr_t classType{};
    std::uintptr_t property{};
    std::uint32_t nameSymbol{};
    std::uintptr_t contentType{};
};

constexpr std::size_t kMaximumCachedNoesisNameSourceClasses = 16;
thread_local CachedNoesisNameProperty g_cachedVmRollModifierNameProperty;
thread_local FixedSnapshot<CachedNoesisNameProperty,
    kMaximumCachedNoesisNameSourceClasses> g_cachedSourceNameProperties;

std::uintptr_t GetNoesisClassType(std::uintptr_t object) noexcept
{
    if (object == 0) {
        return 0;
    }
    std::uintptr_t vtable{};
    std::uintptr_t function{};
    if (!Read(reinterpret_cast<void const*>(object), vtable)
        || vtable == 0
        || !Read(reinterpret_cast<void const*>(
                vtable + kNoesisGetClassTypeVtableIndex
                    * sizeof(std::uintptr_t)),
            function)
        || function == 0) {
        return 0;
    }
    __try {
        auto const getClassType =
            reinterpret_cast<NoesisGetClassTypeProc>(function);
        return reinterpret_cast<std::uintptr_t>(
            getClassType(reinterpret_cast<void const*>(object)));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

std::uintptr_t GetNoesisTypePropertyContent(
    std::uintptr_t property, std::uintptr_t object) noexcept
{
    if (property == 0 || object == 0) {
        return 0;
    }
    std::uintptr_t vtable{};
    std::uintptr_t function{};
    if (!Read(reinterpret_cast<void const*>(property), vtable)
        || vtable == 0
        || !Read(reinterpret_cast<void const*>(
                vtable + kNoesisTypePropertyGetContentVtableIndex
                    * sizeof(std::uintptr_t)),
            function)
        || function == 0) {
        return 0;
    }
    __try {
        auto const getContent =
            reinterpret_cast<NoesisTypePropertyGetContentProc>(function);
        return reinterpret_cast<std::uintptr_t>(
            getContent(reinterpret_cast<void const*>(property),
                reinterpret_cast<void const*>(object)));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

bool FindNoesisProperty(std::uintptr_t object,
    std::optional<std::uint32_t> nameSymbol,
    std::optional<std::uintptr_t> expectedValue,
    std::optional<std::uintptr_t> expectedContentType,
    NoesisPropertyValue& result) noexcept
{
    result = {};
    auto classType = GetNoesisClassType(object);
    for (std::size_t depth = 0;
         classType != 0 && depth < kMaximumNoesisClassDepth; ++depth) {
        std::uintptr_t properties{};
        std::uint32_t propertyCount{};
        if (!Read(reinterpret_cast<void const*>(
                    classType + kNoesisTypeClassPropertiesOffset),
                properties)
            || !Read(reinterpret_cast<void const*>(
                    classType + kNoesisTypeClassPropertiesOffset
                        + kNoesisVectorSizeOffset),
                propertyCount)
            || propertyCount > kMaximumNoesisPropertiesPerClass
            || (propertyCount != 0 && properties == 0)) {
            return false;
        }

        for (std::uint32_t index = 0; index < propertyCount; ++index) {
            std::uintptr_t property{};
            std::uint32_t observedNameSymbol{};
            std::uintptr_t observedContentType{};
            if (!Read(reinterpret_cast<void const*>(
                        properties
                            + static_cast<std::uintptr_t>(index)
                                * sizeof(std::uintptr_t)),
                    property)
                || property == 0
                || !Read(reinterpret_cast<void const*>(
                        property + kNoesisTypePropertyNameSymbolOffset),
                    observedNameSymbol)
                || !Read(reinterpret_cast<void const*>(
                        property
                            + kNoesisTypePropertyContentTypeOffset),
                    observedContentType)
                || (nameSymbol.has_value()
                    && observedNameSymbol != *nameSymbol)
                || (expectedContentType.has_value()
                    && observedContentType != *expectedContentType)) {
                continue;
            }

            auto const value =
                GetNoesisTypePropertyContent(property, object);
            if (value == 0
                || (expectedValue.has_value()
                    && value != *expectedValue)) {
                continue;
            }
            result = NoesisPropertyValue{
                .property = property,
                .nameSymbol = observedNameSymbol,
                .contentType = observedContentType,
                .value = value,
            };
            return true;
        }

        std::uintptr_t baseClass{};
        if (!Read(reinterpret_cast<void const*>(
                    classType + kNoesisTypeClassBaseOffset),
                baseClass)
            || baseClass == classType) {
            break;
        }
        classType = baseClass;
    }
    return false;
}

bool FindVmRollModifierNameProperty(std::uintptr_t viewModel,
    NoesisPropertyValue& result) noexcept
{
    result = {};
    auto const classType = GetNoesisClassType(viewModel);
    auto const expectedValue =
        viewModel + kDynamicModifierVmNameValueOffset;
    auto const& cached = g_cachedVmRollModifierNameProperty;
    if (classType != 0 && cached.classType == classType
        && cached.property != 0) {
        auto const value = GetNoesisTypePropertyContent(
            cached.property, viewModel);
        if (value == expectedValue) {
            result = NoesisPropertyValue{
                .property = cached.property,
                .nameSymbol = cached.nameSymbol,
                .contentType = cached.contentType,
                .value = value,
            };
            return true;
        }
    }

    if (!FindNoesisProperty(viewModel, std::nullopt,
            expectedValue, std::nullopt, result)) {
        return false;
    }
    g_cachedVmRollModifierNameProperty = CachedNoesisNameProperty{
        .classType = classType,
        .property = result.property,
        .nameSymbol = result.nameSymbol,
        .contentType = result.contentType,
    };
    return true;
}

bool FindSourceNameProperty(std::uintptr_t source,
    NoesisPropertyValue const& target,
    NoesisPropertyValue& result) noexcept
{
    result = {};
    auto const classType = GetNoesisClassType(source);
    for (auto const& cached : g_cachedSourceNameProperties) {
        if (cached.classType != classType
            || cached.nameSymbol != target.nameSymbol
            || cached.contentType != target.contentType
            || cached.property == 0) {
            continue;
        }
        auto const value = GetNoesisTypePropertyContent(
            cached.property, source);
        if (value != 0) {
            result = NoesisPropertyValue{
                .property = cached.property,
                .nameSymbol = cached.nameSymbol,
                .contentType = cached.contentType,
                .value = value,
            };
            return true;
        }
    }

    if (!FindNoesisProperty(source, target.nameSymbol,
            std::nullopt, target.contentType, result)) {
        return false;
    }
    if (g_cachedSourceNameProperties.size()
        < kMaximumCachedNoesisNameSourceClasses) {
        g_cachedSourceNameProperties.push_back(CachedNoesisNameProperty{
            .classType = classType,
            .property = result.property,
            .nameSymbol = result.nameSymbol,
            .contentType = result.contentType,
        });
    }
    return true;
}

bool NotifyDynamicModifierProperty(std::uintptr_t viewModel,
    std::size_t propertySourceOffset,
    std::size_t propertyMarkerOffset) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr || viewModel == 0) {
        return false;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    void* property{};
    void* source{};
    if (!Read(reinterpret_cast<void const*>(
            base + g_build->clientModifierDisabledPropertyRva), property)
        || property == nullptr
        || !Read(At<void*>(reinterpret_cast<void*>(viewModel),
            propertySourceOffset), source)
        || source == nullptr) {
        return false;
    }
    auto const notify = reinterpret_cast<ClientPropertyChangedProc>(
        base + g_build->clientPropertyChangedRva);
    notify(property, source,
        At<void>(reinterpret_cast<void*>(viewModel),
            propertyMarkerOffset));
    return true;
}

bool NotifyDynamicModifierDisabled(std::uintptr_t viewModel) noexcept
{
    return NotifyDynamicModifierProperty(viewModel,
        kDynamicModifierVmPropertySourceOffset,
        kDynamicModifierVmPropertyMarkerOffset);
}

bool NotifyDynamicModifierVisibility(std::uintptr_t viewModel) noexcept
{
    return NotifyDynamicModifierProperty(viewModel,
        kDynamicModifierVmVisibilitySourceOffset,
        kDynamicModifierVmVisibilityMarkerOffset);
}

bool SetDynamicModifierDiceTypeSet(std::uintptr_t viewModel,
    std::uintptr_t diceTypeSet) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr
        || viewModel == 0 || diceTypeSet == 0) {
        return false;
    }

    auto* property = At<void>(reinterpret_cast<void*>(viewModel),
        kDynamicModifierVmDiceTypeSetPropertyOffset);
    __try {
        // This is the exact non-virtual setter used by BG3 when it populates a
        // VMRollModifier. It retains/releases the DiceTypeSet, stores it at
        // property+10h (viewModel+110h), and raises the DiceTypeSet property
        // notification consumed by the result animation.
        auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
        auto const setter =
            reinterpret_cast<ClientVmDiceTypeSetPropertySetterProc>(
                base
                + g_build->clientVmDiceTypeSetPropertySetterRva);
        setter(
            property, reinterpret_cast<void*>(diceTypeSet));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    std::uintptr_t observed{};
    return Read(At<std::uintptr_t>(reinterpret_cast<void*>(viewModel),
                    kDynamicModifierVmDiceTypeSetOffset),
               observed)
        && observed == diceTypeSet;
}

bool SetDynamicModifierByteProperty(std::uintptr_t viewModel,
    std::size_t valueOffset, std::uint8_t value,
    std::size_t propertySourceOffset,
    std::size_t propertyMarkerOffset) noexcept
{
    PerfScope perf(PerfMetric::SetByteProperty);
    if (viewModel == 0) {
        return false;
    }
    auto* propertyValue = At<std::uint8_t>(
        reinterpret_cast<void*>(viewModel), valueOffset);
    std::uint8_t observed{};
    if (!Read(propertyValue, observed)) {
        return false;
    }
    if (observed == value) {
        return true;
    }
    return Write(propertyValue, value)
        && NotifyDynamicModifierProperty(viewModel,
            propertySourceOffset, propertyMarkerOffset);
}

bool SetDynamicModifierRollBonusPresentationType(
    std::uintptr_t viewModel) noexcept
{
    PerfScope perf(PerfMetric::SetPresentationType);
    return SetDynamicModifierByteProperty(viewModel,
            kDynamicModifierVmBoostTypeOffset, kDynamicModifierRollBonusType,
            kDynamicModifierVmBoostTypePropertySourceOffset,
            kDynamicModifierVmBoostTypePropertyMarkerOffset)
        && SetDynamicModifierByteProperty(viewModel,
            kDynamicModifierVmSourceTypeOffset,
            kDynamicModifierRollBonusSourceType,
            kDynamicModifierVmSourceTypePropertySourceOffset,
            kDynamicModifierVmSourceTypePropertyMarkerOffset);
}

bool SetDynamicModifierSourceVm(std::uintptr_t viewModel,
    std::uintptr_t sourceVm) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr
        || viewModel == 0 || sourceVm == 0) {
        return false;
    }
    __try {
        // VMRollModifier.SourceVM is the retained presentation object that
        // supplies the native modifier label and icon. Use BG3's exact setter
        // so the source is AddRef'd, the old value is released, and Noesis
        // receives the same property notification as vanilla.
        auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
        auto const setter =
            reinterpret_cast<ClientVmRollModifierSourceVmPropertySetterProc>(
                base
                + g_build->clientVmRollModifierSourceVmPropertySetterRva);
        setter(reinterpret_cast<void*>(viewModel),
            reinterpret_cast<void*>(sourceVm));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    std::uintptr_t observed{};
    return Read(At<std::uintptr_t>(reinterpret_cast<void*>(viewModel),
                    kDynamicModifierVmSourceVmOffset),
               observed)
        && observed == sourceVm;
}

bool SetDynamicModifierNameFromPresentationObject(
    std::uintptr_t viewModel, std::uintptr_t presentationObject) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr
        || viewModel == 0 || presentationObject == 0) {
        return false;
    }

    // VMRollModifier.Name and the selected presentation viewmodel's Name are
    // reflected Noesis properties, but concrete source classes do not share a
    // stable native offset. Discover the Name symbol and value type from the
    // known VMRollModifier member, then resolve the same typed property on the
    // object that BG3 used to render the selected row.
    NoesisPropertyValue targetNameProperty;
    if (!FindVmRollModifierNameProperty(
            viewModel, targetNameProperty)) {
        return false;
    }
    NoesisPropertyValue sourceNameProperty;
    if (!FindSourceNameProperty(presentationObject,
            targetNameProperty, sourceNameProperty)) {
        return false;
    }

    bool assigned{};
    __try {
        // Use the exact native value assignment routine used by BG3's static
        // modifier renderer so localized handles, reference counts, and
        // mod-provided names remain owned by BG3.
        auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
        auto const assign =
            reinterpret_cast<ClientVmRollModifierNameValueAssignProc>(
                base
                + g_build->clientVmRollModifierNameValueAssignRva);
        assign(At<void>(reinterpret_cast<void*>(viewModel),
                   kDynamicModifierVmNameValueOffset),
            reinterpret_cast<void const*>(sourceNameProperty.value));
        // The value assignment deliberately excludes the two trailing
        // translated-string flags. BG3's renderer copies them immediately
        // afterward, so mirror that exact second step.
        std::array<std::byte, 2> flags{};
        assigned = Read(reinterpret_cast<void const*>(
                            sourceNameProperty.value + 0x10),
                        flags)
            && Write(At<std::array<std::byte, 2>>(
                         reinterpret_cast<void*>(viewModel),
                         kDynamicModifierVmNameValueOffset + 0x10),
                flags);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    // The native assignment routine may retain or canonicalize the localized
    // string into a different backing allocation. Raw byte equality is not a
    // valid postcondition; BG3's own renderer likewise trusts the assignment
    // and emits the property notification without comparing object bytes.
    bool const notified = assigned
        && NotifyDynamicModifierProperty(viewModel,
            kDynamicModifierVmNamePropertySourceOffset,
            kDynamicModifierVmNamePropertyMarkerOffset);
    return assigned && notified;
}

bool SetDynamicModifierNameFromPresentation(
    std::uintptr_t viewModel, std::uintptr_t selectedViewModel,
    std::uintptr_t sourceVm) noexcept
{
    PerfScope perf(PerfMetric::SetNamePresentation);
    // The selected VMBoostModifier is the exact object whose label is visible
    // before the user clicks the die. Its nested SourceVM supplies the icon,
    // but its reflected Name may describe a different source/caster object.
    // Prefer the selected row's Name and retain SourceVM only as a fallback
    // for bonus implementations that do not expose Name on VMBoostModifier.
    if (selectedViewModel != 0) {
        if (SetDynamicModifierNameFromPresentationObject(
                viewModel, selectedViewModel)) {
            return true;
        }
    }
    if (sourceVm != 0) {
        return SetDynamicModifierNameFromPresentationObject(
            viewModel, sourceVm);
    }
    return false;
}

bool SetDynamicModifierResolvedValue(
    std::uintptr_t viewModel, std::int32_t value) noexcept
{
    PerfScope perf(PerfMetric::SetResolvedValue);
    if (viewModel == 0 || value <= 0) {
        return false;
    }
    auto* propertyValue = At<double>(
        reinterpret_cast<void*>(viewModel),
        kDynamicModifierVmValueOffset);
    double observed{};
    auto const resolved = static_cast<double>(value);
    if (!Read(propertyValue, observed)) {
        return false;
    }
    if (observed == resolved) {
        return true;
    }
    return Write(propertyValue, resolved)
        && NotifyDynamicModifierProperty(viewModel,
            kDynamicModifierVmValuePropertySourceOffset,
            kDynamicModifierVmValuePropertyMarkerOffset);
}

bool SetSelectedRollBonusResolvedValue(
    std::uintptr_t selectedViewModel, std::int32_t value) noexcept
{
    if (g_gameModule == nullptr || g_build == nullptr
        || selectedViewModel == 0 || value <= 0 || value > 255) {
        return false;
    }

    // DCActiveRoll's modifier-animation callback first tries to cast its event
    // to VMRollModifier and reads Value at +0c0h. If that cast fails, BG3 calls
    // this exact helper for a selected VMBoostModifier and adds the byte at
    // +0b0h from the returned native object. Use that same guarded helper
    // instead of guessing a VMBoostModifier layout or special-casing Guidance.
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    auto const resolve = reinterpret_cast<ClientSelectedModifierValueProc>(
        base + g_build->clientSelectedModifierValueRva);
    void* selectedValue{};
    __try {
        selectedValue = resolve(
            reinterpret_cast<void*>(selectedViewModel));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    if (selectedValue == nullptr) {
        return false;
    }
    auto* propertyValue = At<std::uint8_t>(
        selectedValue, kSelectedModifierResolvedValueOffset);
    std::uint8_t observed{};
    auto const resolved = static_cast<std::uint8_t>(value);
    if (!Read(propertyValue, observed)
        || !Write(propertyValue, resolved)) {
        return false;
    }
    std::uint8_t verified{};
    if (!Read(propertyValue, verified) || verified != resolved) {
        Write(propertyValue, observed);
        return false;
    }
    return true;
}

bool ReadSelectedRollBonusSourceVm(std::uintptr_t viewModel,
    std::uintptr_t& sourceVm) noexcept
{
    sourceVm = 0;
    return viewModel != 0
        && Read(At<std::uintptr_t>(reinterpret_cast<void*>(viewModel),
            kSelectedBoostVmSourceVmOffset), sourceVm);
}

bool ReadSelectedRollBonusViewModel(std::uintptr_t viewModel,
    std::uintptr_t& diceTypeSet, DynamicModifierIdentity& identity,
    std::uint8_t& diceSize, std::uint8_t& diceCount,
    std::uint8_t& visible) noexcept
{
    diceTypeSet = 0;
    identity = {};
    diceSize = 0;
    diceCount = 0;
    visible = 0;
    return viewModel != 0
        && Read(At<std::uintptr_t>(reinterpret_cast<void*>(viewModel),
            kSelectedBoostVmDiceTypeSetOffset), diceTypeSet)
        && diceTypeSet != 0
        && Read(At<std::array<std::uint64_t, 2>>(
            reinterpret_cast<void*>(viewModel),
            kSelectedBoostVmIdentityOffset), identity.guid)
        && Read(At<std::uint8_t>(
            reinterpret_cast<void*>(viewModel),
            kSelectedBoostVmIdentityOffset
                + kDynamicModifierIdTypeOffset), identity.type)
        && Read(At<std::uint8_t>(
            reinterpret_cast<void*>(diceTypeSet),
            kDynamicModifierDescriptorDiceSizeOffset), diceSize)
        && Read(At<std::uint8_t>(
            reinterpret_cast<void*>(diceTypeSet),
            kDynamicModifierDescriptorDiceCountOffset), diceCount)
        && Read(At<std::uint8_t>(
            reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmVisibleOffset), visible);
}

std::uintptr_t InvokeVmRollModifierFactory(
    std::uintptr_t factoryAddress) noexcept
{
    __try {
        auto const factory =
            reinterpret_cast<ClientVmRollModifierFactoryProc>(
                factoryAddress);
        return reinterpret_cast<std::uintptr_t>(factory());
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 0;
    }
}

std::uintptr_t CreateVmRollModifierViewModel(
    std::uintptr_t diceTypeSet,
    DynamicModifierIdentity const& identity,
    std::uintptr_t selectedViewModel,
    std::uintptr_t sourceVm, std::int32_t resolvedValue, bool& typed,
    bool& sourceVmTransferred,
    bool& nameTransferred,
    bool& valueTransferred,
    bool requireResolvedValue = true) noexcept
{
    typed = false;
    sourceVmTransferred = false;
    nameTransferred = false;
    valueTransferred = false;
    if (g_gameModule == nullptr || g_build == nullptr
        || diceTypeSet == 0) {
        return 0;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    auto const viewModel = InvokeVmRollModifierFactory(
        base + g_build->clientVmRollModifierFactoryRva);
    if (viewModel == 0) {
        return 0;
    }

    bool const diceTypeSetConfigured = SetDynamicModifierDiceTypeSet(
        viewModel, diceTypeSet);
    typed = SetDynamicModifierRollBonusPresentationType(viewModel);
    sourceVmTransferred = sourceVm != 0
        && SetDynamicModifierSourceVm(viewModel, sourceVm);
    nameTransferred = SetDynamicModifierNameFromPresentation(
        viewModel, selectedViewModel, sourceVm);
    valueTransferred = SetDynamicModifierResolvedValue(
        viewModel, resolvedValue);
    bool const guidSet = Write(At<std::array<std::uint64_t, 2>>(
            reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmGuidOffset), identity.guid);
    bool const disabledSet = Write(At<std::uint8_t>(
            reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDisabledOffset), std::uint8_t{0});
    bool const stateSet = Write(At<std::uint8_t>(
            reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmStateOffset), std::uint8_t{0});
    bool const configured =
        diceTypeSetConfigured && typed && sourceVmTransferred
        && nameTransferred
        && (!requireResolvedValue || valueTransferred)
        && guidSet && disabledSet && stateSet;
    if (!configured) {
        if (TraceEnabled()) {
            Log("TRACE", "native_client_vmroll_modifier_factory_failed",
                "viewmodel=" + Hex(viewModel)
                + "|dice_type_set=" + Hex(diceTypeSet)
                + "|dice_type_set_configured="
                + std::to_string(diceTypeSetConfigured ? 1 : 0)
                + "|presentation_type_set="
                + std::to_string(typed ? 1 : 0)
                + "|source_vm=" + Hex(sourceVm)
                + "|source_vm_set="
                + std::to_string(sourceVmTransferred ? 1 : 0)
                + "|name_from_source_vm_set="
                + std::to_string(nameTransferred ? 1 : 0)
                + "|name_binding_strategy=typed_noesis_reflection"
                + "|resolved_value="
                + std::to_string(resolvedValue)
                + "|resolved_value_set="
                + std::to_string(valueTransferred ? 1 : 0)
                + "|resolved_value_required="
                + std::to_string(requireResolvedValue ? 1 : 0)
                + "|guid_set=" + std::to_string(guidSet ? 1 : 0)
                + "|disabled_set="
                + std::to_string(disabledSet ? 1 : 0)
                + "|state_set=" + std::to_string(stateSet ? 1 : 0)
                + "|factory_class=VMRollModifier_size_1f0"
                + "|property_setters=exact_nonvirtual"
                + "|thread_id=" + std::to_string(GetCurrentThreadId())
                + "|tick_ms=" + std::to_string(GetTickCount64()));
        }
        ReleaseClientIntrusiveObject(viewModel);
        return 0;
    }
    return viewModel;
}

bool ContainsDynamicModifierIdentity(void const* modifiersComponent,
    std::size_t arrayOffset,
    DynamicModifierIdentity const& identity) noexcept
{
    if (modifiersComponent == nullptr) {
        return false;
    }
    void* data{};
    std::int32_t count{};
    auto* component = const_cast<void*>(modifiersComponent);
    if (!Read(At<void*>(component, arrayOffset), data)
        || !Read(At<std::int32_t>(
            component, arrayOffset + 0x0c), count)
        || count < 0 || count > 1024
        || (count != 0
            && !IsReadable(data,
                static_cast<std::size_t>(count)
                    * kDynamicModifierIdSize))) {
        return false;
    }
    auto const* bytes = static_cast<std::byte const*>(data);
    for (std::int32_t index = 0; index < count; ++index) {
        auto const* current = bytes
            + static_cast<std::size_t>(index)
                * kDynamicModifierIdSize;
        std::array<std::uint64_t, 2> guid{};
        std::uint8_t type{};
        if (Read(current, guid)
            && Read(current + kDynamicModifierIdTypeOffset, type)
            && guid == identity.guid
            && type == identity.type) {
            return true;
        }
    }
    return false;
}

std::optional<std::size_t> ConsumeResolvedBonus(
    RollBonusReconciliationObservation& observation,
    std::uint8_t diceSize, std::uint8_t diceCount) noexcept
{
    if (diceCount == 0) {
        return {};
    }
    for (std::size_t index = 0; index < observation.bonusCount; ++index) {
        auto& bonus = observation.bonuses[index];
        if (!bonus.consumed
            && bonus.diceSize == diceSize
            && bonus.diceCount == diceCount) {
            bonus.consumed = true;
            return index;
        }
    }
    return {};
}

bool FindStaticModifier(void const* modifiersComponent,
    std::array<std::uint64_t, 2> const& guid,
    void const*& modifier) noexcept
{
    modifier = nullptr;
    if (modifiersComponent == nullptr
        || (guid[0] == 0 && guid[1] == 0)) {
        return false;
    }
    void* data{};
    std::int32_t count{};
    if (!Read(At<void*>(const_cast<void*>(modifiersComponent),
            kRollModifiersStaticModifiersOffset), data)
        || !Read(At<std::int32_t>(const_cast<void*>(modifiersComponent),
            kRollModifiersStaticModifierCountOffset), count)
        || count < 0 || count > 1024
        || (count != 0
            && !IsReadable(data,
                static_cast<std::size_t>(count) * kStaticModifierSize))) {
        return false;
    }
    auto const bytes = static_cast<std::byte const*>(data);
    for (std::int32_t index = 0; index < count; ++index) {
        auto const current = bytes
            + static_cast<std::size_t>(index) * kStaticModifierSize;
        std::array<std::uint64_t, 2> currentGuid{};
        if (Read(current, currentGuid) && currentGuid == guid) {
            modifier = current;
            return true;
        }
    }
    return false;
}

std::optional<std::uint32_t> ClientModifierCollectionCount(
    void* collection) noexcept
{
    void* backing{};
    std::uint32_t count{};
    if (collection == nullptr
        || !Read(At<void*>(collection,
                kObservableCollectionBackingOffset), backing)
        || backing == nullptr
        || !Read(At<std::uint32_t>(backing,
                kObservableCollectionBackingCountOffset), count)
        || count > kMaximumObservedDynamicModifierViewModels) {
        return {};
    }
    return count;
}

ClientModifierCollectionSnapshot SnapshotClientModifierCollection(
    void* collection, std::uintptr_t getterRva) noexcept
{
    PerfScope perf(PerfMetric::SnapshotCollection);
    ClientModifierCollectionSnapshot result;
    if (g_gameModule == nullptr || g_build == nullptr
        || collection == nullptr || getterRva == 0) {
        return result;
    }
    auto const count = ClientModifierCollectionCount(collection);
    if (!count.has_value()) {
        return result;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    auto const get = reinterpret_cast<ClientModifierCollectionGetProc>(
        base + getterRva);
    for (std::uint32_t index = 0; index < *count; ++index) {
        auto const viewModel = get(
            collection, static_cast<std::int32_t>(index));
        if (viewModel != nullptr) {
            result.push_back(
                reinterpret_cast<std::uintptr_t>(viewModel));
        }
    }
    return result;
}

bool ClientModifierCollectionContains(void* collection,
    std::uintptr_t getterRva, std::uintptr_t viewModel) noexcept
{
    auto const entries = SnapshotClientModifierCollection(
        collection, getterRva);
    return std::find(entries.begin(), entries.end(), viewModel)
        != entries.end();
}

bool ClientRollBonusKeepSelectedDetour(
    void* collection, void* viewModel) noexcept
{
    try {
        auto const collectionAddress =
            reinterpret_cast<std::uintptr_t>(collection);
        auto const viewModelAddress =
            reinterpret_cast<std::uintptr_t>(viewModel);
        if (collectionAddress >= kActiveRollDynamicModifierCollectionOffset
            && viewModelAddress != 0) {
            auto const activeRoll = collectionAddress
                - kActiveRollDynamicModifierCollectionOffset;
            void* vmRoll{};
            if (Read(At<void*>(
                        reinterpret_cast<void*>(activeRoll),
                        kActiveRollVmRollOffset), vmRoll)
                && vmRoll != nullptr) {
                std::optional<boh::ProfileSelection> preserved;
                {
                    std::scoped_lock lock(
                        g_clientPresentationLeaseMutex);
                    auto const indexed =
                        g_clientPresentationLeaseByVmRoll.find(
                            reinterpret_cast<std::uintptr_t>(vmRoll));
                    auto const found = indexed
                        == g_clientPresentationLeaseByVmRoll.end()
                        ? g_clientPresentationLeases.end()
                        : g_clientPresentationLeases.find(indexed->second);
                    if (found != g_clientPresentationLeases.end()) {
                        auto const& current = found->second;
                        if (!current.selectedRemovalGuardArmed) {
                            // The exact roll is known, but its handoff guard is
                            // not active; preserve vanilla removal.
                        } else {
                            auto const begin =
                                current.retainedRollBonusViewModels.begin();
                            auto const end = begin
                                + static_cast<std::ptrdiff_t>(
                                    current.retainedRollBonusViewModelCount);
                            if (current.selection != nullptr
                                && std::find(begin, end, viewModelAddress)
                                != end) {
                                preserved = *current.selection;
                            }
                        }
                    }
                }
                if (preserved.has_value()) {
                    if (TraceEnabled()) {
                        auto const& record = preserved->record;
                        Log("TRACE",
                            "native_client_roll_selected_bonus_removal_suppressed",
                            "action=" + boh::ActionName(record.kind)
                            + "|delegation_id="
                            + std::to_string(record.id)
                            + "|roll_uuid=" + record.rollUuid
                            + "|selected_viewmodel="
                            + Hex(viewModelAddress)
                            + "|collection=" + Hex(collectionAddress)
                            + "|continuity=preserved_until_authoritative_handoff"
                            + "|authoritative_result_unchanged=1"
                            + "|component_owner_unchanged=1"
                            + "|thread_id="
                            + std::to_string(GetCurrentThreadId())
                            + "|tick_ms="
                            + std::to_string(GetTickCount64()));
                    }
                    return false;
                }
            }
        }
    } catch (...) {
        // Any ambiguity falls through to BG3's original collection removal.
    }
    return g_clientRollBonusKeepSelectedHook.call<bool>(
        collection, viewModel);
}

void RestoreSelectedRollBonusList(std::uintptr_t activeRoll,
    std::uintptr_t vmRoll, std::string_view stage) noexcept
{
    PerfScope perf(PerfMetric::RestoreSelected);
    try {
        bool const tracing = TraceEnabled();
        if (g_gameModule == nullptr || g_build == nullptr
            || activeRoll == 0 || vmRoll == 0) {
            return;
        }

        ClientPresentationLeaseSnapshot lease;
        std::array<std::uintptr_t,
            kMaximumRetainedRollBonusViewModels> retained{};
        std::size_t retainedCount{};
        {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            auto const indexed =
                g_clientPresentationLeaseByVmRoll.find(vmRoll);
            auto const found = indexed
                == g_clientPresentationLeaseByVmRoll.end()
                ? g_clientPresentationLeases.end()
                : g_clientPresentationLeases.find(indexed->second);
            if (found != g_clientPresentationLeases.end()) {
                auto const& current = found->second;
                lease = ClientPresentationLeaseSnapshot{
                    .selection = current.selection,
                    .frozenAdvantage = current.frozenAdvantage,
                    .presentationFrozen =
                        current.presentationFrozen,
                    .retainedRollBonusViewModelCount =
                        current.retainedRollBonusViewModelCount,
                };
                retained = current.retainedRollBonusViewModels;
                retainedCount =
                    current.retainedRollBonusViewModelCount;
            }
        }
        if (retainedCount == 0) {
            return;
        }

        auto* collection = At<void>(
            reinterpret_cast<void*>(activeRoll),
            kActiveRollDynamicModifierCollectionOffset);
        auto existing = SnapshotClientModifierCollection(
            collection, g_build->clientModifierCollectionGetRva);
        auto const entriesBefore = existing.size();
        auto const base =
            reinterpret_cast<std::uintptr_t>(g_gameModule);
        auto const add = reinterpret_cast<ClientModifierCollectionAddProc>(
            base + g_build->clientModifierCollectionAddRva);

        std::size_t eligible{};
        std::size_t alreadyPresent{};
        std::size_t restored{};
        std::size_t failed{};
        std::vector<std::string> details;
        for (std::size_t index = 0; index < retainedCount; ++index) {
            auto const viewModel = retained[index];
            std::uintptr_t diceTypeSet{};
            DynamicModifierIdentity identity{};
            std::uint8_t diceSize{};
            std::uint8_t diceCount{};
            std::uint8_t visible{};
            if (!ReadSelectedRollBonusViewModel(viewModel,
                    diceTypeSet, identity, diceSize, diceCount, visible)
                || diceCount == 0) {
                continue;
            }
            ++eligible;
            if (std::find(existing.begin(), existing.end(), viewModel)
                != existing.end()) {
                ++alreadyPresent;
                if (tracing) {
                    details.push_back(
                        "present:" + Hex(viewModel)
                        + ":d" + std::to_string(diceSize) + "x"
                        + std::to_string(diceCount));
                }
                continue;
            }

            add(collection, reinterpret_cast<void*>(viewModel));
            if (ClientModifierCollectionContains(collection,
                    g_build->clientModifierCollectionGetRva, viewModel)) {
                existing.push_back(viewModel);
                ++restored;
                if (tracing) {
                    details.push_back(
                        "restored:" + Hex(viewModel)
                        + ":d" + std::to_string(diceSize) + "x"
                        + std::to_string(diceCount));
                }
            } else {
                ++failed;
                if (tracing) {
                    details.push_back(
                        "failed:" + Hex(viewModel)
                        + ":d" + std::to_string(diceSize) + "x"
                        + std::to_string(diceCount));
                }
            }
        }

        if (!tracing) {
            return;
        }
        std::ostringstream detailStream;
        for (std::size_t index = 0; index < details.size(); ++index) {
            if (index != 0) {
                detailStream << ',';
            }
            detailStream << details[index];
        }
        auto const& record = lease.selection->record;
        Log("TRACE", "native_client_roll_selected_bonus_restored",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|stage=" + std::string(stage)
            + "|retained_count=" + std::to_string(retainedCount)
            + "|eligible_count=" + std::to_string(eligible)
            + "|already_present_count="
            + std::to_string(alreadyPresent)
            + "|restored_count=" + std::to_string(restored)
            + "|failed_count=" + std::to_string(failed)
            + "|entries_before=" + std::to_string(entriesBefore)
            + "|entries_after="
            + std::to_string(SnapshotClientModifierCollection(
                collection, g_build->clientModifierCollectionGetRva).size())
            + "|details="
            + (details.empty() ? "none" : detailStream.str())
            + "|selected_wrapper_identity_preserved=1"
            + "|request_already_dispatched=1"
            + "|authoritative_result_unchanged=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Restoring the selected UI wrapper is presentation-only and must
        // never interfere with BG3's already-dispatched roll.
    }
}

bool ReadRollBonusViewModelDice(std::uintptr_t viewModel,
    std::uint8_t& diceSize, std::uint8_t& diceCount,
    std::uint8_t& disabled, std::uint8_t& state) noexcept
{
    void* diceTypeSet{};
    return viewModel != 0
        && Read(At<void*>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDiceTypeSetOffset), diceTypeSet)
        && diceTypeSet != nullptr
        && Read(At<std::uint8_t>(diceTypeSet,
            kDynamicModifierDescriptorDiceSizeOffset), diceSize)
        && Read(At<std::uint8_t>(diceTypeSet,
            kDynamicModifierDescriptorDiceCountOffset), diceCount)
        && Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDisabledOffset), disabled)
        && Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmStateOffset), state);
}

void CaptureSelectedRollBonusViewModels(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::uint32_t rollState,
    boh::ProfileSelection const& selection) noexcept
{
    PerfScope perf(PerfMetric::CaptureSelected);
    try {
        bool const tracing = TraceEnabled();
        if (g_build == nullptr || activeRoll == 0 || vmRoll == 0
            || (rollState != 1 && rollState != 2)) {
            return;
        }
        // DCActiveRoll+0B98h is SelectedBoostModifierList: the flat list of
        // exact boost-action viewmodels selected in the roll UI. Roll.Modifiers
        // at VMRoll+178h is a different, result-facing collection. Capturing
        // from the latter loses a just-selected boost before reconciliation.
        auto* collection = At<void>(
            reinterpret_cast<void*>(activeRoll),
            kActiveRollDynamicModifierCollectionOffset);
        auto const entries = SnapshotClientModifierCollection(
            collection, g_build->clientModifierCollectionGetRva);
        std::size_t eligible{};
        std::size_t retained{};
        std::size_t cached{};
        std::vector<std::string> retainedDetails;
        {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            auto const indexed =
                g_clientPresentationLeaseByVmRoll.find(vmRoll);
            auto const found = indexed
                == g_clientPresentationLeaseByVmRoll.end()
                ? g_clientPresentationLeases.end()
                : g_clientPresentationLeases.find(indexed->second);
            if (found != g_clientPresentationLeases.end()) {
                // Each click gets a fresh snapshot. Keeping a previous
                // click's wrapper would make a spent or deselected boost
                // eligible for a later result.
                QueueClientViewModelReleases(found->second);
            }
        }
        for (auto const viewModel : entries) {
            std::uintptr_t diceTypeSet{};
            std::uintptr_t sourceVm{};
            DynamicModifierIdentity identity{};
            std::uint8_t diceSize{};
            std::uint8_t diceCount{};
            std::uint8_t visible{};
            if (!ReadSelectedRollBonusViewModel(viewModel,
                    diceTypeSet, identity, diceSize, diceCount, visible)
                || !ReadSelectedRollBonusSourceVm(viewModel, sourceVm)
                || sourceVm == 0 || diceCount == 0) {
                continue;
            }
            ++eligible;

            bool added{};
            {
                std::scoped_lock lock(g_clientPresentationLeaseMutex);
                auto const indexed =
                    g_clientPresentationLeaseByVmRoll.find(vmRoll);
                auto const found = indexed
                    == g_clientPresentationLeaseByVmRoll.end()
                    ? g_clientPresentationLeases.end()
                    : g_clientPresentationLeases.find(indexed->second);
                if (found != g_clientPresentationLeases.end()) {
                    auto& lease = found->second;
                    auto const begin =
                        lease.retainedRollBonusViewModels.begin();
                    auto const end = begin
                        + lease.retainedRollBonusViewModelCount;
                    if (std::find(begin, end, viewModel) != end
                        || lease.retainedRollBonusViewModelCount
                            >= kMaximumRetainedRollBonusViewModels) {
                        break;
                    }
                    if (RetainClientViewModel(viewModel)) {
                        lease.retainedRollBonusViewModels[
                            lease.retainedRollBonusViewModelCount++]
                            = viewModel;
                        lease.lastUsedTick = GetTickCount64();
                        added = true;
                    } else {
                        added = false;
                    }
                }
            }
            if (added) {
                ++retained;
                if (RememberCachedRollBonusPresentation(
                        selection, viewModel, identity,
                        diceSize, diceCount)) {
                    ++cached;
                }
                if (tracing) {
                    retainedDetails.push_back(
                        Hex(viewModel)
                        + ":source_vm=" + Hex(sourceVm)
                        + ":dice_type_set=" + Hex(diceTypeSet) + ":d"
                        + std::to_string(diceSize) + "x"
                        + std::to_string(diceCount)
                        + ":visible=" + std::to_string(visible)
                        + ":identity=" + Hex(identity.guid[0])
                        + "/" + Hex(identity.guid[1])
                        + "/" + std::to_string(identity.type));
                }
            }
        }

        if (!tracing) {
            return;
        }
        auto const lease = FindClientPresentationLeaseByVmRoll(vmRoll);
        if (!lease.has_value()) {
            return;
        }
        std::ostringstream details;
        for (std::size_t index = 0;
             index < retainedDetails.size(); ++index) {
            if (index != 0) {
                details << ',';
            }
            details << retainedDetails[index];
        }
        auto const& record = lease->selection->record;
        Log("TRACE", "native_client_roll_bonus_viewmodels_retained",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|collection_entries=" + std::to_string(entries.size())
            + "|eligible_dice_viewmodels=" + std::to_string(eligible)
            + "|newly_retained=" + std::to_string(retained)
            + "|newly_cached=" + std::to_string(cached)
            + "|retained_total="
            + std::to_string(
                lease->retainedRollBonusViewModelCount)
            + "|retained_details="
            + (retainedDetails.empty() ? "none" : details.str())
            + "|selected_collection=" + Hex(
                activeRoll + kActiveRollDynamicModifierCollectionOffset)
            + "|retention_source=selected_boost_modifier_list"
            + "|selected_layout=source_vm_at_48_dice_at_e0_identity_at_110"
            + "|vmroll_modifier_collection_untouched=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Retention is client presentation only and must fail open.
    }
}

void ArmSelectedRollBonusPresentationAfterPayload(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::uint32_t rollState) noexcept
{
    PerfScope perf(PerfMetric::ArmSelected);
    try {
        bool const tracing = TraceEnabled();
        if (g_gameModule == nullptr || g_build == nullptr
            || activeRoll == 0 || vmRoll == 0
            || (rollState != 1 && rollState != 2)) {
            return;
        }

        ClientPresentationLeaseSnapshot lease;
        std::array<std::uintptr_t,
            kMaximumRetainedRollBonusViewModels> retained{};
        std::size_t retainedCount{};
        {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            auto const indexed =
                g_clientPresentationLeaseByVmRoll.find(vmRoll);
            auto const found = indexed
                == g_clientPresentationLeaseByVmRoll.end()
                ? g_clientPresentationLeases.end()
                : g_clientPresentationLeases.find(indexed->second);
            if (found != g_clientPresentationLeases.end()) {
                auto const& current = found->second;
                lease = ClientPresentationLeaseSnapshot{
                    .selection = current.selection,
                    .frozenAdvantage = current.frozenAdvantage,
                    .presentationFrozen =
                        current.presentationFrozen,
                    .retainedRollBonusViewModelCount =
                        current.retainedRollBonusViewModelCount,
                };
                retained = current.retainedRollBonusViewModels;
                retainedCount =
                    current.retainedRollBonusViewModelCount;
            }
        }
        if (retainedCount == 0) {
            return;
        }

        auto* selectedCollection = At<void>(
            reinterpret_cast<void*>(activeRoll),
            kActiveRollDynamicModifierCollectionOffset);
        auto const selectedEntries = SnapshotClientModifierCollection(
            selectedCollection, g_build->clientModifierCollectionGetRva);
        std::size_t eligible{};
        std::size_t present{};
        std::vector<std::string> details;

        for (std::size_t index = 0; index < retainedCount; ++index) {
            auto const selected = retained[index];
            std::uintptr_t diceTypeSet{};
            std::uintptr_t sourceVm{};
            DynamicModifierIdentity identity{};
            std::uint8_t diceSize{};
            std::uint8_t diceCount{};
            std::uint8_t visible{};
            if (!ReadSelectedRollBonusViewModel(selected,
                    diceTypeSet, identity, diceSize, diceCount, visible)
                || !ReadSelectedRollBonusSourceVm(selected, sourceVm)
                || sourceVm == 0 || diceCount == 0) {
                continue;
            }
            ++eligible;
            bool const isPresent = std::find(
                selectedEntries.begin(), selectedEntries.end(), selected)
                != selectedEntries.end();
            if (isPresent) {
                ++present;
            }
            if (tracing) {
                details.push_back(
                    std::string(isPresent ? "retained:" : "missing:")
                    + Hex(selected)
                    + ":d" + std::to_string(diceSize) + "x"
                    + std::to_string(diceCount));
            }
        }

        bool removalGuardArmed{};
        if (eligible != 0 && eligible == retainedCount
            && present == eligible) {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            auto const indexed =
                g_clientPresentationLeaseByVmRoll.find(vmRoll);
            auto const found = indexed
                == g_clientPresentationLeaseByVmRoll.end()
                ? g_clientPresentationLeases.end()
                : g_clientPresentationLeases.find(indexed->second);
            if (found != g_clientPresentationLeases.end()) {
                found->second.selectedRemovalGuardArmed = true;
                removalGuardArmed = true;
            }
        }

        if (!tracing) {
            return;
        }
        std::ostringstream detailStream;
        for (std::size_t index = 0; index < details.size(); ++index) {
            if (index != 0) {
                detailStream << ',';
            }
            detailStream << details[index];
        }
        auto const& record = lease.selection->record;
        Log("TRACE", "native_client_roll_bonus_direct_handoff_armed",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|retained_count=" + std::to_string(retainedCount)
            + "|eligible_count=" + std::to_string(eligible)
            + "|selected_present_count=" + std::to_string(present)
            + "|details="
            + (details.empty() ? "none" : detailStream.str())
            + "|direct_handoff_ready="
            + std::to_string(
                eligible != 0 && eligible == retainedCount
                    && present == eligible ? 1 : 0)
            + "|selected_removal_guard_armed="
            + std::to_string(removalGuardArmed ? 1 : 0)
            + "|binding_timing=after_request_payload_before_dispatch"
            + "|pre_roll_synthetic_rows=0"
            + "|selected_wrapper_identity_preserved=1"
            + "|request_payload_unchanged=1"
            + "|authoritative_result_unchanged=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Preparation is local presentation only and must fail open.
    }
}

SelectedRollBonusBindingResult BindSelectedRollBonusPresentation(
    std::uintptr_t activeRoll, std::uintptr_t vmRoll,
    std::span<ResolvedBonusObservation const> bonuses) noexcept
{
    PerfScope perf(PerfMetric::BindPresentation);
    SelectedRollBonusBindingResult result;
    try {
        if (g_gameModule == nullptr || g_build == nullptr
            || activeRoll == 0 || vmRoll == 0 || bonuses.empty()) {
            return result;
        }

        ClientPresentationLeaseSnapshot lease;
        std::array<std::uintptr_t,
            kMaximumRetainedRollBonusViewModels> retained{};
        std::size_t retainedCount{};
        {
            std::scoped_lock lock(g_clientPresentationLeaseMutex);
            auto const indexed =
                g_clientPresentationLeaseByVmRoll.find(vmRoll);
            auto const found = indexed
                == g_clientPresentationLeaseByVmRoll.end()
                ? g_clientPresentationLeases.end()
                : g_clientPresentationLeases.find(indexed->second);
            if (found != g_clientPresentationLeases.end()) {
                auto& current = found->second;
                lease = ClientPresentationLeaseSnapshot{
                    .selection = current.selection,
                    .frozenAdvantage = current.frozenAdvantage,
                    .presentationFrozen =
                        current.presentationFrozen,
                    .retainedRollBonusViewModelCount =
                        current.retainedRollBonusViewModelCount,
                };
                retained = current.retainedRollBonusViewModels;
                retainedCount = current.retainedRollBonusViewModelCount;
                current.retainedRollBonusViewModels = {};
                current.retainedRollBonusViewModelCount = 0;
                current.selectedRemovalGuardArmed = false;
            }
        }
        result.retained = retainedCount;
        if (lease.selection == nullptr) {
            return result;
        }
        auto const cached = retainedCount == 0
            ? FindCachedRollBonusPresentations(*lease.selection)
            : CachedRollBonusPresentationSnapshot{};
        result.cached = cached.size();
        if (retainedCount == 0 && cached.empty()) {
            return result;
        }

        struct PresentationCandidate {
            std::uintptr_t selectedViewModel{};
            DynamicModifierIdentity identity{};
            std::uint8_t diceSize{};
            std::uint8_t diceCount{};
            bool cached{};
        };
        FixedSnapshot<PresentationCandidate,
            kMaximumRetainedRollBonusViewModels
                + kMaximumCachedRollBonusPresentations> candidates;
        for (std::size_t reverse = retainedCount; reverse > 0; --reverse) {
            std::uintptr_t diceTypeSet{};
            DynamicModifierIdentity identity{};
            std::uint8_t diceSize{};
            std::uint8_t diceCount{};
            std::uint8_t visible{};
            auto const selected = retained[reverse - 1];
            if (ReadSelectedRollBonusViewModel(selected, diceTypeSet,
                    identity, diceSize, diceCount, visible)
                && diceCount != 0) {
                candidates.push_back(PresentationCandidate{
                    .selectedViewModel = selected,
                    .identity = identity,
                    .diceSize = diceSize,
                    .diceCount = diceCount,
                    .cached = false,
                });
            }
        }
        for (auto const& entry : cached) {
            candidates.push_back(PresentationCandidate{
                .selectedViewModel = entry.selectedViewModel,
                .identity = DynamicModifierIdentity{
                    .guid = entry.identityGuid,
                    .type = entry.identityType,
                },
                .diceSize = entry.diceSize,
                .diceCount = entry.diceCount,
                .cached = true,
            });
        }

        std::array<bool, kMaximumResolvedRollBonuses> consumed{};
        auto* vmCollection = At<void>(
            reinterpret_cast<void*>(vmRoll),
            kVmRollDynamicModifierCollectionOffset);
        auto* selectedCollection = At<void>(
            reinterpret_cast<void*>(activeRoll),
            kActiveRollDynamicModifierCollectionOffset);
        auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
        auto const addVm = reinterpret_cast<ClientModifierCollectionAddProc>(
            base + g_build->clientVmRollModifierCollectionAddRva);
        auto const removeSelected =
            reinterpret_cast<ClientModifierCollectionRemoveProc>(
                base + g_build->clientModifierCollectionRemoveRva);
        auto const existing = SnapshotClientModifierCollection(
            vmCollection, g_build->clientVmRollModifierCollectionGetRva);
        auto const selectedEntries = SnapshotClientModifierCollection(
            selectedCollection,
            g_build->clientModifierCollectionGetRva);
        std::array<bool,
            kMaximumObservedDynamicModifierViewModels> existingConsumed{};
        bool const tracing = TraceEnabled();
        std::vector<std::string> bindingDetails;

        for (auto const& candidate : candidates) {
            std::uintptr_t selectedDiceTypeSet{};
            DynamicModifierIdentity observedIdentity{};
            std::uint8_t observedDiceSize{};
            std::uint8_t observedDiceCount{};
            std::uint8_t visible{};
            std::uintptr_t selectedSourceVm{};
            if (!ReadSelectedRollBonusViewModel(
                    candidate.selectedViewModel, selectedDiceTypeSet,
                    observedIdentity, observedDiceSize,
                    observedDiceCount, visible)
                || !ReadSelectedRollBonusSourceVm(
                    candidate.selectedViewModel, selectedSourceVm)
                || observedDiceSize != candidate.diceSize
                || observedDiceCount != candidate.diceCount) {
                continue;
            }
            if (selectedSourceVm != 0) {
                ++result.sourceVms;
            }

            std::optional<std::size_t> bonusMatch;
            std::size_t sameShapeBonusCount{};
            for (std::size_t index = 0;
                 index < bonuses.size() && index < consumed.size(); ++index) {
                if (bonuses[index].diceSize == candidate.diceSize
                    && bonuses[index].diceCount == candidate.diceCount
                    && bonuses[index].value > 0) {
                    ++sameShapeBonusCount;
                    if (!consumed[index] && !bonusMatch.has_value()) {
                        bonusMatch = index;
                    }
                }
            }
            if (!bonusMatch.has_value()
                || (candidate.cached && sameShapeBonusCount != 1)) {
                if (tracing) {
                    bindingDetails.push_back(
                        "skipped:" + Hex(candidate.selectedViewModel)
                        + ":source="
                        + (candidate.cached ? "cache" : "selected")
                        + ":same_shape_bonuses="
                        + std::to_string(sameShapeBonusCount));
                }
                continue;
            }

            // The selected VMBoostModifier is already the exact object that
            // BG3 animates for an in-roll-UI bonus. Once the result publishes
            // its authoritative dice value, write that value directly to the
            // object BG3's own animation callback reads. No result-facing
            // VMRollModifier is needed before the roll, so there is no blank
            // placeholder row for XAML to render while the request is in
            // flight.
            if (!candidate.cached) {
                bool const selectedPresent = std::find(
                    selectedEntries.begin(), selectedEntries.end(),
                    candidate.selectedViewModel)
                    != selectedEntries.end();
                bool const selectedValueTransferred = selectedPresent
                    && SetSelectedRollBonusResolvedValue(
                        candidate.selectedViewModel,
                        bonuses[*bonusMatch].value);
                if (selectedValueTransferred) {
                    consumed[*bonusMatch] = true;
                    ++result.matched;
                    ++result.selectedAuthoritative;
                    ++result.directTargets;
                    if (selectedSourceVm != 0) {
                        ++result.sourceVmsAlreadyBound;
                    }
                    if (tracing) {
                        bindingDetails.push_back(
                            "selected_authoritative_direct:"
                            + Hex(candidate.selectedViewModel)
                            + ":dice_type_set=" + Hex(selectedDiceTypeSet)
                            + ":source_vm=" + Hex(selectedSourceVm)
                            + ":resolved_value="
                            + std::to_string(bonuses[*bonusMatch].value)
                            + ":pre_roll_synthetic_rows=0"
                            + ":single_visible_path=1");
                    }
                    continue;
                }

                // If the direct handoff cannot be proved, remove the selected
                // wrapper before falling back to a result-facing row. That
                // preserves exactly-once numeric contribution even when
                // presentation must degrade.
                ++result.selectedFallbacks;
                removeSelected(selectedCollection,
                    reinterpret_cast<void*>(
                        candidate.selectedViewModel));
                if (tracing) {
                    bindingDetails.push_back(
                        "selected_direct_fallback:"
                        + Hex(candidate.selectedViewModel)
                        + ":selected_present="
                        + std::to_string(selectedPresent ? 1 : 0));
                }
            }

            std::optional<std::size_t> fallbackTarget;
            std::optional<std::size_t> identityTarget;
            std::size_t sameShapeVmCount{};
            for (std::size_t index = 0; index < existing.size(); ++index) {
                if (existingConsumed[index]) {
                    continue;
                }
                std::uint8_t candidateDiceSize{};
                std::uint8_t candidateDiceCount{};
                std::uint8_t candidateDisabled{};
                std::uint8_t candidateState{};
                if (!ReadRollBonusViewModelDice(existing[index],
                        candidateDiceSize, candidateDiceCount,
                        candidateDisabled, candidateState)
                    || candidateDiceSize != candidate.diceSize
                    || candidateDiceCount != candidate.diceCount) {
                    continue;
                }
                ++sameShapeVmCount;
                if (!fallbackTarget.has_value()) {
                    fallbackTarget = index;
                }
                std::array<std::uint64_t, 2> existingGuid{};
                if ((candidate.identity.guid[0] != 0
                        || candidate.identity.guid[1] != 0)
                    && Read(At<std::array<std::uint64_t, 2>>(
                            reinterpret_cast<void*>(existing[index]),
                            kDynamicModifierVmGuidOffset), existingGuid)
                    && existingGuid == candidate.identity.guid) {
                    identityTarget = index;
                    break;
                }
            }

            auto const targetIndex = identityTarget.has_value()
                ? identityTarget : fallbackTarget;
            // A cache entry comes from a previous roll. It may repair one
            // unambiguous status-derived wrapper, but it may never synthesize
            // a new entry or choose among multiple same-shaped modifiers.
            if (candidate.cached
                && (!targetIndex.has_value() || sameShapeVmCount != 1)) {
                if (tracing) {
                    bindingDetails.push_back(
                        "cache_ambiguous:" + Hex(candidate.selectedViewModel)
                        + ":same_shape_viewmodels="
                        + std::to_string(sameShapeVmCount));
                }
                continue;
            }
            if (targetIndex.has_value()) {
                auto const target = existing[*targetIndex];
                std::uintptr_t existingDiceTypeSet{};
                Read(At<std::uintptr_t>(
                        reinterpret_cast<void*>(target),
                        kDynamicModifierVmDiceTypeSetOffset),
                    existingDiceTypeSet);
                std::uintptr_t existingSourceVm{};
                Read(At<std::uintptr_t>(
                        reinterpret_cast<void*>(target),
                        kDynamicModifierVmSourceVmOffset),
                    existingSourceVm);
                bool const alreadyBound =
                    existingDiceTypeSet == selectedDiceTypeSet;
                bool const diceTypeSetBound = alreadyBound
                    || SetDynamicModifierDiceTypeSet(
                        target, selectedDiceTypeSet);
                bool const typed =
                    SetDynamicModifierRollBonusPresentationType(target);
                bool const sourceVmAlreadyBound =
                    selectedSourceVm != 0
                    && existingSourceVm == selectedSourceVm;
                bool const sourceVmTransferred = sourceVmAlreadyBound
                    || (selectedSourceVm != 0
                        && SetDynamicModifierSourceVm(
                            target, selectedSourceVm));
                bool const nameTransferred =
                    SetDynamicModifierNameFromPresentation(
                        target, candidate.selectedViewModel,
                        selectedSourceVm);
                bool const valueTransferred =
                    SetDynamicModifierResolvedValue(
                        target, bonuses[*bonusMatch].value);
                if (diceTypeSetBound && typed && sourceVmTransferred
                    && nameTransferred && valueTransferred) {
                    existingConsumed[*targetIndex] = true;
                    consumed[*bonusMatch] = true;
                    ++result.matched;
                    ++result.typed;
                    if (alreadyBound) {
                        ++result.alreadyBound;
                    } else {
                        ++result.rebound;
                    }
                    if (sourceVmAlreadyBound) {
                        ++result.sourceVmsAlreadyBound;
                    } else if (sourceVmTransferred) {
                        ++result.sourceVmsTransferred;
                    }
                    if (!candidate.cached) {
                        ++result.directTargets;
                    }
                    if (tracing) {
                        bindingDetails.push_back(
                            std::string(
                                alreadyBound ? "already:" : "rebound:")
                            + Hex(target)
                            + ":from=" + Hex(candidate.selectedViewModel)
                            + ":dice_type_set=" + Hex(selectedDiceTypeSet)
                            + ":source="
                            + (candidate.cached ? "cache" : "selected")
                            + ":identity_match="
                            + std::to_string(
                                identityTarget.has_value() ? 1 : 0)
                            + ":type=2:category=2"
                            + ":source_vm=" + Hex(selectedSourceVm)
                            + ":source_vm_before=" + Hex(existingSourceVm)
                            + ":source_vm_transferred="
                            + std::to_string(sourceVmTransferred ? 1 : 0)
                            + ":resolved_value="
                            + std::to_string(bonuses[*bonusMatch].value)
                            + ":resolved_value_transferred=1");
                    }
                }
                continue;
            }

            bool typed{};
            bool sourceVmTransferred{};
            bool nameTransferred{};
            bool valueTransferred{};
            auto const created = CreateVmRollModifierViewModel(
                selectedDiceTypeSet, candidate.identity,
                candidate.selectedViewModel, selectedSourceVm,
                bonuses[*bonusMatch].value, typed,
                sourceVmTransferred, nameTransferred,
                valueTransferred);
            if (created == 0) {
                if (tracing) {
                    bindingDetails.push_back(
                        "factory_failed:" + Hex(candidate.selectedViewModel)
                        + ":source_vm=" + Hex(selectedSourceVm)
                        + ":typed=" + std::to_string(typed ? 1 : 0)
                        + ":source_vm_transferred="
                        + std::to_string(sourceVmTransferred ? 1 : 0)
                        + ":name_from_presentation="
                        + std::to_string(nameTransferred ? 1 : 0)
                        + ":resolved_value="
                        + std::to_string(bonuses[*bonusMatch].value)
                        + ":resolved_value_transferred="
                        + std::to_string(valueTransferred ? 1 : 0));
                }
                continue;
            }
            addVm(vmCollection, reinterpret_cast<void*>(created));
            bool const presentAfter = ClientModifierCollectionContains(
                vmCollection, g_build->clientVmRollModifierCollectionGetRva,
                created);
            ReleaseClientIntrusiveObject(created);
            if (presentAfter) {
                consumed[*bonusMatch] = true;
                ++result.matched;
                ++result.inserted;
                ++result.typed;
                if (sourceVmTransferred) {
                    ++result.sourceVmsTransferred;
                }
                if (tracing) {
                    bindingDetails.push_back(
                        "created:" + Hex(created)
                        + ":from=" + Hex(candidate.selectedViewModel)
                        + ":dice_type_set=" + Hex(selectedDiceTypeSet)
                        + ":identity=" + Hex(candidate.identity.guid[0])
                        + "/" + Hex(candidate.identity.guid[1])
                        + "/" + std::to_string(candidate.identity.type)
                        + ":type=2:category=2"
                        + ":source_vm=" + Hex(selectedSourceVm)
                        + ":source_vm_transferred="
                        + std::to_string(sourceVmTransferred ? 1 : 0)
                        + ":name_from_presentation="
                        + std::to_string(nameTransferred ? 1 : 0)
                        + ":resolved_value="
                        + std::to_string(bonuses[*bonusMatch].value)
                        + ":resolved_value_transferred="
                        + std::to_string(valueTransferred ? 1 : 0));
                }
            }
        }

        for (std::size_t index = 0; index < retainedCount; ++index) {
            ReleaseClientViewModel(retained[index]);
        }

        if (tracing) {
            std::ostringstream details;
            for (std::size_t index = 0; index < bindingDetails.size();
                 ++index) {
                if (index != 0) {
                    details << ',';
                }
                details << bindingDetails[index];
            }
        auto const& record = lease.selection->record;
            Log("TRACE", "native_client_roll_bonus_presentation_bound",
                "action=" + boh::ActionName(record.kind)
                + "|delegation_id=" + std::to_string(record.id)
                + "|roll_uuid=" + record.rollUuid
                + "|retained_count=" + std::to_string(retainedCount)
                + "|cached_candidate_count="
                + std::to_string(cached.size())
                + "|authoritative_dice_bonus_count="
                + std::to_string(bonuses.size())
                + "|matched_count=" + std::to_string(result.matched)
                + "|inserted_count=" + std::to_string(result.inserted)
                + "|rebound_count=" + std::to_string(result.rebound)
                + "|already_bound_count="
                + std::to_string(result.alreadyBound)
                + "|typed_count=" + std::to_string(result.typed)
                + "|source_vm_count="
                + std::to_string(result.sourceVms)
                + "|source_vm_transferred_count="
                + std::to_string(result.sourceVmsTransferred)
                + "|source_vm_already_bound_count="
                + std::to_string(result.sourceVmsAlreadyBound)
                + "|vmroll_entries_before="
                + std::to_string(existing.size())
                + "|binding_details="
                + (bindingDetails.empty() ? "none" : details.str())
                + "|binding_target=selected_wrapper_or_vmroll_fallback"
                + "|binding_timing=authoritative_resolution"
                + "|direct_selected_targets="
                + std::to_string(result.directTargets)
                + "|selected_authoritative_count="
                + std::to_string(result.selectedAuthoritative)
                + "|pre_roll_synthetic_rows=0"
                + "|selected_path_fallbacks="
                + std::to_string(result.selectedFallbacks)
                + "|selected_wrapper_inserted=0"
                + "|vmroll_wrapper_factory=native"
                + "|selected_collection_writes=continuity_or_safe_fallback"
                + "|single_numeric_presentation_path="
                + std::to_string(
                    result.selectedAuthoritative != 0 ? 1 : 0)
                + "|dice_type_set_property_setter=native_noesis"
                + "|source_vm_property_setter=native_noesis"
                + "|name_binding_strategy=typed_noesis_reflection"
                + "|presentation_type=roll_bonus"
                + "|authoritative_result_unchanged=1"
                + "|component_owner_unchanged=1"
                + "|thread_id=" + std::to_string(GetCurrentThreadId())
                + "|tick_ms=" + std::to_string(GetTickCount64()));
        }
        return result;
    } catch (...) {
        // Binding is client presentation only and must fail open.
        return result;
    }
}

void ClientRollBonusReconcileStartMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::ReconcileStart);
    try {
        DrainDeferredClientViewModelReleases();
        g_rollBonusReconciliationObservation = {};

        auto const activeRoll = reinterpret_cast<void*>(context.rdi);
        auto const result = reinterpret_cast<void*>(context.rbx);
        auto const modifiers = reinterpret_cast<void*>(context.rax);
        void* vmRoll{};
        if (activeRoll == nullptr || result == nullptr || modifiers == nullptr
            || !Read(At<void*>(activeRoll, kActiveRollVmRollOffset), vmRoll)
            || vmRoll == nullptr) {
            return;
        }
        auto const lease = FindClientPresentationLeaseByVmRoll(
            reinterpret_cast<std::uintptr_t>(vmRoll));

        void* bonuses{};
        std::int32_t capacity{};
        std::int32_t count{};
        if (!Read(At<void*>(result, kRollResultResolvedBonusesOffset),
                bonuses)
            || !Read(At<std::int32_t>(
                    result, kRollResultResolvedBonusCapacityOffset),
                capacity)
            || !Read(At<std::int32_t>(
                    result, kRollResultResolvedBonusCountOffset),
                count)
            || count <= 0
            || count > static_cast<std::int32_t>(
                kMaximumResolvedRollBonuses)
            || capacity < count || capacity > 4096
            || !IsReadable(bonuses,
                static_cast<std::size_t>(count)
                    * kResolvedRollBonusSize)) {
            return;
        }

        RollBonusReconciliationObservation observation{
            .active = true,
            .delegated = lease.has_value(),
            .activeRoll = context.rdi,
            .resultPayload = context.rbx,
            .modifiersComponent = context.rax,
            .vmRoll = reinterpret_cast<std::uintptr_t>(vmRoll),
        };
        if (lease.has_value() && TraceEnabled()) {
            observation.selection = *lease->selection;
        }
        auto const bytes = static_cast<std::byte*>(bonuses);
        for (std::int32_t index = 0; index < count; ++index) {
            auto const bonus = bytes
                + static_cast<std::size_t>(index)
                    * kResolvedRollBonusSize;
            ResolvedBonusObservation resolved{};
            if (!Read(bonus + kResolvedRollBonusDiceSizeOffset,
                    resolved.diceSize)
                || !Read(bonus + kResolvedRollBonusDiceCountOffset,
                    resolved.diceCount)
                || !Read(bonus + kResolvedRollBonusValueOffset,
                    resolved.value)
                || resolved.diceCount == 0) {
                continue;
            }
            observation.bonuses[observation.bonusCount++] = resolved;
        }
        if (observation.bonusCount == 0) {
            return;
        }
        SelectedRollBonusBindingResult binding;
        if (observation.delegated) {
            // Retargeting a roll-UI bonus to the specialist can make BG3
            // clear the initiator-facing SelectedBoostModifierList even
            // though vanilla keeps that wrapper beside its result-facing
            // Roll.Modifiers entry. Reassert the exact retained wrapper
            // before AnimSeqSelected snapshots the selected list.
            RestoreSelectedRollBonusList(
                observation.activeRoll, observation.vmRoll,
                "pre_reconcile");
            binding = BindSelectedRollBonusPresentation(
                observation.activeRoll,
                observation.vmRoll,
                std::span<ResolvedBonusObservation const>(
                    observation.bonuses.data(),
                    observation.bonusCount));
        }
        g_rollBonusReconciliationObservation = observation;

        if (TraceEnabled()) {
            auto const& record = observation.selection.record;
            auto const profileMode = observation.delegated
                ? "delegated" : "vanilla_reference";
            Log("TRACE", observation.delegated
                    ? "native_client_roll_bonus_reconcile_started"
                    : "native_client_roll_bonus_reference_reconcile_started",
                "action=" + (observation.delegated
                    ? boh::ActionName(record.kind)
                    : std::string("reference"))
                + "|delegation_id=" + (observation.delegated
                    ? std::to_string(record.id) : std::string("none"))
                + "|roll_uuid=" + (observation.delegated
                    ? record.rollUuid : std::string("unmapped"))
                + "|profile_mode=" + profileMode
                + "|resolved_bonus_count="
                + std::to_string(observation.bonusCount)
                + "|selected_boosts_retained="
                + std::to_string(binding.retained)
                + "|selected_boosts_cached="
                + std::to_string(binding.cached)
                + "|selected_boosts_matched="
                + std::to_string(binding.matched)
                + "|selected_boosts_inserted="
                + std::to_string(binding.inserted)
                + "|selected_boosts_rebound="
                + std::to_string(binding.rebound)
                + "|selected_boosts_already_bound="
                + std::to_string(binding.alreadyBound)
                + "|selected_boosts_typed="
                + std::to_string(binding.typed)
                + "|selected_boost_source_vms="
                + std::to_string(binding.sourceVms)
                + "|selected_boost_source_vms_transferred="
                + std::to_string(binding.sourceVmsTransferred)
                + "|selected_boost_source_vms_already_bound="
                + std::to_string(binding.sourceVmsAlreadyBound)
                + "|selected_boost_direct_targets="
                + std::to_string(binding.directTargets)
                + "|active_roll=" + Hex(observation.activeRoll)
                + "|vm_roll=" + Hex(observation.vmRoll)
                + "|result_payload=" + Hex(observation.resultPayload)
                + "|modifiers_component="
                + Hex(observation.modifiersComponent)
                + "|component_owner_unchanged=1"
                + "|thread_id=" + std::to_string(GetCurrentThreadId())
                + "|tick_ms=" + std::to_string(GetTickCount64()));
        }
    } catch (...) {
        g_rollBonusReconciliationObservation = {};
        // Reconciliation repair must fail open to BG3's original refresh.
    }
}

void TraceAdvantageSourceModifierBinding(
    safetyhook::Context const& context) noexcept
{
    if (!TraceEnabled() || context.rax == 0 || context.rsp == 0) {
        return;
    }
    auto const viewModel = reinterpret_cast<void*>(context.rax);
    void* vmRoll{};
    std::uint8_t boostType{};
    std::uint8_t disabled{};
    std::uint8_t state{};
    std::uintptr_t sourceVm{};
    std::array<std::uint64_t, 2> identity{};
    std::array<std::byte, kDynamicModifierVmTraceBytes> raw{};
    if (!Read(reinterpret_cast<void const*>(
            context.rsp + kModifierRefreshVmRollStackOffset), vmRoll)
        || vmRoll == nullptr
        || !Read(At<std::uint8_t>(viewModel,
            kDynamicModifierVmBoostTypeOffset), boostType)
        || boostType != 3
        || !Read(At<std::uint8_t>(viewModel,
            kDynamicModifierVmDisabledOffset), disabled)
        || !Read(At<std::uint8_t>(viewModel,
            kDynamicModifierVmStateOffset), state)
        || !Read(At<std::uintptr_t>(viewModel,
            kDynamicModifierVmSourceVmOffset), sourceVm)
        || !Read(At<std::array<std::uint64_t, 2>>(viewModel,
            kDynamicModifierVmGuidOffset), identity)) {
        return;
    }
    bool const rawReadable = Read(viewModel, raw);
    auto const vmRollAddress = reinterpret_cast<std::uintptr_t>(vmRoll);
    auto const lease = FindClientPresentationLeaseByVmRoll(vmRollAddress);
    auto const key = 0xa600000000000000ULL
        ^ vmRollAddress ^ context.rax;
    std::uint64_t pass{};
    {
        std::scoped_lock lock(g_profileTraceMutex);
        pass = ++g_profilePasses[key];
    }
    if (pass > 4) {
        return;
    }

    Log("TRACE", "native_client_advantage_source_modifier_binding",
        "action=" + (lease.has_value()
            ? boh::ActionName(lease->selection->record.kind)
            : std::string("reference"))
        + "|delegation_id=" + (lease.has_value()
            ? std::to_string(lease->selection->record.id)
            : std::string("none"))
        + "|roll_uuid=" + (lease.has_value()
            ? lease->selection->record.rollUuid
            : std::string("unmapped"))
        + "|profile_mode=" + (lease.has_value()
            ? std::string("delegated")
            : std::string("vanilla_reference"))
        + "|pass=" + std::to_string(pass)
        + "|disabled=" + std::to_string(disabled)
        + "|state=" + std::to_string(state)
        + "|identity_lo=" + Hex(identity[0])
        + "|identity_hi=" + Hex(identity[1])
        + "|source_vm=" + Hex(sourceVm)
        + "|source_vm_present=" + std::to_string(sourceVm != 0 ? 1 : 0)
        + "|raw_vm="
        + (rawReadable ? HexBytes(raw) : std::string("unreadable"))
        + "|viewmodel=" + Hex(context.rax)
        + "|vm_roll=" + Hex(vmRollAddress)
        + "|observation_only=1"
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64()));
}

void ClientRollBonusReconcileViewModelMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::ReconcileViewModel);
    try {
        TraceAdvantageSourceModifierBinding(context);
        auto& observation = g_rollBonusReconciliationObservation;
        if (!observation.active
            || observation.viewModelCount
                >= observation.viewModels.size()
            || context.rax == 0) {
            return;
        }
        auto const viewModel = reinterpret_cast<void*>(context.rax);
        DynamicModifierViewModelObservation current{
            .viewModel = context.rax,
        };
        if (TraceEnabled()) {
            current.rawReadable = Read(viewModel, current.raw);
        }
        void* diceTypeSet{};
        if (!Read(At<std::array<std::uint64_t, 2>>(
                viewModel, kDynamicModifierVmGuidOffset), current.guid)
            || !Read(At<std::uint8_t>(
                viewModel, kDynamicModifierVmDisabledOffset),
                current.disabledBefore)
            || !Read(At<std::uint8_t>(
                viewModel, kDynamicModifierVmStateOffset),
                current.stateBefore)) {
            return;
        }
        if (Read(At<void*>(
                viewModel, kDynamicModifierVmDiceTypeSetOffset), diceTypeSet)
            && diceTypeSet != nullptr
            && Read(At<std::uint8_t>(
                    diceTypeSet,
                    kDynamicModifierDescriptorDiceSizeOffset),
                current.diceSize)
            && Read(At<std::uint8_t>(
                    diceTypeSet,
                    kDynamicModifierDescriptorDiceCountOffset),
                current.diceCount)) {
            current.descriptorReadable = true;
        }
        observation.viewModels[observation.viewModelCount++] = current;
    } catch (...) {
        // Observation only; BG3's collection traversal remains untouched.
    }
}

struct PreservedRollBonusViewModel {
    ClientPresentationLeaseSnapshot lease;
    std::uintptr_t vmRoll{};
    std::uintptr_t viewModel{};
    std::uint8_t diceSize{};
    std::uint8_t diceCount{};
    std::uint8_t state{};
};

std::optional<PreservedRollBonusViewModel>
MatchSelectedDelegatedRollBonus(std::uintptr_t stackPointer,
    std::uintptr_t viewModel) noexcept
{
    if (stackPointer == 0 || viewModel == 0) {
        return {};
    }
    void* vmRoll{};
    void* diceTypeSet{};
    std::uint8_t disabled{};
    std::uint8_t state{};
    std::uint8_t diceSize{};
    std::uint8_t diceCount{};
    if (!Read(reinterpret_cast<void const*>(
            stackPointer + kModifierRefreshVmRollStackOffset), vmRoll)
        || vmRoll == nullptr
        || !Read(At<void*>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDiceTypeSetOffset), diceTypeSet)
        || diceTypeSet == nullptr
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDisabledOffset), disabled)
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmStateOffset), state)
        || !Read(At<std::uint8_t>(diceTypeSet,
            kDynamicModifierDescriptorDiceSizeOffset), diceSize)
        || !Read(At<std::uint8_t>(diceTypeSet,
            kDynamicModifierDescriptorDiceCountOffset), diceCount)
        || disabled != 0 || state == 3 || diceCount == 0) {
        return {};
    }
    auto const lease = FindClientPresentationLeaseByVmRoll(
        reinterpret_cast<std::uintptr_t>(vmRoll));
    if (!lease.has_value()) {
        return {};
    }
    return PreservedRollBonusViewModel{
        .lease = *lease,
        .vmRoll = reinterpret_cast<std::uintptr_t>(vmRoll),
        .viewModel = viewModel,
        .diceSize = diceSize,
        .diceCount = diceCount,
        .state = state,
    };
}

void LogPreservedRollBonusViewModel(
    PreservedRollBonusViewModel const& preserved,
    std::string_view branch) noexcept
{
    if (!TraceEnabled()) {
        return;
    }
    auto const& record = preserved.lease.selection->record;
    Log("TRACE", "native_client_roll_bonus_disable_suppressed",
        "action=" + boh::ActionName(record.kind)
        + "|delegation_id=" + std::to_string(record.id)
        + "|roll_uuid=" + record.rollUuid
        + "|branch=" + std::string(branch)
        + "|dice_size=" + std::to_string(preserved.diceSize)
        + "|dice_count=" + std::to_string(preserved.diceCount)
        + "|state=" + std::to_string(preserved.state)
        + "|viewmodel=" + Hex(preserved.viewModel)
        + "|vm_roll=" + Hex(preserved.vmRoll)
        + "|authoritative_result_unchanged=1"
        + "|component_owner_unchanged=1"
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64()));
}

struct PreservedAdvantageSourceModifier {
    ClientPresentationLeaseSnapshot lease;
    std::uintptr_t vmRoll{};
    std::uintptr_t viewModel{};
    std::uintptr_t sourceViewModel{};
    std::uint8_t expectedAdvantage{};
    std::uint8_t state{};
};

std::optional<PreservedAdvantageSourceModifier>
MatchDelegatedAdvantageSourceModifier(std::uintptr_t stackPointer,
    std::uintptr_t viewModel) noexcept
{
    if (stackPointer == 0 || viewModel == 0) {
        return {};
    }
    void* vmRoll{};
    std::uint8_t boostType{};
    std::uint8_t disabled{};
    std::uint8_t state{};
    std::uintptr_t sourceViewModel{};
    if (!Read(reinterpret_cast<void const*>(
            stackPointer + kModifierRefreshVmRollStackOffset), vmRoll)
        || vmRoll == nullptr
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmBoostTypeOffset), boostType)
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmDisabledOffset), disabled)
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmStateOffset), state)
        || !Read(At<std::uintptr_t>(reinterpret_cast<void*>(viewModel),
            kDynamicModifierVmSourceVmOffset), sourceViewModel)) {
        return {};
    }
    auto const vmRollAddress = reinterpret_cast<std::uintptr_t>(vmRoll);
    auto const lease = FindClientPresentationLeaseByVmRoll(vmRollAddress);
    if (!lease.has_value()) {
        return {};
    }
    auto const expected = CurrentClientPresentationAdvantage(*lease);
    if (!expected.has_value()
        || !boh::ShouldPreserveAdvantageSourceModifier(
            *expected, boostType, disabled, state,
            sourceViewModel != 0)) {
        return {};
    }
    return PreservedAdvantageSourceModifier{
        .lease = *lease,
        .vmRoll = vmRollAddress,
        .viewModel = viewModel,
        .sourceViewModel = sourceViewModel,
        .expectedAdvantage = *expected,
        .state = state,
    };
}

void LogPreservedAdvantageSourceModifier(
    PreservedAdvantageSourceModifier const& preserved,
    std::string_view branch) noexcept
{
    if (!TraceEnabled()) {
        return;
    }
    auto const& record = preserved.lease.selection->record;
    Log("TRACE", "native_client_advantage_source_modifier_preserved",
        "action=" + boh::ActionName(record.kind)
        + "|delegation_id=" + std::to_string(record.id)
        + "|roll_uuid=" + record.rollUuid
        + "|branch=" + std::string(branch)
        + "|expected_advantage="
        + std::to_string(preserved.expectedAdvantage)
        + "|state=" + std::to_string(preserved.state)
        + "|viewmodel=" + Hex(preserved.viewModel)
        + "|source_vm=" + Hex(preserved.sourceViewModel)
        + "|vm_roll=" + Hex(preserved.vmRoll)
        + "|source_vm_identity_preserved=1"
        + "|source_icon_binding_preserved=1"
        + "|presentation_only=1"
        + "|authoritative_result_unchanged=1"
        + "|component_owner_unchanged=1"
        + "|roll_bonus_path_unchanged=1"
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64()));
}

void ClientRollBonusPreserveMatchedMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::PreserveMatched);
    try {
        auto const currentDisabled = static_cast<std::uint8_t>(
            context.rax & 0xffU);
        auto const requestedDisabled = static_cast<std::uint8_t>(
            context.rcx & 0xffU);
        if (currentDisabled != 0 || requestedDisabled == 0) {
            return;
        }
        auto const preserved = MatchSelectedDelegatedRollBonus(
            context.rsp, context.rdi);
        if (preserved.has_value()) {
            // The original instruction compares AL (the viewmodel's current
            // disabled state) with CL (the matched StaticModifier state). Keep
            // CL equal to the already-enabled viewmodel so BG3 follows its
            // unchanged branch and never emits the disabling property update.
            context.rcx &= ~static_cast<std::uintptr_t>(0xffU);
            LogPreservedRollBonusViewModel(*preserved, "matched_static");
            return;
        }
        auto const advantage = MatchDelegatedAdvantageSourceModifier(
            context.rsp, context.rdi);
        if (!advantage.has_value()) {
            return;
        }
        context.rcx &= ~static_cast<std::uintptr_t>(0xffU);
        LogPreservedAdvantageSourceModifier(
            *advantage, "matched_static");
    } catch (...) {
        // Preservation is client presentation only and must fail open.
    }
}

void ClientRollBonusPreserveMissingMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::PreserveMissing);
    try {
        auto const currentDisabled = static_cast<std::uint8_t>(
            context.rax & 0xffU);
        if (currentDisabled != 0) {
            return;
        }
        auto const preserved = MatchSelectedDelegatedRollBonus(
            context.rsp, context.rdi);
        if (preserved.has_value()) {
            // The original instruction tests AL and disables the viewmodel
            // only when it is zero. Supplying a local nonzero comparison
            // value skips that branch without changing the viewmodel or
            // modifier component.
            context.rax = (context.rax
                & ~static_cast<std::uintptr_t>(0xffU)) | 1U;
            LogPreservedRollBonusViewModel(*preserved, "missing_static");
            return;
        }
        auto const advantage = MatchDelegatedAdvantageSourceModifier(
            context.rsp, context.rdi);
        if (!advantage.has_value()) {
            return;
        }
        context.rax = (context.rax
            & ~static_cast<std::uintptr_t>(0xffU)) | 1U;
        LogPreservedAdvantageSourceModifier(
            *advantage, "missing_static");
    } catch (...) {
        // Preservation is client presentation only and must fail open.
    }
}

struct PreservedAdvantageViewModel {
    ClientPresentationLeaseSnapshot lease;
    std::uintptr_t vmRoll{};
    std::uintptr_t viewModel{};
    std::uint8_t expectedAdvantage{};
    std::uint8_t advantageType{};
    std::uint8_t state{};
};

std::optional<PreservedAdvantageViewModel>
MatchDelegatedAdvantageSource(std::uintptr_t stackPointer,
    std::uintptr_t viewModel) noexcept
{
    if (stackPointer == 0 || viewModel == 0) {
        return {};
    }
    void* vmRoll{};
    std::uint8_t advantageType{};
    std::uint8_t disabled{};
    std::uint8_t state{};
    if (!Read(reinterpret_cast<void const*>(
            stackPointer + kModifierRefreshVmRollStackOffset), vmRoll)
        || vmRoll == nullptr
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kAdvantageVmTypeOffset), advantageType)
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kAdvantageVmDisabledOffset), disabled)
        || !Read(At<std::uint8_t>(reinterpret_cast<void*>(viewModel),
            kAdvantageVmStateOffset), state)) {
        return {};
    }
    auto const vmRollAddress = reinterpret_cast<std::uintptr_t>(vmRoll);
    auto const lease = FindClientPresentationLeaseByVmRoll(vmRollAddress);
    if (!lease.has_value()) {
        return {};
    }
    auto const expected = CurrentClientPresentationAdvantage(*lease);
    if (!expected.has_value()
        || !boh::ShouldPreserveAdvantageModifierPresentation(
            *expected, advantageType, disabled, state)) {
        return {};
    }
    return PreservedAdvantageViewModel{
        .lease = *lease,
        .vmRoll = vmRollAddress,
        .viewModel = viewModel,
        .expectedAdvantage = *expected,
        .advantageType = advantageType,
        .state = state,
    };
}

void LogPreservedAdvantageViewModel(
    PreservedAdvantageViewModel const& preserved,
    std::string_view branch) noexcept
{
    if (!TraceEnabled()) {
        return;
    }
    auto const& record = preserved.lease.selection->record;
    Log("TRACE", "native_client_advantage_disable_suppressed",
        "action=" + boh::ActionName(record.kind)
        + "|delegation_id=" + std::to_string(record.id)
        + "|roll_uuid=" + record.rollUuid
        + "|branch=" + std::string(branch)
        + "|expected_advantage="
        + std::to_string(preserved.expectedAdvantage)
        + "|advantage_type="
        + std::to_string(preserved.advantageType)
        + "|state=" + std::to_string(preserved.state)
        + "|viewmodel=" + Hex(preserved.viewModel)
        + "|vm_roll=" + Hex(preserved.vmRoll)
        + "|presentation_only=1"
        + "|authoritative_result_unchanged=1"
        + "|component_owner_unchanged=1"
        + "|roll_bonus_path_unchanged=1"
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64()));
}

void TraceAdvantageViewModelBinding(
    safetyhook::Context const& context,
    std::string_view branch) noexcept
{
    if (!TraceEnabled() || context.rdi == 0 || context.rsp == 0) {
        return;
    }
    void* vmRoll{};
    auto const viewModel = reinterpret_cast<void*>(context.rdi);
    std::uint8_t advantageType{};
    std::uint8_t disabled{};
    std::uint8_t state{};
    std::uintptr_t tagReason{};
    std::uintptr_t sourceVm{};
    std::array<std::uint64_t, 2> identity{};
    std::array<std::byte, kAdvantageVmTraceBytes> raw{};
    if (!Read(reinterpret_cast<void const*>(
            context.rsp + kModifierRefreshVmRollStackOffset), vmRoll)
        || vmRoll == nullptr
        || !Read(At<std::uint8_t>(viewModel,
            kAdvantageVmTypeOffset), advantageType)
        || !Read(At<std::uint8_t>(viewModel,
            kAdvantageVmDisabledOffset), disabled)
        || !Read(At<std::uint8_t>(viewModel,
            kAdvantageVmStateOffset), state)
        || !Read(At<std::uintptr_t>(viewModel,
            kAdvantageVmTagReasonOffset), tagReason)
        || !Read(At<std::uintptr_t>(viewModel,
            kAdvantageVmSourceVmOffset), sourceVm)
        || !Read(At<std::array<std::uint64_t, 2>>(viewModel,
            kAdvantageVmIdentityOffset), identity)) {
        return;
    }
    bool const rawReadable = Read(viewModel, raw);
    auto const vmRollAddress = reinterpret_cast<std::uintptr_t>(vmRoll);
    auto const lease = FindClientPresentationLeaseByVmRoll(vmRollAddress);
    auto const branchKey = branch == "matched_static"
        ? 0x01ULL : 0x02ULL;
    auto const key = 0xa700000000000000ULL
        ^ vmRollAddress ^ context.rdi ^ branchKey;
    std::uint64_t pass{};
    {
        std::scoped_lock lock(g_profileTraceMutex);
        pass = ++g_profilePasses[key];
    }
    if (pass > 4) {
        return;
    }

    Log("TRACE", "native_client_advantage_viewmodel_binding",
        "action=" + (lease.has_value()
            ? boh::ActionName(lease->selection->record.kind)
            : std::string("reference"))
        + "|delegation_id=" + (lease.has_value()
            ? std::to_string(lease->selection->record.id)
            : std::string("none"))
        + "|roll_uuid=" + (lease.has_value()
            ? lease->selection->record.rollUuid
            : std::string("unmapped"))
        + "|profile_mode=" + (lease.has_value()
            ? std::string("delegated")
            : std::string("vanilla_reference"))
        + "|branch=" + std::string(branch)
        + "|pass=" + std::to_string(pass)
        + "|advantage_type=" + std::to_string(advantageType)
        + "|disabled=" + std::to_string(disabled)
        + "|state=" + std::to_string(state)
        + "|comparison_current_disabled="
        + std::to_string(static_cast<std::uint8_t>(
            context.rax & 0xffU))
        + "|comparison_requested_disabled="
        + std::to_string(static_cast<std::uint8_t>(
            context.rcx & 0xffU))
        + "|identity_lo=" + Hex(identity[0])
        + "|identity_hi=" + Hex(identity[1])
        + "|tag_reason=" + Hex(tagReason)
        + "|source_vm=" + Hex(sourceVm)
        + "|source_vm_present=" + std::to_string(sourceVm != 0 ? 1 : 0)
        + "|raw_vm="
        + (rawReadable ? HexBytes(raw) : std::string("unreadable"))
        + "|viewmodel=" + Hex(context.rdi)
        + "|vm_roll=" + Hex(vmRollAddress)
        + "|observation_only=1"
        + "|thread_id=" + std::to_string(GetCurrentThreadId())
        + "|tick_ms=" + std::to_string(GetTickCount64()));
}

void ClientAdvantagePreserveMatchedMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::AdvantageMatched);
    try {
        TraceAdvantageViewModelBinding(context, "matched_static");
        auto const currentDisabled = static_cast<std::uint8_t>(
            context.rax & 0xffU);
        auto const requestedDisabled = static_cast<std::uint8_t>(
            context.rcx & 0xffU);
        if (currentDisabled != 0 || requestedDisabled == 0) {
            return;
        }
        auto const preserved = MatchDelegatedAdvantageSource(
            context.rsp, context.rdi);
        if (!preserved.has_value()) {
            return;
        }

        // The original instruction compares the VMAdvantage's current
        // Disabled byte in AL with the matched static source's value in CL.
        // Keep the already-enabled native row unchanged.
        context.rcx &= ~static_cast<std::uintptr_t>(0xffU);
        LogPreservedAdvantageViewModel(*preserved, "matched_static");
    } catch (...) {
        // Advantage-source presentation must fail open to BG3's refresh.
    }
}

void ClientAdvantagePreserveMissingMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::AdvantageMissing);
    try {
        TraceAdvantageViewModelBinding(context, "missing_static");
        auto const currentDisabled = static_cast<std::uint8_t>(
            context.rax & 0xffU);
        if (currentDisabled != 0) {
            return;
        }
        auto const preserved = MatchDelegatedAdvantageSource(
            context.rsp, context.rdi);
        if (!preserved.has_value()) {
            return;
        }

        // The original instruction disables only when AL is zero. Supplying a
        // local nonzero comparison value skips that UI-only transition; the
        // source viewmodel, modifier component, and result remain untouched.
        context.rax = (context.rax
            & ~static_cast<std::uintptr_t>(0xffU)) | 1U;
        LogPreservedAdvantageViewModel(*preserved, "missing_static");
    } catch (...) {
        // Advantage-source presentation must fail open to BG3's refresh.
    }
}

void ClientRollBonusRendererAddMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::RendererAdd);
    try {
        if (context.rsi == 0
            || context.r14 < kVmRollDynamicModifierCollectionOffset) {
            return;
        }
        auto const viewModel = context.rsi;
        auto const vmCollection = context.r14;
        auto const vmRoll =
            vmCollection - kVmRollDynamicModifierCollectionOffset;
        auto const lease = FindClientPresentationLeaseByVmRoll(vmRoll);
        if (!lease.has_value()) {
            return;
        }

        std::uint8_t boostType{};
        std::uintptr_t sourceVmBefore{};
        std::uint8_t diceSize{};
        std::uint8_t diceCount{};
        std::uint8_t disabled{};
        std::uint8_t state{};
        if (!Read(At<std::uint8_t>(
                    reinterpret_cast<void*>(viewModel),
                    kDynamicModifierVmBoostTypeOffset), boostType)
            || (boostType != kDynamicModifierRollBonusType
                && boostType != 0x31)
            || !Read(At<std::uintptr_t>(
                    reinterpret_cast<void*>(viewModel),
                    kDynamicModifierVmSourceVmOffset), sourceVmBefore)
            || sourceVmBefore != 0
            || !ReadRollBonusViewModelDice(viewModel,
                diceSize, diceCount, disabled, state)
            || diceCount == 0) {
            return;
        }

        auto const cached =
            FindCachedRollBonusPresentations(*lease->selection);
        std::uintptr_t selected{};
        std::uintptr_t sourceVm{};
        std::size_t sameShape{};
        for (auto const& candidate : cached) {
            if (candidate.diceSize != diceSize
                || candidate.diceCount != diceCount) {
                continue;
            }
            std::uintptr_t candidateDiceTypeSet{};
            std::uintptr_t candidateSourceVm{};
            DynamicModifierIdentity candidateIdentity{};
            std::uint8_t candidateDiceSize{};
            std::uint8_t candidateDiceCount{};
            std::uint8_t candidateVisible{};
            if (!ReadSelectedRollBonusViewModel(
                    candidate.selectedViewModel,
                    candidateDiceTypeSet, candidateIdentity,
                    candidateDiceSize, candidateDiceCount,
                    candidateVisible)
                || !ReadSelectedRollBonusSourceVm(
                    candidate.selectedViewModel,
                    candidateSourceVm)
                || candidateSourceVm == 0
                || candidateDiceSize != diceSize
                || candidateDiceCount != diceCount) {
                continue;
            }
            ++sameShape;
            selected = candidate.selectedViewModel;
            sourceVm = candidateSourceVm;
        }
        if (sameShape != 1 || selected == 0 || sourceVm == 0) {
            return;
        }

        bool const transferred =
            SetDynamicModifierSourceVm(viewModel, sourceVm);
        if (!TraceEnabled()) {
            return;
        }
        auto const& record = lease->selection->record;
        Log("TRACE", "native_client_roll_bonus_renderer_source_bound",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|dice_size=" + std::to_string(diceSize)
            + "|dice_count=" + std::to_string(diceCount)
            + "|boost_type=" + std::to_string(boostType)
            + "|disabled=" + std::to_string(disabled)
            + "|state=" + std::to_string(state)
            + "|cached_same_shape=" + std::to_string(sameShape)
            + "|source_vm=" + Hex(sourceVm)
            + "|source_vm_transferred="
            + std::to_string(transferred ? 1 : 0)
            + "|name_source=native_renderer"
            + "|selected_viewmodel=" + Hex(selected)
            + "|viewmodel=" + Hex(viewModel)
            + "|vm_roll=" + Hex(vmRoll)
            + "|binding_timing=before_first_collection_add"
            + "|authoritative_result_unchanged=1"
            + "|component_owner_unchanged=1"
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Early icon binding is client presentation only and must fail open.
    }
}

[[maybe_unused]] void ClientRollBonusPreserveSelectedMidHook(
    safetyhook::Context& context) noexcept
{
    try {
        if (!TraceEnabled()) {
            return;
        }
        auto const viewModel = reinterpret_cast<void*>(context.rbx);
        if (viewModel == nullptr
            || context.r15 < kActiveRollDynamicModifierCollectionOffset
            || context.r13 == 0) {
            return;
        }

        auto const activeRollAddress = context.r15
            - kActiveRollDynamicModifierCollectionOffset;
        auto const activeRoll = reinterpret_cast<void*>(activeRollAddress);
        void* vmRoll{};
        std::uint32_t rollState{};
        if (!Read(At<std::uint32_t>(
                    activeRoll, kActiveRollStateOffset), rollState)
            || !Read(At<void*>(
                    activeRoll, kActiveRollVmRollOffset), vmRoll)
            || vmRoll == nullptr) {
            return;
        }

        auto const lease = FindClientPresentationLeaseByVmRoll(
            reinterpret_cast<std::uintptr_t>(vmRoll));
        if (!lease.has_value()) {
            return;
        }

        std::uintptr_t diceTypeSet{};
        std::uintptr_t sourceVm{};
        DynamicModifierIdentity identity{};
        std::uint8_t visible{};
        std::uint8_t diceSize{};
        std::uint8_t diceCount{};
        if (!ReadSelectedRollBonusViewModel(
                reinterpret_cast<std::uintptr_t>(viewModel),
                diceTypeSet, identity, diceSize, diceCount, visible)
            || !ReadSelectedRollBonusSourceVm(
                reinterpret_cast<std::uintptr_t>(viewModel),
                sourceVm)) {
            return;
        }

        auto const presentInPrimary = ContainsDynamicModifierIdentity(
            reinterpret_cast<void const*>(context.r13),
            kRollModifiersDynamicModifiersOffset, identity);
        auto const presentInSelected = ContainsDynamicModifierIdentity(
            reinterpret_cast<void const*>(context.r13),
            kRollModifiersDynamicModifiers2Offset, identity);
        auto const presentInRetiring = ContainsDynamicModifierIdentity(
            reinterpret_cast<void const*>(context.r13),
            kRollModifiersDynamicModifiers3Offset, identity);
        auto const shouldPromote = boh::ShouldPromoteMissingSelectedRollBonus(
                true,
                visible == 0,
                true,
                true,
                diceCount,
                !presentInSelected);
        auto const& record = lease->selection->record;
        Log("TRACE",
            "native_client_roll_bonus_nested_viewmodel_candidate",
            "action=" + boh::ActionName(record.kind)
                + "|delegation_id=" + std::to_string(record.id)
                + "|roll_uuid=" + record.rollUuid
                + "|dice_size=" + std::to_string(diceSize)
                + "|dice_count=" + std::to_string(diceCount)
                + "|visible=" + std::to_string(visible)
                + "|roll_state=" + std::to_string(rollState)
                + "|present_primary=" + std::to_string(
                    presentInPrimary ? 1 : 0)
                + "|present_selected=" + std::to_string(
                    presentInSelected ? 1 : 0)
                + "|present_retiring=" + std::to_string(
                    presentInRetiring ? 1 : 0)
                + "|promotion_eligible="
                + std::to_string(shouldPromote ? 1 : 0)
                + "|legacy_promotion_disabled=1"
                + "|selected_collection_writes=0"
                + "|identity_lo=" + Hex(identity.guid[0])
                + "|identity_hi=" + Hex(identity.guid[1])
                + "|identity_type=" + std::to_string(identity.type)
                + "|dice_type_set=" + Hex(diceTypeSet)
                + "|source_vm=" + Hex(sourceVm)
                + "|selected_layout=source_vm_at_48_dice_at_e0_identity_at_110"
                + "|viewmodel="
                + Hex(reinterpret_cast<std::uintptr_t>(viewModel))
                + "|vm_roll="
                + Hex(reinterpret_cast<std::uintptr_t>(vmRoll))
                + "|active_roll="
                + Hex(reinterpret_cast<std::uintptr_t>(activeRoll))
                + "|component_owner_unchanged=1"
                + "|thread_id=" + std::to_string(GetCurrentThreadId())
                + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Observation only; BG3's selected-boost collection stays untouched.
    }
}

void ClientRollBonusReconcileEndMidHook(
    safetyhook::Context& context) noexcept
{
    PerfScope perf(PerfMetric::ReconcileEnd);
    try {
        auto observation = g_rollBonusReconciliationObservation;
        g_rollBonusReconciliationObservation = {};
        if (!observation.active
            || observation.activeRoll != context.rdi
            || observation.resultPayload != context.rbx) {
            return;
        }

        if (TraceEnabled()) {
            auto const& record = observation.selection.record;
            for (std::size_t index = 0;
                 index < observation.viewModelCount; ++index) {
                auto const& current = observation.viewModels[index];
                void const* staticModifier{};
                bool const staticFound = FindStaticModifier(
                    reinterpret_cast<void const*>(
                        observation.modifiersComponent),
                    current.guid, staticModifier);
                std::uint8_t staticDisabled{};
                bool const staticDisabledReadable = staticFound
                    && Read(At<std::uint8_t>(
                        const_cast<void*>(staticModifier),
                        kStaticModifierDisabledOffset), staticDisabled);
                std::uint8_t disabledAfter{};
                bool const disabledAfterReadable = Read(At<std::uint8_t>(
                    reinterpret_cast<void*>(current.viewModel),
                    kDynamicModifierVmDisabledOffset), disabledAfter);
                std::uint8_t visibleAfter{};
                bool const visibleAfterReadable = Read(At<std::uint8_t>(
                    reinterpret_cast<void*>(current.viewModel),
                    kDynamicModifierVmVisibleOffset), visibleAfter);
                Log("TRACE",
                    observation.delegated
                        ? "native_client_roll_bonus_viewmodel_observed"
                        : "native_client_roll_bonus_reference_viewmodel_observed",
                    "action=" + (observation.delegated
                        ? boh::ActionName(record.kind)
                        : std::string("reference"))
                    + "|delegation_id=" + (observation.delegated
                        ? std::to_string(record.id) : std::string("none"))
                    + "|roll_uuid=" + (observation.delegated
                        ? record.rollUuid : std::string("unmapped"))
                    + "|profile_mode=" + (observation.delegated
                        ? std::string("delegated")
                        : std::string("vanilla_reference"))
                    + "|index=" + std::to_string(index)
                    + "|guid_lo=" + Hex(current.guid[0])
                    + "|guid_hi=" + Hex(current.guid[1])
                    + "|descriptor_readable="
                    + std::to_string(
                        current.descriptorReadable ? 1 : 0)
                    + "|dice_size="
                    + std::to_string(current.diceSize)
                    + "|dice_count="
                    + std::to_string(current.diceCount)
                    + "|disabled_before="
                    + std::to_string(current.disabledBefore)
                    + "|disabled_after="
                    + (disabledAfterReadable
                        ? std::to_string(disabledAfter) : "unreadable")
                    + "|visible_after="
                    + (visibleAfterReadable
                        ? std::to_string(visibleAfter) : "unreadable")
                    + "|static_modifier_found="
                    + std::to_string(staticFound ? 1 : 0)
                    + "|static_modifier_disabled="
                    + (staticDisabledReadable
                        ? std::to_string(staticDisabled)
                        : (staticFound ? "unreadable" : "absent"))
                    + "|raw_vm="
                    + ((current.rawReadable && current.diceCount != 0)
                        ? HexBytes(current.raw) : std::string("omitted"))
                    + "|viewmodel=" + Hex(current.viewModel)
                    + "|component_owner_unchanged=1"
                    + "|thread_id="
                    + std::to_string(GetCurrentThreadId())
                    + "|tick_ms="
                    + std::to_string(GetTickCount64()));
            }
        }

        if (!observation.delegated) {
            return;
        }

        std::size_t represented{};
        for (std::size_t index = 0;
             index < observation.viewModelCount; ++index) {
            auto const& current = observation.viewModels[index];
            if (!current.descriptorReadable || current.diceCount == 0) {
                continue;
            }
            std::uint8_t viewModelDisabled{};
            if (!Read(At<std::uint8_t>(
                    reinterpret_cast<void*>(current.viewModel),
                    kDynamicModifierVmDisabledOffset),
                    viewModelDisabled)
                || viewModelDisabled != 0) {
                continue;
            }
            // BG3's result reconciler matches enabled dynamic viewmodels to
            // resolved bonuses by dice shape. It does not require the original
            // modifier GUID or its replicated disabled flag to match.
            if (ConsumeResolvedBonus(observation,
                    current.diceSize, current.diceCount).has_value()) {
                ++represented;
            }
        }

        std::size_t restored{};
        for (std::size_t index = 0;
             index < observation.viewModelCount; ++index) {
            auto const& current = observation.viewModels[index];
            if (!current.descriptorReadable || current.diceCount == 0
                || current.disabledBefore != 0) {
                continue;
            }
            void const* staticModifier{};
            bool const staticFound = FindStaticModifier(
                reinterpret_cast<void const*>(
                    observation.modifiersComponent),
                current.guid, staticModifier);
            std::uint8_t staticDisabled{};
            bool const staticDisabledReadable = !staticFound
                || Read(At<std::uint8_t>(
                    const_cast<void*>(staticModifier),
                    kStaticModifierDisabledOffset), staticDisabled);
            // An enabled GUID-matched viewmodel represents the authoritative
            // bonus normally and was consumed in the first pass. A matched
            // StaticModifier that BG3 disabled during this refresh does not:
            // the already-resolved result is the stronger truth for this
            // completed roll, so it remains eligible for client restoration.
            if (!staticDisabledReadable
                || (staticFound && staticDisabled == 0)) {
                continue;
            }
            std::uint8_t disabledAfter{};
            if (!Read(At<std::uint8_t>(
                    reinterpret_cast<void*>(current.viewModel),
                    kDynamicModifierVmDisabledOffset), disabledAfter)
                || disabledAfter == 0) {
                continue;
            }
            auto const bonusIndex = ConsumeResolvedBonus(observation,
                current.diceSize, current.diceCount);
            if (!bonusIndex.has_value()) {
                continue;
            }

            auto* disabled = At<std::uint8_t>(
                reinterpret_cast<void*>(current.viewModel),
                kDynamicModifierVmDisabledOffset);
            auto* state = At<std::uint8_t>(
                reinterpret_cast<void*>(current.viewModel),
                kDynamicModifierVmStateOffset);
            if (!Write(disabled, std::uint8_t{ 0 })
                || !Write(state, current.stateBefore)) {
                observation.bonuses[*bonusIndex].consumed = false;
                continue;
            }
            auto const notified = NotifyDynamicModifierDisabled(
                current.viewModel);
            ++restored;

            if (TraceEnabled()) {
                auto const& record = observation.selection.record;
                auto const& bonus = observation.bonuses[*bonusIndex];
                Log("TRACE",
                    "native_client_roll_bonus_viewmodel_restored",
                    "action=" + boh::ActionName(record.kind)
                    + "|delegation_id=" + std::to_string(record.id)
                    + "|roll_uuid=" + record.rollUuid
                    + "|dice_size=" + std::to_string(bonus.diceSize)
                    + "|dice_count=" + std::to_string(bonus.diceCount)
                    + "|resolved_bonus=" + std::to_string(bonus.value)
                    + "|disabled_before="
                    + std::to_string(current.disabledBefore)
                    + "|disabled_after_refresh="
                    + std::to_string(disabledAfter)
                    + "|static_modifier_found="
                    + std::to_string(staticFound ? 1 : 0)
                    + "|static_modifier_disabled="
                    + (staticFound
                        ? std::to_string(staticDisabled) : "absent")
                    + "|state_restored="
                    + std::to_string(current.stateBefore)
                    + "|property_notified="
                    + std::to_string(notified ? 1 : 0)
                    + "|viewmodel=" + Hex(current.viewModel)
                    + "|authoritative_result_unchanged=1"
                    + "|component_owner_unchanged=1"
                    + "|thread_id="
                    + std::to_string(GetCurrentThreadId())
                    + "|tick_ms=" + std::to_string(GetTickCount64()));
            }
        }

        if (TraceEnabled()) {
            std::size_t unresolved{};
            for (std::size_t index = 0;
                 index < observation.bonusCount; ++index) {
                if (!observation.bonuses[index].consumed) {
                    ++unresolved;
                }
            }
            auto const& record = observation.selection.record;
            Log("TRACE", "native_client_roll_bonus_reconcile_completed",
                "action=" + boh::ActionName(record.kind)
                + "|delegation_id=" + std::to_string(record.id)
                + "|roll_uuid=" + record.rollUuid
                + "|viewmodels_observed="
                + std::to_string(observation.viewModelCount)
                + "|resolved_bonus_count="
                + std::to_string(observation.bonusCount)
                + "|already_represented=" + std::to_string(represented)
                + "|restored=" + std::to_string(restored)
                + "|unresolved=" + std::to_string(unresolved)
                + "|authoritative_result_unchanged=1"
                + "|component_owner_unchanged=1"
                + "|thread_id=" + std::to_string(GetCurrentThreadId())
                + "|tick_ms=" + std::to_string(GetTickCount64()));
        }
    } catch (...) {
        g_rollBonusReconciliationObservation = {};
        // Any unexpected layout fails open to BG3's original reconciliation.
    }
}

void ClientRollFinalizeMidHook(safetyhook::Context& context) noexcept
{
    PerfRollCompletion completion;
    PerfScope perf(PerfMetric::Finalize);
    try {
        auto const activeRoll = reinterpret_cast<void*>(context.rdi);
        void* vmRoll{};
        if (!Read(At<void*>(
                activeRoll, kActiveRollVmRollOffset), vmRoll)
            || vmRoll == nullptr) {
            return;
        }
        auto const lease = FindClientPresentationLeaseByVmRoll(
            reinterpret_cast<std::uintptr_t>(vmRoll));
        if (!lease.has_value()) {
            return;
        }
        auto const expected = CurrentClientPresentationAdvantage(*lease);
        if (!expected.has_value()) {
            return;
        }

        auto const result = reinterpret_cast<void*>(context.rbx);
        std::uint8_t natural{};
        std::uint8_t discarded{};
        std::int8_t modifier{};
        if (!IsReadable(result, kMinimumRollResultBytes)
            || !Read(At<std::uint8_t>(
                    result, kRollResultNaturalOffset), natural)
            || !Read(At<std::uint8_t>(
                    result, kRollResultDiscardedOffset), discarded)
            || !Read(At<std::int8_t>(
                    result, kRollResultModifierOffset), modifier)) {
            return;
        }

        // The client result's discarded-die byte may still be stale here even
        // though the authoritative specialist result contains the second die.
        // The exact frozen lease supplies the presentation expectation; only
        // require a valid natural result before preserving normal animation.
        bool const replicatedResultValid =
            natural >= 1 && natural <= 20;
        if (!replicatedResultValid) {
            return;
        }

        auto const modifiersMatched = static_cast<std::uint8_t>(
            context.rax & 0xffU);
        auto const modifierInRange = static_cast<std::uint8_t>(
            context.r14 & 0xffU);
        auto const advantageMatched = static_cast<std::uint8_t>(
            context.r15 & 0xffU);
        std::uint8_t fallbackBefore{};
        bool const fallbackReadable = Read(At<std::uint8_t>(
            activeRoll, kActiveRollFallbackOffset), fallbackBefore);
        std::uint8_t displayedBefore{};
        bool const displayedReadable = Read(At<std::uint8_t>(
            activeRoll, kActiveRollDisplayedValueOffset), displayedBefore);
        std::uint8_t immediateTotal{};
        bool const immediateTotalReadable = Read(At<std::uint8_t>(
            activeRoll, kActiveRollImmediateTotalOffset), immediateTotal);

        // This is the server-replicated result already accepted by BG3 for the
        // delegated roll. Preserve the normal result animation branch even
        // when an initiator-owned modifier viewmodel cannot reconcile its
        // identity with the specialist-targeted resolved bonus.
        context.rax = (context.rax
                & ~static_cast<std::uintptr_t>(0xffU)) | 1U;
        context.r14 = (context.r14
                & ~static_cast<std::uintptr_t>(0xffU)) | 1U;
        context.r15 = (context.r15
                & ~static_cast<std::uintptr_t>(0xffU)) | 1U;

        if (!TraceEnabled()) {
            return;
        }
        std::uint32_t rollState{};
        Read(At<std::uint32_t>(
            activeRoll, kActiveRollStateOffset), rollState);
        auto const& record = lease->selection->record;
        Log("TRACE", "native_client_roll_finalize_consistency",
            "action=" + boh::ActionName(record.kind)
            + "|delegation_id=" + std::to_string(record.id)
            + "|roll_uuid=" + record.rollUuid
            + "|roll_state=" + std::to_string(rollState)
            + "|expected_advantage=" + std::to_string(*expected)
            + "|result_natural=" + std::to_string(natural)
            + "|result_discarded=" + std::to_string(discarded)
            + "|result_modifier="
            + std::to_string(static_cast<int>(modifier))
            + "|modifiers_matched_before="
            + std::to_string(modifiersMatched)
            + "|modifier_in_range_before="
            + std::to_string(modifierInRange)
            + "|advantage_matched_before="
            + std::to_string(advantageMatched)
            + "|fallback_before_finalize="
            + (fallbackReadable
                ? std::to_string(fallbackBefore) : "unreadable")
            + "|displayed_value_before_finalize="
            + (displayedReadable
                ? std::to_string(displayedBefore) : "unreadable")
            + "|immediate_total="
            + (immediateTotalReadable
                ? std::to_string(immediateTotal) : "unreadable")
            + "|normal_animation_after=1"
            + "|replicated_result_validated=1"
            + "|result_numeric_values_unchanged=1"
            + "|component_owner_unchanged=1"
            + "|vm_roll="
            + Hex(reinterpret_cast<std::uintptr_t>(vmRoll))
            + "|active_roll=" + Hex(context.rdi)
            + "|thread_id=" + std::to_string(GetCurrentThreadId())
            + "|tick_ms=" + std::to_string(GetTickCount64()));
    } catch (...) {
        // Final presentation consistency must fail open.
    }
}

template <std::size_t Size>
bool ValidateHookSite(std::uintptr_t rva,
    std::array<std::byte, Size> const& signature, std::string_view name,
    std::string& failure)
{
    auto const address = reinterpret_cast<void const*>(
        reinterpret_cast<std::uintptr_t>(g_gameModule) + rva);
    if (!IsReadable(address, Size)) {
        failure = std::string(name) + "_signature_unreadable";
        return false;
    }
    if (std::memcmp(address, signature.data(), Size) != 0) {
        failure = std::string(name) + "_signature_mismatch:rva=0x" + [&]() {
            std::ostringstream value;
            value << std::hex << rva;
            return value.str();
        }();
        return false;
    }
    return true;
}

bool InstallCodeHooks(std::string& failure)
{
    if (!ValidateHookSite(g_build->profileUiHookRva,
            kProfileUiSignature, "profile_ui", failure)
        || !ValidateHookSite(g_build->profileMathHookRva,
            kProfileMathSignature, "profile_math", failure)
        || !ValidateHookSite(g_build->clientRollPresentationHookRva,
             kClientRollPresentationSignature,
             "client_roll_presentation", failure)
        || !ValidateHookSite(g_build->clientRollSourceContextHookRva,
             kClientRollSourceContextSignature,
             "client_roll_source_context", failure)
        || !ValidateHookSite(g_build->clientRollAggregateHookRva,
            kClientRollAggregateSignature,
            "client_roll_aggregate", failure)
        || !ValidateHookSite(g_build->clientRollStartHookRva,
            kClientRollStartSignature,
            "client_roll_start", failure)
        || !ValidateHookSite(g_build->clientRollPayloadReadyHookRva,
            kClientRollPayloadReadySignature,
            "client_roll_payload_ready", failure)
        || !ValidateHookSite(g_build->clientRollPostDispatchHookRva,
            kClientRollPostDispatchSignature,
            "client_roll_post_dispatch", failure)
        || !ValidateHookSite(g_build->clientRollResultHookRva,
            kClientRollResultSignature,
            "client_roll_result", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusReconcileStartHookRva,
            kClientRollBonusReconcileStartSignature,
            "client_roll_bonus_reconcile_start", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusReconcileViewModelHookRva,
            kClientRollBonusReconcileViewModelSignature,
            "client_roll_bonus_reconcile_viewmodel", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusPreserveMatchedHookRva,
            kClientRollBonusPreserveMatchedSignature,
            "client_roll_bonus_preserve_matched", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusPreserveMissingHookRva,
            kClientRollBonusPreserveMissingSignature,
            "client_roll_bonus_preserve_missing", failure)
        || !ValidateHookSite(
            g_build->clientAdvantagePreserveMatchedHookRva,
            kClientAdvantagePreserveMatchedSignature,
            "client_advantage_preserve_matched", failure)
        || !ValidateHookSite(
            g_build->clientAdvantagePreserveMissingHookRva,
            kClientAdvantagePreserveMissingSignature,
            "client_advantage_preserve_missing", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusRendererAddHookRva,
            kClientRollBonusRendererAddSignature,
            "client_roll_bonus_renderer_add", failure)
        || !ValidateHookSite(
            g_build->clientRollBonusReconcileEndHookRva,
            kClientRollBonusReconcileEndSignature,
            "client_roll_bonus_reconcile_end", failure)
        || !ValidateHookSite(g_build->clientRollFinalizeHookRva,
            kClientRollFinalizeSignature,
            "client_roll_finalize", failure)
        || !ValidateHookSite(g_build->clientModifierCollectionAddRva,
            kClientModifierCollectionAddSignature,
            "client_modifier_collection_add", failure)
        || !ValidateHookSite(g_build->clientModifierCollectionRemoveRva,
            kClientModifierCollectionAddSignature,
            "client_modifier_collection_remove", failure)
        || !ValidateHookSite(g_build->clientModifierCollectionGetRva,
            kClientModifierCollectionGetSignature,
            "client_modifier_collection_get", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierCollectionAddRva,
            kClientModifierCollectionAddSignature,
            "client_vmroll_modifier_collection_add", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierCollectionRemoveRva,
            kClientModifierCollectionAddSignature,
            "client_vmroll_modifier_collection_remove", failure)
        || !ValidateHookSite(
            g_build->clientSelectedModifierValueRva,
            kClientSelectedModifierValueSignature,
            "client_selected_modifier_value", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierCollectionGetRva,
            kClientModifierCollectionGetSignature,
            "client_vmroll_modifier_collection_get", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierFactoryRva,
            kClientVmRollModifierFactorySignature,
            "client_vmroll_modifier_factory", failure)
        || !ValidateHookSite(
            g_build->clientVmDiceTypeSetPropertySetterRva,
            kClientVmDiceTypeSetPropertySetterSignature,
            "client_vmdicetypeset_property_setter", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierSourceVmPropertySetterRva,
            kClientVmRollModifierSourceVmPropertySetterSignature,
            "client_vmroll_modifier_sourcevm_property_setter", failure)
        || !ValidateHookSite(
            g_build->clientVmRollModifierNameValueAssignRva,
            kClientVmRollModifierNameValueAssignSignature,
            "client_vmroll_modifier_name_value_assign", failure)
        || !ValidateHookSite(
            g_build->clientTaskSelectionHookRva,
            kClientTaskSelectionSignature,
            "client_task_selection", failure)
        || !ValidateHookSite(
            g_build->clientInputControllerUpdateRva,
            kClientInputControllerUpdateSignature,
            "client_input_controller_update", failure)
        || !ValidateHookSite(
            g_build->clientGetCharacterTaskRva,
            kClientGetCharacterTaskSignature,
            "client_get_character_task", failure)
        || !ValidateHookSite(
            g_build->clientSetRunningTaskRva,
            kClientSetRunningTaskSignature,
            "client_set_running_task", failure)) {
        return false;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    g_profileUiHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->profileUiHookRva),
        &ProfileUiMidHook);
    if (!g_profileUiHook) {
        failure = "profile_ui_hook_creation_failed";
        return false;
    }
    g_profileMathHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->profileMathHookRva),
        &ProfileMathMidHook);
    if (!g_profileMathHook) {
        g_profileUiHook.reset();
        failure = "profile_math_hook_creation_failed";
        return false;
    }
    g_clientRollPresentationHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->clientRollPresentationHookRva),
        &ClientRollPresentationMidHook);
    if (!g_clientRollPresentationHook) {
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_presentation_hook_creation_failed";
        return false;
    }
    g_clientRollAggregateHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->clientRollAggregateHookRva),
        &ClientRollAggregateMidHook);
    if (!g_clientRollAggregateHook) {
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_aggregate_hook_creation_failed";
        return false;
    }
    g_clientRollStartHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->clientRollStartHookRva),
        &ClientRollStartMidHook);
    if (!g_clientRollStartHook) {
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_start_hook_creation_failed";
        return false;
    }
    g_clientRollResultHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->clientRollResultHookRva),
        &ClientRollResultMidHook);
    if (!g_clientRollResultHook) {
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_result_hook_creation_failed";
        return false;
    }
    g_clientRollBonusReconcileStartHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusReconcileStartHookRva),
        &ClientRollBonusReconcileStartMidHook);
    if (!g_clientRollBonusReconcileStartHook) {
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_reconcile_start_hook_creation_failed";
        return false;
    }
    g_clientRollBonusReconcileViewModelHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusReconcileViewModelHookRva),
        &ClientRollBonusReconcileViewModelMidHook);
    if (!g_clientRollBonusReconcileViewModelHook) {
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure =
            "client_roll_bonus_reconcile_viewmodel_hook_creation_failed";
        return false;
    }
    g_clientRollBonusPreserveMatchedHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusPreserveMatchedHookRva),
        &ClientRollBonusPreserveMatchedMidHook);
    if (!g_clientRollBonusPreserveMatchedHook) {
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_preserve_matched_hook_creation_failed";
        return false;
    }
    g_clientRollBonusPreserveMissingHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusPreserveMissingHookRva),
        &ClientRollBonusPreserveMissingMidHook);
    if (!g_clientRollBonusPreserveMissingHook) {
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_preserve_missing_hook_creation_failed";
        return false;
    }
    g_clientRollBonusRendererAddHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusRendererAddHookRva),
        &ClientRollBonusRendererAddMidHook);
    if (!g_clientRollBonusRendererAddHook) {
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_renderer_add_hook_creation_failed";
        return false;
    }
    g_clientRollBonusReconcileEndHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollBonusReconcileEndHookRva),
        &ClientRollBonusReconcileEndMidHook);
    if (!g_clientRollBonusReconcileEndHook) {
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_reconcile_end_hook_creation_failed";
        return false;
    }
    g_clientRollFinalizeHook = safetyhook::create_mid(
        reinterpret_cast<void*>(base + g_build->clientRollFinalizeHookRva),
        &ClientRollFinalizeMidHook);
    if (!g_clientRollFinalizeHook) {
        g_clientRollBonusReconcileEndHook.reset();
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_finalize_hook_creation_failed";
        return false;
    }
    g_clientRollPayloadReadyHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollPayloadReadyHookRva),
        &ClientRollPayloadReadyMidHook);
    if (!g_clientRollPayloadReadyHook) {
        g_clientRollFinalizeHook.reset();
        g_clientRollBonusReconcileEndHook.reset();
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_payload_ready_hook_creation_failed";
        return false;
    }
    g_clientRollPostDispatchHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollPostDispatchHookRva),
        &ClientRollPostDispatchMidHook);
    if (!g_clientRollPostDispatchHook) {
        g_clientRollPayloadReadyHook.reset();
        g_clientRollFinalizeHook.reset();
        g_clientRollBonusReconcileEndHook.reset();
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_post_dispatch_hook_creation_failed";
        return false;
    }
    g_clientRollBonusKeepSelectedHook = safetyhook::create_inline(
        reinterpret_cast<void*>(
            base + g_build->clientModifierCollectionRemoveRva),
        &ClientRollBonusKeepSelectedDetour);
    if (!g_clientRollBonusKeepSelectedHook) {
        g_clientRollPostDispatchHook.reset();
        g_clientRollPayloadReadyHook.reset();
        g_clientRollFinalizeHook.reset();
        g_clientRollBonusReconcileEndHook.reset();
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
        failure = "client_roll_bonus_keep_selected_hook_creation_failed";
        return false;
    }
    auto resetExistingCodeHooks = []() noexcept {
        g_clientTaskSelectionHook.reset();
        g_clientRollSourceContextHook.reset();
        g_clientRollBonusKeepSelectedHook.reset();
        g_clientRollPostDispatchHook.reset();
        g_clientRollPayloadReadyHook.reset();
        g_clientRollFinalizeHook.reset();
        g_clientRollBonusReconcileEndHook.reset();
        g_clientRollBonusRendererAddHook.reset();
        g_clientRollBonusPreserveMissingHook.reset();
        g_clientRollBonusPreserveMatchedHook.reset();
        g_clientRollBonusReconcileViewModelHook.reset();
        g_clientRollBonusReconcileStartHook.reset();
        g_clientRollResultHook.reset();
        g_clientRollStartHook.reset();
        g_clientRollAggregateHook.reset();
        g_clientRollPresentationHook.reset();
        g_profileMathHook.reset();
        g_profileUiHook.reset();
    };
    g_clientRollSourceContextHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientRollSourceContextHookRva),
        &ClientRollSourceContextMidHook);
    if (!g_clientRollSourceContextHook) {
        resetExistingCodeHooks();
        failure = "client_roll_source_context_hook_creation_failed";
        return false;
    }
    g_clientAdvantagePreserveMatchedHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientAdvantagePreserveMatchedHookRva),
        &ClientAdvantagePreserveMatchedMidHook);
    if (!g_clientAdvantagePreserveMatchedHook) {
        resetExistingCodeHooks();
        failure = "client_advantage_preserve_matched_hook_creation_failed";
        return false;
    }
    g_clientAdvantagePreserveMissingHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientAdvantagePreserveMissingHookRva),
        &ClientAdvantagePreserveMissingMidHook);
    if (!g_clientAdvantagePreserveMissingHook) {
        g_clientAdvantagePreserveMatchedHook.reset();
        resetExistingCodeHooks();
        failure = "client_advantage_preserve_missing_hook_creation_failed";
        return false;
    }
    g_clientTaskSelectionHook = safetyhook::create_mid(
        reinterpret_cast<void*>(
            base + g_build->clientTaskSelectionHookRva),
        &ClientTaskSelectionMidHook);
    if (!g_clientTaskSelectionHook) {
        g_clientAdvantagePreserveMissingHook.reset();
        g_clientAdvantagePreserveMatchedHook.reset();
        resetExistingCodeHooks();
        failure = "client_task_selection_hook_creation_failed";
        return false;
    }
    g_clientInputControllerUpdateHook = safetyhook::create_inline(
        reinterpret_cast<void*>(
            base + g_build->clientInputControllerUpdateRva),
        &ClientInputControllerUpdateDetour);
    if (!g_clientInputControllerUpdateHook) {
        g_clientTaskSelectionHook.reset();
        g_clientAdvantagePreserveMissingHook.reset();
        g_clientAdvantagePreserveMatchedHook.reset();
        resetExistingCodeHooks();
        failure = "client_input_controller_update_hook_creation_failed";
        return false;
    }
    g_codeHooksReady.store(true);
    Log("INFO", "native_profile_hooks_installed",
        "ui_rva=" + Hex(g_build->profileUiHookRva)
        + "|math_rva=" + Hex(g_build->profileMathHookRva)
        + "|client_roll_presentation_rva="
        + Hex(g_build->clientRollPresentationHookRva)
        + "|client_roll_source_context_rva="
        + Hex(g_build->clientRollSourceContextHookRva)
        + "|client_roll_aggregate_rva="
        + Hex(g_build->clientRollAggregateHookRva)
        + "|client_roll_start_rva="
        + Hex(g_build->clientRollStartHookRva)
        + "|client_roll_payload_ready_rva="
        + Hex(g_build->clientRollPayloadReadyHookRva)
        + "|client_roll_post_dispatch_rva="
        + Hex(g_build->clientRollPostDispatchHookRva)
        + "|client_roll_result_rva="
        + Hex(g_build->clientRollResultHookRva)
        + "|client_roll_bonus_reconcile_start_rva="
        + Hex(g_build->clientRollBonusReconcileStartHookRva)
        + "|client_roll_bonus_reconcile_viewmodel_rva="
        + Hex(g_build->clientRollBonusReconcileViewModelHookRva)
        + "|client_roll_bonus_preserve_matched_rva="
        + Hex(g_build->clientRollBonusPreserveMatchedHookRva)
        + "|client_roll_bonus_preserve_missing_rva="
        + Hex(g_build->clientRollBonusPreserveMissingHookRva)
        + "|client_advantage_preserve_matched_rva="
        + Hex(g_build->clientAdvantagePreserveMatchedHookRva)
        + "|client_advantage_preserve_missing_rva="
        + Hex(g_build->clientAdvantagePreserveMissingHookRva)
        + "|client_roll_bonus_keep_selected_rva="
        + Hex(g_build->clientModifierCollectionRemoveRva)
        + "|client_roll_bonus_renderer_add_rva="
        + Hex(g_build->clientRollBonusRendererAddHookRva)
        + "|client_roll_bonus_reconcile_end_rva="
        + Hex(g_build->clientRollBonusReconcileEndHookRva)
        + "|client_roll_finalize_rva="
        + Hex(g_build->clientRollFinalizeHookRva)
        + "|client_modifier_collection_add_rva="
        + Hex(g_build->clientModifierCollectionAddRva)
        + "|client_modifier_collection_remove_rva="
        + Hex(g_build->clientModifierCollectionRemoveRva)
        + "|client_modifier_collection_get_rva="
        + Hex(g_build->clientModifierCollectionGetRva)
        + "|client_vmroll_modifier_collection_add_rva="
        + Hex(g_build->clientVmRollModifierCollectionAddRva)
        + "|client_vmroll_modifier_collection_remove_rva="
        + Hex(g_build->clientVmRollModifierCollectionRemoveRva)
        + "|client_selected_modifier_value_rva="
        + Hex(g_build->clientSelectedModifierValueRva)
        + "|client_vmroll_modifier_collection_get_rva="
        + Hex(g_build->clientVmRollModifierCollectionGetRva)
        + "|client_vmroll_modifier_factory_rva="
        + Hex(g_build->clientVmRollModifierFactoryRva)
        + "|client_vmdicetypeset_property_setter_rva="
        + Hex(g_build->clientVmDiceTypeSetPropertySetterRva)
        + "|client_vmroll_modifier_sourcevm_property_setter_rva="
        + Hex(g_build->clientVmRollModifierSourceVmPropertySetterRva)
        + "|client_vmroll_modifier_name_value_assign_rva="
        + Hex(g_build->clientVmRollModifierNameValueAssignRva)
        + "|client_task_selection_rva="
        + Hex(g_build->clientTaskSelectionHookRva)
        + "|client_input_controller_update_rva="
        + Hex(g_build->clientInputControllerUpdateRva)
        + "|client_get_character_task_rva="
        + Hex(g_build->clientGetCharacterTaskRva)
        + "|client_set_running_task_rva="
        + Hex(g_build->clientSetRunningTaskRva)
        + "|verified_scope=server"
        + "|client_roll_presentation=verified"
        + "|client_roll_source_context=verified"
        + "|client_roll_aggregate=verified"
        + "|client_roll_start=verified"
        + "|client_roll_payload_ready=verified"
        + "|client_roll_post_dispatch=verified"
        + "|client_roll_result=verified"
        + "|client_roll_bonus_reconcile_start=verified"
        + "|client_roll_bonus_reconcile_viewmodel=verified"
        + "|client_roll_bonus_preserve_matched=verified"
        + "|client_roll_bonus_preserve_missing=verified"
        + "|client_advantage_preserve_matched=verified"
        + "|client_advantage_preserve_missing=verified"
        + "|client_roll_bonus_keep_selected=verified"
        + "|client_roll_bonus_renderer_add=verified"
        + "|client_roll_bonus_presentation_transfer=verified"
        + "|client_roll_bonus_reconcile_end=verified"
        + "|client_roll_finalize=verified"
        + "|client_modifier_collection_add=verified"
        + "|client_modifier_collection_get=verified"
        + "|client_vmroll_modifier_collection_add=verified"
        + "|client_vmroll_modifier_collection_get=verified"
        + "|client_vmroll_modifier_factory=verified"
        + "|client_vmdicetypeset_property_setter=verified"
        + "|client_vmroll_modifier_sourcevm_property_setter=verified"
        + "|client_vmroll_modifier_name_value_assign=verified"
        + "|client_input_controller_update=verified"
        + "|client_get_character_task=verified"
        + "|client_set_running_task=verified"
        + "|ownership_component_mutation=disabled");
    return true;
}

bool WritePointer(void** slot, void* value)
{
    DWORD previous{};
    if (VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &previous) == FALSE) {
        return false;
    }
    InterlockedExchangePointer(slot, value);
    DWORD ignored{};
    VirtualProtect(slot, sizeof(void*), previous, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));
    return true;
}

void RefreshingModifierSystemHook(void* system, void* world, void* gameTime)
{
    RefreshDocument(false);
    g_modifierOriginal(system, world, gameTime);
}

void RefreshingRollSystemHook(void* system, void* world, void* gameTime)
{
    RefreshDocument(false);
    g_rollOriginal(system, world, gameTime);
}

bool PatchSystem(std::string_view name, void* world, std::uintptr_t indexRva,
    SystemUpdateProc hook, SystemUpdateProc& original, void**& slot,
    std::string& failure)
{
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    std::int32_t index{};
    std::uint32_t count{};
    void* entries{};
    if (!Read(reinterpret_cast<void const*>(base + indexRva), index)
        || !Read(At<std::uint32_t>(world, kWorldSystemsCountOffset), count)
        || !Read(At<void*>(world, kWorldSystemsBufferOffset), entries)) {
        failure = std::string(name) + "_system_metadata_unreadable";
        return false;
    }
    if (index < 0 || static_cast<std::uint32_t>(index) >= count
        || count > 4096 || entries == nullptr) {
        failure = std::string(name) + "_system_index_invalid:index="
            + std::to_string(index) + ",count=" + std::to_string(count);
        return false;
    }
    auto const entry = static_cast<std::byte*>(entries)
        + static_cast<std::size_t>(index) * kSystemEntrySize;
    void* update{};
    if (!Read(entry + kSystemEntryUpdateOffset, update) || update == nullptr) {
        failure = std::string(name) + "_system_update_unreadable";
        return false;
    }
    auto updateSlot = reinterpret_cast<void**>(entry + kSystemEntryUpdateOffset);
    original = reinterpret_cast<SystemUpdateProc>(update);
    if (!WritePointer(updateSlot, reinterpret_cast<void*>(hook))) {
        original = nullptr;
        failure = std::string(name) + "_system_update_write_failed";
        return false;
    }
    slot = updateSlot;
    Log("INFO", "native_refresh_hook_installed",
        "system=" + std::string(name)
        + "|index=" + std::to_string(index)
        + "|update=" + Hex(reinterpret_cast<std::uintptr_t>(update)));
    return true;
}

void RestoreSystemHooks()
{
    if (g_rollUpdateSlot != nullptr && g_rollOriginal != nullptr) {
        void* current{};
        if (Read(g_rollUpdateSlot, current)
            && current == reinterpret_cast<void*>(&RefreshingRollSystemHook)) {
            WritePointer(g_rollUpdateSlot, reinterpret_cast<void*>(g_rollOriginal));
        }
    }
    if (g_modifierUpdateSlot != nullptr && g_modifierOriginal != nullptr) {
        void* current{};
        if (Read(g_modifierUpdateSlot, current)
            && current == reinterpret_cast<void*>(&RefreshingModifierSystemHook)) {
            WritePointer(g_modifierUpdateSlot, reinterpret_cast<void*>(g_modifierOriginal));
        }
    }
    g_rollUpdateSlot = nullptr;
    g_modifierUpdateSlot = nullptr;
    g_rollOriginal = nullptr;
    g_modifierOriginal = nullptr;
    g_hooksReady.store(false);
}

bool InstallSystemHooks(void* world, std::string& failure)
{
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    std::int32_t modifierIndex{};
    std::int32_t rollIndex{};
    if (!Read(reinterpret_cast<void const*>(base + g_build->modifierSystemIndexRva),
            modifierIndex)
        || !Read(reinterpret_cast<void const*>(base + g_build->rollSystemIndexRva),
            rollIndex)
        || modifierIndex == rollIndex) {
        failure = "shared_profile_system_indices_invalid";
        return false;
    }
    if (!PatchSystem("modifier", world, g_build->modifierSystemIndexRva,
            &RefreshingModifierSystemHook, g_modifierOriginal,
            g_modifierUpdateSlot, failure)) {
        return false;
    }
    if (!PatchSystem("roll", world, g_build->rollSystemIndexRva,
            &RefreshingRollSystemHook, g_rollOriginal,
            g_rollUpdateSlot, failure)) {
        RestoreSystemHooks();
        return false;
    }
    SetHookFailure({});
    g_serverWorld.store(world);
    g_hooksReady.store(true);
    Log("INFO", "native_hooks_ready",
        "hooks=" + std::string(kReportedHooks)
        + "|client_active_roll_presentation=native|shared_roll_path=1"
        + "|requested_roll_owner_mutation=0|world="
        + Hex(reinterpret_cast<std::uintptr_t>(world)));
    return true;
}

BuildSpec const* DetectBuild()
{
    auto const dos = reinterpret_cast<IMAGE_DOS_HEADER const*>(g_gameModule);
    if (!IsReadable(dos, sizeof(*dos)) || dos->e_magic != IMAGE_DOS_SIGNATURE) {
        return nullptr;
    }
    auto const nt = reinterpret_cast<IMAGE_NT_HEADERS64 const*>(
        reinterpret_cast<std::byte const*>(g_gameModule) + dos->e_lfanew);
    if (!IsReadable(nt, sizeof(*nt)) || nt->Signature != IMAGE_NT_SIGNATURE) {
        return nullptr;
    }
    wchar_t executable[MAX_PATH]{};
    GetModuleFileNameW(g_gameModule, executable, MAX_PATH);
    auto const name = fs::path(executable).filename().wstring();
    for (auto const& build : kBuilds) {
        if (_wcsicmp(name.c_str(), build.executable) == 0
            && nt->FileHeader.TimeDateStamp == build.timestamp
            && nt->OptionalHeader.SizeOfImage == build.imageSize) {
            return &build;
        }
    }
    return nullptr;
}

void* ServerWorld()
{
    if (g_build == nullptr) {
        return nullptr;
    }
    auto const base = reinterpret_cast<std::uintptr_t>(g_gameModule);
    void* server{};
    void* world{};
    if (!Read(reinterpret_cast<void const*>(base + g_build->serverGlobalRva), server)
        || server == nullptr
        || !Read(At<void*>(server, g_build->serverWorldOffset), world)) {
        return nullptr;
    }
    return world;
}

DWORD WINAPI Worker(void*)
{
    PWSTR localAppData{};
    if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT,
            nullptr, &localAppData) != S_OK) {
        return 1;
    }
    auto const root = fs::path(localAppData)
        / L"Larian Studios" / L"Baldur's Gate 3";
    CoTaskMemFree(localAppData);
    std::error_code error;
    fs::create_directories(root / L"Script Extender", error);
    fs::create_directories(root / L"Script Extender Logs", error);
    g_actionPath = root / L"Script Extender" / L"BestOfHandsNative.actions";
    g_clientActionPath = root / L"Script Extender" / L"BestOfHandsNative.client";
    g_leftClickActionPath =
        root / L"Script Extender" / L"BestOfHandsNative.leftclick";
    g_statusPath = root / L"Script Extender" / L"BestOfHandsNative.status";
    g_logPath = root / L"Script Extender Logs" / L"BestOfHandsNative.log";
    LARGE_INTEGER qpcFrequency{};
    if (QueryPerformanceFrequency(&qpcFrequency)) {
        g_perfQpcFrequency.store(
            qpcFrequency.QuadPart, std::memory_order_relaxed);
    }
    g_session = std::to_wstring(GetCurrentProcessId())
        + L"-" + std::to_wstring(GetTickCount64());
    g_sessionUtf8 = Narrow(g_session);
    {
        std::scoped_lock lock(g_clientPresentationLeaseMutex);
        g_clientPresentationLeases.reserve(
            kMaximumClientPresentationLeases);
        g_clientPresentationLeaseByVmRoll.reserve(
            kMaximumClientPresentationLeases);
        g_cachedRollBonusPresentations.reserve(
            kMaximumCachedRollBonusPresentations);
        g_deferredClientViewModelReleases.reserve(
            kMaximumClientPresentationLeases
                * kMaximumRetainedRollBonusViewModels
            + kMaximumCachedRollBonusPresentations);
    }

    g_build = DetectBuild();
    if (g_build == nullptr) {
        WriteStatus("unsupported_game_build",
            "no validated signature set matches this executable", "");
        Log("ERROR", "unsupported_game_build");
        return 2;
    }
    Log("INFO", "loaded", "version=" + std::string(boh::kPluginVersion)
        + "|executable=" + Narrow(g_build->executable));
    if constexpr (kPerfDiagnostics) {
        Log("INFO", "perf_diagnostics_enabled",
            "hot_path=fixed_atomic_qpc"
            "|output=one_background_summary_per_roll"
            "|metric_format=calls,total_us,max_us,first_us,last_us");
    }

    std::string failure;
    if (!InstallCodeHooks(failure)) {
        SetHookFailure(failure);
        WriteCurrentStatus("");
        Log("ERROR", "native_hook_install_failed", "detail=" + failure);
        return 3;
    }
    WriteStatus("waiting_for_server",
        "validated profile and client presentation hooks; waiting for the server entity world",
        "");

    void* lastObservedWorld{};
    std::string lastLoggedFailure;
    auto currentAck = []() {
        std::shared_lock lock(g_documentMutex);
        return g_document.probe;
    };

    while (!g_stop.load()) {
        // Game-thread hooks synchronously refresh this document before profile
        // evaluation. The worker is only a fallback and must not make those
        // hooks wait behind background parsing.
        RefreshDocument(false, false);
        RefreshClientDocument(false);
        RefreshLeftClickDocument(false);
        auto const world = ServerWorld();
        if (world != lastObservedWorld) {
            Log("INFO", world != nullptr ? "server_world_found"
                                          : "server_world_unavailable",
                "world=" + Hex(reinterpret_cast<std::uintptr_t>(world)));
            lastObservedWorld = world;
        }
        auto const hookedWorld = g_serverWorld.load();
        if (g_hooksReady.load() && world != hookedWorld) {
            // The retired world owns the old systems buffer. Do not write back
            // into it; discard those slots and arm against the replacement.
            g_modifierUpdateSlot = nullptr;
            g_rollUpdateSlot = nullptr;
            g_modifierOriginal = nullptr;
            g_rollOriginal = nullptr;
            g_serverWorld.store(nullptr);
            g_hooksReady.store(false);
            SetHookFailure({});
            lastLoggedFailure.clear();
            Log("INFO", "server_world_changed");
            WriteCurrentStatus(currentAck());
        }
        if (!g_hooksReady.load() && world != nullptr) {
            failure.clear();
            if (InstallSystemHooks(world, failure)) {
                lastLoggedFailure.clear();
                WriteCurrentStatus(currentAck());
            } else {
                SetHookFailure(failure);
                if (failure != lastLoggedFailure) {
                    lastLoggedFailure = failure;
                    Log("ERROR", "native_hook_install_failed",
                        "detail=" + failure + "|world="
                        + Hex(reinterpret_cast<std::uintptr_t>(world)));
                    WriteCurrentStatus(currentAck());
                }
            }
        }
        FlushCompletedPerfRolls();
        Sleep(25);
    }
    EndActivePerfRoll(true);
    FlushCompletedPerfRolls();
    g_quickLockpickPending.store(false, std::memory_order_release);
    g_clientInputControllerUpdateHook.reset();
    g_clientTaskSelectionHook.reset();
    RestoreSystemHooks();
    WriteStatus("stopped", "native plugin stopped", "");
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        g_gameModule = GetModuleHandleW(L"bg3_dx11.exe");
        if (g_gameModule == nullptr) {
            g_gameModule = GetModuleHandleW(L"bg3.exe");
        }
        DisableThreadLibraryCalls(module);
        auto const thread = CreateThread(nullptr, 0, &Worker, nullptr, 0, nullptr);
        if (thread != nullptr) {
            CloseHandle(thread);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        g_stop.store(true);
    }
    return TRUE;
}
