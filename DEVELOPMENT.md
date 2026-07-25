# Developing Best of Hands

Best of Hands 2.0 consists of a normal BG3 PAK and a small Windows native plugin. The PAK selects the specialist and owns diagnostics; the DLL changes the roll-profile source at narrow validated server action boundaries and supplies the specialist's aggregate advantage at the exact client `DCActiveRoll` presentation boundary. A bounded, exact-roll-UUID client lease retains that presentation value after the replicated `RequestedRoll` is destroyed and preserves it through BG3's signature-validated modifier-aggregation and click-to-roll boundaries. These hooks never change the server roll component or outcome. On the client they may correct only presentation state, including the local advantage byte and immediate-total fallback flag; numeric result values and ownership remain unchanged. Neither half completes actions, rolls dice, consumes tools, or synthesizes success/failure outcomes. The only gameplay target rewrite is an accepted active-roll bonus: its already validated initiator target is changed to the specialist so the effect enters the delegated profile.

## Runtime contract

> **Current validation boundary:** the native profile-source path below is
> implemented for BG3's ordinary lockpick and disarm actions. The v1 automatic
> left-click lockpick entry point is not currently enabled: a failed ordinary
> `Use` does not itself create BG3's client lockpick task. During the first
> runtime validation pass, initiate lockpicking from the native context-menu
> action. Do not publish v2 until a client-task adapter restores left-click
> lockpicking without reviving the removed custom roll/outcome path.

For a delegated lockpick or disarm:

1. The normal player interaction reaches `RequestCanLockpick` or `RequestCanDisarmTrap` with the initiating character and target.
2. Lua selects the eligible active-party character with the highest calculated raw Sleight of Hand value. The initiator wins ties.
3. Lua publishes one short-lived action record containing the action type, stable entity UUIDs, and the server handles for the initiator, specialist, and target.
4. The original Osiris request continues untouched. Permission, crime, movement, action tasks, target state, and toolkit remain owned by BG3 and the initiator.
5. BG3 creates its normal `RequestedRoll` for the initiator. Lua observes that creation and adds the roll entity handle and stable roll UUID to the bridge record; it does not install modifiers or make the specialist the lasting roll owner. Client Lua correlates the replicated roll by that UUID and publishes only the matching client handles in a separate file.
6. Immediately before the server resolves or revalidates the visible modifier profile, the DLL redirects only the UI routine's local profile-source pointer to stable thread-local storage containing the specialist handle. The real `RequestedRoll.Roller` remains the initiator. When the correlated roll reaches the client `DCActiveRoll` builder, separate signature-validated hooks replace the local presentation value copied from `RequestedRoll.AdvantageType` with the specialist's already-observed aggregate advantage. The DLL retains that client-only selection in a bounded lease keyed by exact roll UUID, initiator, and target, because BG3 destroys the replicated component before its post-roll UI. The same value is reasserted immediately before `UserTriggeredNextPhaseCommand` changes `WaitForStart` or `WaitForReRoll` to the rolling phase. At result presentation, the client-only advantage field and `DCActiveRoll` fallback flag are corrected so BG3 builds and animates its ordinary Advantages, Modifiers, and dice viewmodels. Numeric result values, server ownership, and direct-specialist rolls remain untouched.
7. Immediately before BG3 evaluates the roll, the DLL redirects only the evaluator's local actor-source pointer to the specialist. The evaluator therefore obtains the same native profile it would obtain for that specialist, without adding the initiator's bonuses or copying individual modifiers.
8. BG3 completes the original initiator-owned roll and handles Inspiration, Try Again, success/failure callbacks, trap activation, crime, and tool consumption normally.

This shared roll-entity coordinator is used for lockpick and disarm requests. The profile substitution no longer depends on action-specific lockpick or disarm component layouts.

The active-roll UI does not normally show a persistent primary-roller portrait or name. Bonus providers may still be named by native UI entries. Version 2 does not hook UI identity; the requirement is that the displayed native modifier profile is exactly the specialist's.

Roll-UI bonus selection has a split responsibility. A selected bonus affects
the specialist's roll, but range is evaluated from the caster to the initiator
so delegation never requires repositioning the specialist. If the engine
exposes them separately, non-range target eligibility such as race, class, or
status requirements is evaluated against the specialist. If that split is not
available at a safe native boundary, the complete vanilla caster-to-initiator
eligibility result wins rather than making specialist proximity a new
requirement. The current implementation waits for the initiator-targeted
`ServerRollStartSpellRequest`, preserves its caster, originator, spell, and
resource ownership, and rewrites only the effect target to the specialist.

## Fail-closed boundary

The DLL contains validated native-layout tables for both DX11 and Vulkan executables. A table is selected only when executable name, PE timestamp, and `SizeOfImage` all match. All pointers, system indexes, entity-map entries, component sizes, and writable slots are range-checked before use.

Unknown builds are never patched. The DLL writes an `unsupported_game_build` status; Lua rejects it and shows one visible warning per game session. The same behavior applies to a missing DLL, protocol/version mismatch, missing hooks, stale process status, or a native session lost after startup.

The handshake is challenge/acknowledgement based. A status file from an old BG3 process cannot enable delegation. Malformed or partially written action data clears the native action set instead of retaining stale records.

## Architecture

```text
PAK / server Lua
  Init.lua
    +-- PartySkillResolver.lua
    +-- NativeInteractionCoordinator.lua
    +-- NativeBridge.lua <---- files ----> BestOfHandsNative.dll
    +-- NativeRuntimeApi.lua
    +-- LegacyAssistanceCleanup.lua
    `-- Diagnostics.lua

PAK / client Lua
  NativePresentationBridge.lua -> roll UUID -> client specialist handle
  UiRollDiagnostics.lua        -> replicated RequestedRoll/RollModifiers trace

Native DLL
  build guard -> exact server UI/math, client builder, and roll-start signatures
              -> SafetyHook mid-hooks
              -> server world -> shared modifier/roll refresh wrappers
                              -> correlated RequestedRoll identity
                              -> server-local UI profile source = specialist
                              -> server-local math actor source = specialist
                              -> each original engine system exactly once
                              -> no gameplay-component ownership mutation
              -> client DCActiveRoll builder
                              -> transient AdvantageType source = specialist
                              -> bounded exact-UUID presentation lease
                              -> roll-start boundary reassertion and trace
                              -> vanilla viewmodel and animation construction
                              -> scoped client presentation fields only
```

`LegacyAssistanceCleanup.lua` exists only to remove persisted temporary boosts from experimental/pre-v2 builds. Current interactions never add a boost.

The bridge files live under `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender`:

- `BestOfHandsNative.actions`
- `BestOfHandsNative.status`

The native log is `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\BestOfHandsNative.log`.

## Source layout

```text
native/
  CMakeLists.txt
  include/BridgeProtocol.h
  src/BestOfHandsNative.cpp
  tests/BridgeProtocolTests.cpp
src/BestOfHands/Mods/BestOfHands/
  meta.lsx
  ScriptExtender/
    Config.json
    Lua/
      BootstrapClient.lua
      BootstrapServer.lua
      Client/
        NativePresentationBridge.lua
        UiRollDiagnostics.lua
      Server/
        Diagnostics.lua
        Init.lua
        LegacyAssistanceCleanup.lua
        NativeBridge.lua
        NativeInteractionCoordinator.lua
        NativeRuntimeApi.lua
        PartySkillResolver.lua
        Settings.lua
tests/lua/test_runner.lua
scripts/
  build-native.ps1
  build.ps1
  package-release.ps1
  test.ps1
  validate.ps1
```

Do not change the module UUID during ordinary development.

## Design rules

- Begin with the event actor, never a universal host character.
- Keep resolver code free of subscriptions and mutations.
- Rank by calculated raw Sleight of Hand; do not approximate a profile from that number.
- Never add, subtract, copy, or reconstruct individual modifiers.
- Never block and replace a native action with `RequestActiveRoll`, `Unlock`, `AttemptedDisarm`, or manual tool removal.
- Call every wrapped native system exactly once. Substitute only ephemeral register-local sources; never write `RequestedRoll.Roller` or `ServerRollFinishedEvent.Roller`.
- Keep native mutation guarded by a complete executable signature set.
- Treat uncertain state as no delegation. Vanilla behavior must remain available.
- Keep Eternal behavior out of Best of Hands. Compatibility work may observe or cooperate with their stable contracts but must not reproduce their ownership logic.
- Keep trace collection observational and bounded so logging cannot become part of gameplay timing. Any presentation-only synchronization must remain separately guarded and must never write replicated gameplay state.

## Prerequisites

- Windows and PowerShell 7
- Visual Studio 2022 Build Tools with Desktop C++ and CMake
- CMake 3.28 or newer
- Git
- [uv](https://docs.astral.sh/uv/) for Lua/Python validation
- [BG3 Script Extender](https://github.com/Norbyte/bg3se), API v29 or newer
- [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944)
- [LSLib ExportTool](https://github.com/Norbyte/lslib/releases/tag/v1.20.4), including `Divine.exe`
- The exact BG3 executable build recorded in `tools/tool-versions.json` for in-game validation

Pinned tool versions and hashes are recorded in `tools/tool-versions.json`. Do not commit build output, downloaded tools, game data, saves, PAKs, ZIPs, or runtime logs.

The native build fetches and statically links the pinned SafetyHook and Zydis versions. They are build dependencies only; users do not install separate SafetyHook or Zydis DLLs. Their notices are included in `THIRD_PARTY_NOTICES.txt` and the combined release archive.

## Validation

Run the complete non-game suite:

```powershell
pwsh -NoProfile -File .\scripts\test.ps1 -BuildNative
```

It validates metadata and version synchronization, exact PAK source contents, licensing/SPDX headers, Markdown links, PowerShell syntax, Lua syntax, workflow YAML, resolver/coordinator/bridge behavior, the absence of v1 custom execution paths, the C++ build, and native protocol tests.

Host tests cannot prove native structure offsets, engine update order, UI behavior, callbacks, crime attribution, or resource consumption. Those are mandatory in-game release gates for both DX11 and Vulkan.

## Build and package

Build the verified PAK and DLL:

```powershell
pwsh -NoProfile -File .\scripts\build.ps1 -DivinePath 'C:\path\to\Divine.exe'
```

Optionally install both outputs into the local test game:

```powershell
pwsh -NoProfile -File .\scripts\build.ps1 `
  -DivinePath 'C:\path\to\Divine.exe' `
  -GameBinPath 'C:\path\to\Baldurs Gate 3\bin' `
  -Install
```

Create the combined release:

```powershell
pwsh -NoProfile -File .\scripts\package-release.ps1
```

Outputs:

```text
dist\BestofHands.pak
dist\BestofHands.zip
  BestofHands.pak
  THIRD_PARTY_NOTICES.txt
  info.json
  bin\NativeMods\BestOfHandsNative.dll
```

The scripts enforce exact allowlists, extract and byte-verify the PAK, verify that the DLL is AMD64, expand and byte-verify the release ZIP, and print SHA-256 hashes. Build and package do not edit the player's load order. `-Install` copies the outputs but still does not launch BG3.

## Diagnostics

Detailed tracing is disabled by default so its snapshots and formatting do not
affect normal roll latency. Enable Script Extender console/runtime logging in
`bin\ScriptExtenderSettings.json`, then use:

```text
!best_of_hands_trace on
!best_of_hands_status
!best_of_hands_trace off
```

With trace enabled, each delegated attempt has a `delegation_id` across both logs. Useful expected records are:

```text
[best_of_hands]|INFO|native_bridge_ready|...
[best_of_hands]|INFO|native_delegation_armed|...
[best_of_hands]|INFO|native_roll_correlated|...
[best_of_hands_client]|TRACE|client_profile_mapping_written|...
[best_of_hands_native]|TRACE|native_profile_source_selected|stage=ui|profile_scope=server|...|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_profile_source_selected|stage=math|...|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_presentation_selected|profile_scope=client|...|requested_advantage=0|presentation_advantage=1|corrected=1|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_aggregate_guard|...|computed_advantage=...|expected_advantage=1|vanilla_notification_preserved=1|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_start_boundary|...|roll_state=1|observed_advantage=...|expected_advantage=1|presentation_frozen=1|advantage_after=1|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_result_consistency|...|result_natural=...|result_discarded=...|result_modifier=...|fallback_before=...|fallback_after=0|displayed_value_before=...|result_numeric_values_unchanged=1|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_bonus_viewmodels_retained|...|collection_entries=...|eligible_dice_viewmodels=...|newly_retained=...|retention_source=selected_boost_modifier_list|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_bonus_direct_handoff_armed|...|selected_present_count=...|direct_handoff_ready=1|pre_roll_synthetic_rows=0|binding_timing=after_request_payload_before_dispatch|request_payload_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_selected_bonus_restored|...|stage=post_dispatch|restored_count=...|selected_wrapper_identity_preserved=1|request_already_dispatched=1
[best_of_hands_native]|TRACE|native_client_roll_selected_bonus_restored|...|stage=pre_reconcile|restored_count=...|selected_wrapper_identity_preserved=1|request_already_dispatched=1
[best_of_hands_native]|TRACE|native_client_roll_bonus_presentation_bound|...|authoritative_dice_bonus_count=...|direct_selected_targets=...|selected_authoritative_count=...|pre_roll_synthetic_rows=0|authoritative_result_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_bonus_reconcile_started|...|resolved_bonus_count=...|component_owner_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_bonus_reconcile_completed|...|already_represented=...|restored=...|unresolved=...
[best_of_hands_native]|TRACE|native_client_roll_finalize_consistency|...|modifiers_matched_before=...|fallback_before_finalize=0|displayed_value_before_finalize=...|immediate_total=...|normal_animation_after=1|replicated_result_validated=1|result_numeric_values_unchanged=1
[best_of_hands_native]|TRACE|native_client_roll_phase|...|phase=...|roll_state_before=...|displayed_value_before=...|fallback_before=...|immediate_total=...
[best_of_hands_native]|TRACE|native_client_modifier_animation|...|displayed_value_before=...|displayed_value_after=...|displayed_delta=...|fallback_before=...|fallback_after=...
[best_of_hands]|INFO|native_modifiers_observed|...
[best_of_hands]|TRACE|native_requested_roll_state|...|natural_roll=...|discarded_dice_total=...
[best_of_hands_client]|TRACE|client_requested_roll_state|...|profile_mode=...
[best_of_hands_client]|TRACE|client_roll_modifiers|...|profile_mode=...
[best_of_hands]|TRACE|native_roll_bonus_spell_request|...|target_matches_initiator=...|target_matches_specialist=...
[best_of_hands]|INFO|native_delegated_roll_result|...
[best_of_hands]|TRACE|native_finished_event_correlated|...|advantage=...|disadvantage=...|natural_roll=...|owner_matches_initiator=1
```

Each native server UI/math selection is capped at eight trace records per stage and delegation; client presentation selections are capped at twelve, aggregate guards at sixteen, and presentation leases at 64 exact roll UUIDs per native session. `native_finished_event_owner_invalid`, `native_roll_correlation_failed`, `native_bridge_lost`, a native signature/hook failure, or a visible disabled warning means the attempt was rejected or the session failed closed. No custom fallback should run.

Requested-roll state is captured at creation, replicated changes, and destruction. Modifier snapshots are captured at creation and replicated changes, including their outer spell/item/source groups. Client Lua records the correlated replicated `RequestedRoll`, roll results, modifier groups, and bridge lifecycle but deliberately does not traverse or mutate the Noesis visual tree. The native client trace records the requested and specialist presentation advantage, whether correction was required, whether the active bridge or retained lease supplied it, client component and viewmodel addresses, and the unchanged ownership invariant. `native_client_roll_aggregate_guard` records the later value reconstructed by BG3's modifier-viewmodel pass; `native_client_roll_start_boundary` freezes the final selected specialist presentation when the user starts the roll; `native_client_roll_result_consistency` records both dice and the modifier total at the exact result-handler branch which selects vanilla animation versus fallback presentation. When tracing is enabled, a direct specialist action is recorded as `profile_mode=vanilla_reference`; a delegated action is `profile_mode=delegated`. Both include roll metadata, advantage/disadvantage state, discarded dice, reroll arrays, and modifier groups for an exact comparison.

`native_client_roll_presentation_selected` is a presentation-only substitution. It runs only at the signature-validated instruction where `DCActiveRoll` copies the replicated advantage byte into `Roll.RollAdvantageType`, and only for a correlated client-scope delegated roll with a concrete specialist advantage value. It replaces the low byte of the local register before BG3's existing change notification and viewmodel construction. `native_client_roll_aggregate_guard` covers the later shared modifier aggregation that otherwise overwrites that value; it replaces the aggregate's local result before the same vanilla compare/store/notification sequence. `native_client_roll_start_boundary` freezes the final selected specialist presentation when the user starts the roll. `native_client_roll_result_consistency` runs before BG3 chooses whether to publish the natural die or the already-summed result to the visible-value property. For an exact delegated lease with a valid result, it clears only the client `DCActiveRoll` fallback flag, supplies the frozen specialist advantage to the local comparison and client presentation fields, and leaves every numeric result value unchanged.

The three `native_client_roll_bonus_reconcile_*` hooks bracket BG3's own dynamic-modifier refresh inside that result handler. Server retargeting can legitimately replace the selected initiator-facing roll-bonus modifier with a specialist-facing StaticModifier carrying a different GUID, or leave the corresponding StaticModifier present but mark it disabled after its dice have already resolved. BG3 performs this refresh twice, with the second pass nested inside its result-publication path. The matched-identity and missing-identity `native_client_roll_bonus_preserve_*` guards therefore intercept the original disable branches themselves.

`DCActiveRoll.SelectedBoostModifierList` contains `VMBoostModifier` objects, not the `VMRollModifier` objects stored in `Roll.Modifiers`; their reflected layouts and roles are different. `VMBoostModifier` exposes the selected source viewmodel at `+0x48`, its `DiceTypeSet` at `+0xE0`, `Owner` at `+0x100`, and dynamic identity at `+0x110`. `VMRollModifier` stores `DiceTypeSet` at `+0x110`, `BoostType` at `+0x130`, `SourceType` at `+0x148`, and the retained `SourceVM` that supplies the native label/icon at `+0x1C8`. The function-entry click hook retains the selected wrapper for one roll. Once the detached request payload is complete, a signature-guarded inline hook suppresses only BG3's attempted removal of that exact wrapper from that exact active-roll collection, preventing the pre-roll card from flickering out while the authoritative result is in flight. No result-facing placeholder is added to `Roll.Modifiers`. Once the authoritative dice value arrives, the reconciler writes it directly to the exact selected-wrapper value object read by BG3's own modifier-animation callback (`+0xB0`). The selected card therefore remains the single visible and numeric animation path from selection through resolution. If that direct handoff cannot be proven, the code removes the selected wrapper before falling back to an authoritative result-facing `VMRollModifier`, so presentation may degrade but the bonus cannot double-apply.

BG3's unmodified result reconciler still owns the authoritative `ResolvedRollBonus` and its already-resolved value. The direct handoff accepts only a positive authoritative result and does not roll or recalculate a bonus. Fixed modifiers, advantage sources, ordinary rolls, pre-roll deselection, early dispatch exits, and non-dice modifiers remain untouched. Multiple same-shaped cached bonuses fail open rather than risk an incorrect presentation. The completion trace records `direct_selected_targets`, `selected_authoritative_count`, `pre_roll_synthetic_rows`, `selected_path_fallbacks`, and `single_numeric_presentation_path`, in addition to the authoritative-value and source-viewmodel bindings. None of these hooks changes the result payload, server modifier component, roller, subject, caster, resource owner, or success/failure outcome. `native_client_roll_finalize_consistency` prevents other initiator-owned presentation mismatches from re-enabling the immediate-total fallback. Direct specialist rolls, persistent ownership, and server math remain untouched.

Server destruction is observational because it precedes BG3's later `RollResult` and post-roll UI path. `RequestedRoll.Canceled` is also observed on ordinary completed outcomes and never owns server cleanup. Client Lua removes its file mapping when the replicated `RequestedRoll` is destroyed, but the DLL retains the already-validated presentation selection by exact roll UUID for the remainder of the native session; its 64-entry least-recently-used bound prevents unbounded growth, and a different roll UUID, initiator, or target cannot match it. A canceled `RollResult` (`result=2`) removes the authoritative server profile mapping on the next tick; ordinary failures (`result=0`) remain mapped for native Inspiration and lockpick Try Again. Lifecycle and modifier traces are bounded per roll.

`native_roll_bonus_spell_request` records the spell request, caster/source, targets, and whether the accepted request targeted the initiator or specialist. An initiator-targeted delegated bonus is rewritten once to the specialist and emits `native_roll_bonus_retargeted`; caster, originator, spell identity, and resource ownership are unchanged.

Before arming delegation, Lua asks BG3's party-inventory query for the ordinary action tool. If no base-game tool is available, Best of Hands creates no native profile record, publishes the existing vanilla custom-response database result `0`, and calls BG3's native non-modal `ShowError` notification with the built-in generic `CannotUse` key. This is necessary because an untouched request reaches `RequestProcessed(..., 1)` and opens an ordinary empty-tool roll in the current game build. The generic notification is native BG3 behavior, but it is not yet claimed to be the exact action-specific text used by an unmodded no-tool interaction. Best of Hands never chooses or consumes a tool. Optional tool providers must extend this conservative availability boundary as part of their later integration.

## Manual release gates

Test both an initiator with no bonuses and one whose total would exceed the specialist's raw sheet value. For lockpick and disarm, cover success, accepted failure, Inspiration retry, critical failure, cancellation, and consecutive actions. Confirm:

- exactly one visible roll;
- only the specialist's native modifier entries and values;
- no initiator modifier stacking;
- Inspiration retry and lockpick Try Again remain native;
- traps activate on failure and disarm on success;
- locks open only on success;
- the initiating character retains movement, visibility, permission, and crime;
- ordinary tools follow native consumption;
- no stuck/uninteractable target after any terminal path;
- `pending_delegations=0` after completion/cancellation;
- no duplicate roll/result/callback records.

Also validate keys, no-tool behavior, doors, containers, pressure plates, vents, owned objects, stealth, forced turn-based mode, party changes, larger parties, save reload, and multiplayer actors. Run the matrix separately on DX11 and Vulkan.

Eternal Lockpick and Eternal Trap Disarm Kit are not part of the initial v2 release gate. Their compatibility matrix begins only after the base native path is stable.

## Versioning

`VERSION` is the semantic-version source of truth. `Settings.lua`, the native bridge constant, CMake project version, and both `Version64` entries in `meta.lsx` must match it.

The first native release is 2.0.0 because it introduces a new required loader and replaces the runtime architecture. A future lockpick-only Script Extender build may continue separately in the 1.x line; it is not implemented here.

## Licensing and reference boundary

Best of Hands acknowledges Auto Lockpicking by Volitio, Use Best Sleight of Hand by JonHinkerton, Best in Party Skills by imCioco, and Eternal Lockpick and Eternal Trap Disarm Kit by SwissFred. Do not copy their source, assets, statuses, localization, or metadata. Public acknowledgements and reuse terms are in [README.md](README.md) and [LICENSE](LICENSE).
