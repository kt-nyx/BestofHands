# Developing Best of Hands

Best of Hands 2.1.2 consists of a normal BG3 PAK and a small Windows native plugin. The PAK selects the specialist and owns diagnostics; the DLL changes the roll-profile source at narrow validated server action boundaries and supplies the specialist's aggregate advantage at the exact client `DCActiveRoll` presentation boundary. A bounded, exact-roll-UUID client lease retains that presentation value after the replicated `RequestedRoll` is destroyed and preserves it through BG3's signature-validated modifier-aggregation and click-to-roll boundaries. These hooks never change the server roll component or outcome. On the client they may correct only presentation state, including the local advantage byte and immediate-total fallback flag; numeric result values and ownership remain unchanged. Neither half completes actions, rolls dice, consumes tools, or synthesizes success/failure outcomes. The left-click adapter activates only BG3's stock client Lockpick task through its validated native controller lifecycle; the only gameplay target rewrite is an accepted active-roll bonus: its already validated initiator target is changed to the specialist so the effect enters the delegated profile.

## Runtime contract

Client Lua publishes a compact snapshot of eligible locally controlled
initiator handles and replicated currently locked targets. It derives current
lock state from the replicated `LockBoost` marker, not the persistent `Lock`
key/DC configuration that remains on lock-capable objects after they are
unlocked. Targets for which the
controlled party owns the matching key are excluded so BG3's automatic
key-use path remains vanilla. Initiators in combat or forced turn-based mode
are also excluded. Identical snapshots are not rewritten, and a failed
handshake or file write retries after 250 ms instead of on every client tick.
Native code parses each changed snapshot into duplicate-rejecting hash maps,
so task-selection lookups do not scan every cached world lock. At BG3's exact,
signature-guarded internal task-selection
boundary, after the controller has ranked its reusable character tasks but
before it clears the non-winning tasks' readiness, prepares the winner, or
installs `RunningTask`, the DLL detects an ordinary ItemUse aimed at an
eligible locked target. It reads the real controller owner, obtains that
controller's reusable ItemUse and Lockpick tasks through the exact-build
`InputController::GetCharacterTask` routine, fills the Lockpick task, and
replaces the selected task register. BG3 consequently retires ItemUse,
prepares and installs Lockpick, and cannot leave the original click armed for
another update frame or publish the vanilla `Locked` error. The target network
ID and the following task flags use BG3SE's validated 64-bit `NetId` layout. A
further click on a locked item while that same stock task is running resolves
to the already-running task without replacing or restarting it. BG3 then owns
the normal movement, permission, `RequestCanLockpick`, roll, key/tool, crime,
and outcome pipeline. The task-selection instruction sequence,
`GetCharacterTask`, and the fallback-only `SetRunningTask` routine all have
per-executable RVAs in the exact-build table and independently validated
machine-code signatures; no source-level vtable index or Lua proxy address is
assumed. The validated `GetCharacterTask` address is cached once when the hooks
are installed instead of re-reading and re-validating its machine code during
each intercepted selection. The five contiguous stock Lockpick task fields are
published with one guarded 19-byte write.

After any authoritative lockpick success, including a direct roll by the
already-selected specialist, server Lua immediately
removes that target from the owning client's left-click snapshot. The client
tombstones its stable UUID and handle so a lagging replicated `LockBoost` change
cannot reclassify the now-unlocked object before the player opens it. A future
`LockBoost` creation, session load, or reset clears the tombstone, preserving
genuine relocking and save transitions.

The older failed-`UseFinished` client request remains only as a fail-open
fallback if the native task-selection substitution was temporarily
unavailable. Its
native activation is strictly one-shot: BG3 may accept or decline it, but an
accepted `SetRunningTask` call is never replayed from later controller-update
frames. A short actor-target lifecycle guard suppresses the failed `UseFinished`
event emitted by an already native-owned context-menu or adapter interaction;
it expires after that interaction stops so a later genuine left click can
publish a new fallback request. From
`RequestCanLockpick` onward, both left-click and context-menu entry use the
single shared delegation flow below.

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

## Capability readiness and build resolution

Native readiness is capability-scoped. `quick_lockpick` owns the internal task-selection, controller update, `GetCharacterTask`, and `SetRunningTask` boundaries. `delegated_roll` is atomic: its two server profile/math substitutions, two server-world update slots, and the complete client roll-presentation/reconciliation set must all work together. The status protocol reports `ready`, `pending`, or `unavailable`, a stable reason, and `exact_table` or `structural_compatibility` for each capability. Lua validates each capability's complete hook manifest, gates Quick Lockpick and delegated rolls separately, refreshes pending state, and deduplicates visible warnings by capability, executable, and failure reason. Detailed executable identity and resolution failures remain in the native log.

The DLL contains reviewed native-layout tables for both DX11 and Vulkan executables. A table is the highest-confidence path and is selected only when executable name, PE timestamp, and `SizeOfImage` all match. A known identity never falls back to structural resolution to hide a changed signature: each affected capability fails closed. All pointers, system indexes, entity-map entries, component sizes, and writable slots are range-checked before use.

Version 2.1.2 adds exact tables for BG3 product version `4.1.1.7398727`:

- DX11 `bg3_dx11.exe`: PE timestamp `0x6A21507E`, `SizeOfImage` `0x065B8000`, SHA-256 `E899C67CB90B9C6B0F052E3F758BA8615BC2012E52561C2AF2E6A1E06EF61A2F`.
- Vulkan `bg3.exe`: PE timestamp `0x6A214F72`, `SizeOfImage` `0x0683F000`, SHA-256 `D8CFC0D6D568A2E7C4B1F7B34687C4AAED5506118BB458679B24A926231B85A0`.

The current build registers server `esv::RollSystem` and `esv::active_roll::ModifierSystem` at indexes 390 and 418 respectively, one lower than the preceding supported build. Their static registration records, live system-entry indexes, and executable update procedures are all independently checked; the values are never inferred from the old table. The server-world offset and the client/server component layouts used by the hooks remain unchanged. Hook and helper RVAs moved in several independent clusters, while the DX11 client source-context call also changed its exact relative displacement. That five-byte signature is therefore stored per build rather than weakened with a wildcard.

Unknown identities enter a deliberately narrow compatibility path. Quick Lockpick is retained only if exactly one reviewed table for the same executable still has all four exact instruction boundaries at the reviewed RVAs. This tolerates rebuild timestamps, `SizeOfImage` changes, module rebasing, and unrelated byte changes while preserving the controller/task layouts used by the write-sensitive path. It deliberately does not relocate hook sites or infer task layouts from short matches. Relevant instruction changes, a missing match, or two matching layouts disable only Quick Lockpick. Product version, timestamp, image size, or one loose byte pattern is never sufficient, and signatures are never weakened with wildcards.

Delegated rolls use numerous layout-sensitive client writes, server globals, registration indexes, and live update slots that cannot be safely rediscovered from a few code anchors. They therefore remain unavailable for every unknown executable identity until a reviewed exact table is added, even when Quick Lockpick passes its narrow compatibility proof. This conservative limitation is intentional. Lua tells the user which feature is unavailable, includes sanitized detected game/build information, and directs them to update the mod/loader; normal BG3 behavior and any separately validated capability remain available.

The handshake is challenge/acknowledgement based. A status file from an old BG3 process cannot enable delegation. Malformed or partially written action data clears the native action set instead of retaining stale records.

The native worker does not install any code hooks, inspect the server ECS
system table, or patch game memory during early process startup. It remains
dormant until the matching PAK's current-version Lua challenge is present.
The challenge file must have been rewritten after this BG3 process started and
must not carry a completed native session from an older process. Only then are
the signature-validated code hooks installed, after which the same server-world
pointer must pass four consecutive observations. Before either refresh slot is
written, the server/world objects and the two exact update-pointer slots must be
committed non-image data memory, their metadata must remain stable across two
reads, and both original update functions must belong to executable pages in
the selected BG3 image. Validation deliberately does not require the complete
ECS systems allocation to share one Windows memory region or protection. A
transient, stale, or malformed candidate is rejected and polling continues
without modifying the game.

After installation, the two update slots are health-checked against the exact
Best of Hands refresh-hook addresses instead of being mistaken for unpatched
BG3 functions. Their stored original BG3 targets remain executable-validated
and are never discarded while an installed hook could still call them. A
temporary null server-world observation does not retire live hooks; a stable
non-null replacement world drops only the retired slot addresses and reuses
the callable originals while installing the replacement slots.

## Architecture

```text
PAK / server Lua
  Init.lua
    +-- PartySkillResolver.lua
    +-- QuickLockpickCoordinator.lua -- failed-Use fallback + success invalidation
    +-- NativeInteractionCoordinator.lua
    +-- NativeBridge.lua <---- files ----> BestofHands.dll
    +-- NativeRuntimeApi.lua
    +-- LegacyAssistanceCleanup.lua
    `-- Diagnostics.lua

PAK / client Lua
  Channels.lua
  NativePresentationBridge.lua -> publish locked target + initiator snapshot
                               -> exclude available keys/combat/turn-based mode
                               -> prepare failed-Use fallback request
                               -> tombstone authoritatively unlocked targets
                               -> roll UUID -> client specialist handle

Native DLL
  stock task adapter -> exact-signature internal task-selection boundary
                     -> ItemUse -> native controller/GetCharacterTask lookup
                     -> selected task register = existing Lockpick task
                     -> first-click ownership; repeated clicks do not restart it
                     -> validated InputController update + SetRunningTask fallback
                     -> ordinary RequestCanLockpick
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
                              -> roll-start boundary reassertion
                              -> vanilla viewmodel and animation construction
                              -> scoped client presentation fields only
```

`LegacyAssistanceCleanup.lua` exists only to remove persisted temporary boosts from experimental/pre-v2 builds. Current interactions never add a boost.

The bridge files live under `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender`:

- `BestOfHandsNative.actions`
- `BestOfHandsNative.client`
- `BestOfHandsNative.leftclick`
- `BestOfHandsNative.status`

The native log is `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\BestOfHandsNative.log`.

## Source layout

```text
native/
  CMakeLists.txt
  include/BridgeProtocol.h
  include/CapabilityResolver.h
  include/FixedSnapshot.h
  include/NativeStartupGate.h
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
      Shared/
        Channels.lua
      Server/
        Diagnostics.lua
        Init.lua
        LegacyAssistanceCleanup.lua
        NativeBridge.lua
        NativeInteractionCoordinator.lua
        NativeRuntimeApi.lua
        PartySkillResolver.lua
        QuickLockpickCoordinator.lua
        Settings.lua
tests/lua/test_runner.lua
scripts/
  collect-compatibility-evidence.ps1
  collect_compatibility_evidence.py
  build-native.ps1
  build.ps1
  package-release.ps1
  test.ps1
  test_automation.py
  validate.ps1
.github/workflows/
  bg3-build-watch.yml
  ci.yml
  codex-compatibility-draft.yml
```

Do not change the module UUID during ordinary development.

## Design rules

- Begin with the event actor, never a universal host character.
- Keep resolver code free of subscriptions and mutations.
- Rank by calculated raw Sleight of Hand; do not approximate a profile from that number.
- Never add, subtract, copy, or reconstruct individual modifiers.
- Never block and replace a native action with `RequestActiveRoll`, `Unlock`, `AttemptedDisarm`, or manual tool removal.
- Pre-use interception and the failed-`UseFinished` fallback may activate only BG3's stock client Lockpick task. They must never own permission, movement, rolls, outcomes, keys, or tools.
- Call every wrapped native system exactly once. Substitute only ephemeral register-local sources; never write `RequestedRoll.Roller` or `ServerRollFinishedEvent.Roller`.
- Keep native mutation guarded by a complete executable signature set.
- Treat uncertain state as no delegation. Vanilla behavior must remain available.
- Keep Eternal behavior out of Best of Hands. Compatibility work may observe or cooperate with their stable contracts but must not reproduce their ownership logic.
- Keep production diagnostics outside the click-to-roll hot path. Any presentation-only synchronization must remain separately guarded and must never write replicated gameplay state.

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

The native build fetches and statically links the pinned SafetyHook and Zydis versions. They are build dependencies only; users do not install separate SafetyHook or Zydis DLLs. Their notices are maintained in `THIRD_PARTY_NOTICES.txt` and embedded into the shipped DLL as a Windows resource.

## Validation

Run the complete non-game suite:

```powershell
pwsh -NoProfile -File .\scripts\test.ps1 -BuildNative
```

It validates metadata and version synchronization, exact PAK source contents, licensing/SPDX headers, Markdown links, PowerShell syntax, Lua syntax, workflow YAML and security policy, Steam parsing/state transitions, sanitized evidence and patch policy, capability resolver/coordinator/bridge behavior, the absence of v1 custom execution paths, the C++ build, and native protocol tests.

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
  info.json
  bin\NativeMods\BestofHands.dll
```

The scripts enforce exact allowlists, extract and byte-verify the PAK, verify that the DLL is AMD64, expand and byte-verify the release ZIP, and print SHA-256 hashes. Build and package do not edit the player's load order. `-Install` copies the outputs but still does not launch BG3.

## Diagnostics

Production builds compile native hook tracing out entirely and do not load the
replicated-roll UI observer. This guarantees that enabling a console setting
cannot accidentally restore native trace work on the click-to-roll path.
`!best_of_hands_status` and the normal INFO/WARN/ERROR records remain
available. `!best_of_hands_trace on` enables the lighter Script Extender
server/client bridge traces only.

The fixed-buffer per-roll timing profiler is also compiled out by default.
Build with `scripts\build-native.ps1 -PerformanceDiagnostics` (or pass the
same switch to `test.ps1`/`build.ps1`) to emit one background `PERF` summary
after each roll. The profiled hooks perform no formatting, allocation, file
I/O, or diagnostic locking while a roll is active.

The full native/UI instrumentation is preserved on
`dev/native-hook-tracing`. Use that branch for a diagnostic build when a
runtime investigation needs hook-level snapshots, phase events, modifier
animation deltas, or the replicated `RequestedRoll` observer. Rebase or merge
the production fix under investigation into that branch before building it;
do not publish that branch as the normal release.

## Native presentation notes

`native_client_roll_presentation_selected` is a presentation-only substitution. It runs only at the signature-validated instruction where `DCActiveRoll` copies the replicated advantage byte into `Roll.RollAdvantageType`, and only for a correlated client-scope delegated roll with a concrete specialist advantage value. It replaces the low byte of the local register before BG3's existing change notification and viewmodel construction. `native_client_roll_aggregate_guard` covers the later shared modifier aggregation that otherwise overwrites that value; it replaces the aggregate's local result before the same vanilla compare/store/notification sequence. `native_client_roll_start_boundary` freezes the final selected specialist presentation when the user starts the roll. `native_client_roll_result_consistency` runs before BG3 chooses whether to publish the natural die or the already-summed result to the visible-value property. For an exact delegated lease with a valid result, it clears only the client `DCActiveRoll` fallback flag, supplies the frozen specialist advantage to the local comparison and client presentation fields, and leaves every numeric result value unchanged.

The three `native_client_roll_bonus_reconcile_*` hooks bracket BG3's own dynamic-modifier refresh inside that result handler. Server retargeting can legitimately replace the selected initiator-facing roll-bonus modifier with a specialist-facing StaticModifier carrying a different GUID, or leave the corresponding StaticModifier present but mark it disabled after its dice have already resolved. BG3 performs this refresh twice, with the second pass nested inside its result-publication path. The matched-identity and missing-identity `native_client_roll_bonus_preserve_*` guards therefore intercept the original disable branches themselves.

`DCActiveRoll.SelectedBoostModifierList` contains `VMBoostModifier` objects, not the `VMRollModifier` objects stored in `Roll.Modifiers`; their reflected layouts and roles are different. `VMBoostModifier` exposes the selected source viewmodel at `+0x48`, its `DiceTypeSet` at `+0xE0`, `Owner` at `+0x100`, and dynamic identity at `+0x110`. `VMRollModifier` stores `DiceTypeSet` at `+0x110`, `BoostType` at `+0x130`, `SourceType` at `+0x148`, and the retained `SourceVM` that supplies the native label/icon at `+0x1C8`. The function-entry click hook retains the selected wrapper for one roll. Once the detached request payload is complete, a signature-guarded inline hook suppresses only BG3's attempted removal of that exact wrapper from that exact active-roll collection, preventing the pre-roll card from flickering out while the authoritative result is in flight. No result-facing placeholder is added to `Roll.Modifiers`. Once the authoritative dice value arrives, the reconciler writes it directly to the exact selected-wrapper value object read by BG3's own modifier-animation callback (`+0xB0`). The selected card therefore remains the single visible and numeric animation path from selection through resolution. If that direct handoff cannot be proven, the code removes the selected wrapper before falling back to an authoritative result-facing `VMRollModifier`, so presentation may degrade but the bonus cannot double-apply.

BG3's unmodified result reconciler still owns the authoritative `ResolvedRollBonus` and its already-resolved value. The direct handoff accepts only a positive authoritative result and does not roll or recalculate a bonus. Fixed modifiers, advantage sources, ordinary rolls, pre-roll deselection, early dispatch exits, and non-dice modifiers remain untouched. Multiple same-shaped cached bonuses fail open rather than risk an incorrect presentation. The diagnostic branch can record `direct_selected_targets`, `selected_authoritative_count`, `pre_roll_synthetic_rows`, `selected_path_fallbacks`, and `single_numeric_presentation_path`, in addition to the authoritative-value and source-viewmodel bindings. None of these hooks changes the result payload, server modifier component, roller, subject, caster, resource owner, or success/failure outcome. The roll-finalization consistency hook prevents other initiator-owned presentation mismatches from re-enabling the immediate-total fallback. Direct specialist rolls, persistent ownership, and server math remain untouched.

Server destruction is observational because it precedes BG3's later `RollResult` and post-roll UI path. `RequestedRoll.Canceled` is also observed on ordinary completed outcomes and never owns server cleanup. Client Lua removes its file mapping when the replicated `RequestedRoll` is destroyed, but the DLL retains the already-validated presentation selection by exact roll UUID for the remainder of the native session; its 64-entry least-recently-used bound prevents unbounded growth, and a different roll UUID, initiator, or target cannot match it. A canceled `RollResult` (`result=2`) removes the authoritative server profile mapping on the next tick; ordinary failures (`result=0`) remain mapped for native Inspiration and lockpick Try Again. Diagnostic-branch lifecycle and modifier traces are bounded per roll.

`native_roll_bonus_spell_request` records the spell request, caster/source, targets, and whether the accepted request targeted the initiator or specialist. An initiator-targeted delegated bonus is rewritten once to the specialist and emits `native_roll_bonus_retargeted`; caster, originator, spell identity, and resource ownership are unchanged.

Before arming delegation, Lua asks BG3's party-inventory query for the action tool. Base-game roots are always eligible. Optional roots are eligible only when their owning module is active according to `Ext.Mod.IsModLoaded`; a detection failure retains only the base-game roots. If no eligible tool is available, Best of Hands creates no native profile record, publishes the existing vanilla custom-response database result `0`, and calls BG3's native non-modal `ShowError` notification with the built-in generic `CannotUse` key. This is necessary because an untouched request reaches `RequestProcessed(..., 1)` and opens an ordinary empty-tool roll in the current game build. The generic notification is native BG3 behavior, but it is not yet claimed to be the exact action-specific text used by an unmodded no-tool interaction.

Eternal Lockpick `2.0.8.8` and Eternal Trap Disarm Kit `3.0.8.10` are integrated as independent optional tool providers. Best of Hands recognizes only their loaded module and tool-root identities. It never chooses, consumes, transfers, renews, or recreates their items and never reproduces their reward logic. Once the availability precheck passes, BG3's stock action and each provider's own story remain authoritative. The real roller remains the initiator, so provider-owned failure renewal and success callbacks retain their native recipient.

## BG3 update and Codex draft automation

### Scheduled watcher

`.github/workflows/bg3-build-watch.yml` runs at minute 17 every four hours and by manual dispatch. A secretless Ubuntu discovery job downloads SteamCMD directly from Valve, logs in anonymously, and parses only `depots.branches.public.buildid` for app `1086940`; unrelated `tested_build_id` fields are rejected. A separate issue-write job compares that decimal ID with one durable issue labelled `automation-state:bg3-build`. The initial `BG3_BASELINE_BUILD_ID` is `24532579`. An unchanged build causes no issue mutation or email; the successful Actions run is the record of the check.

For a new build, the workflow creates or updates one issue labelled `bg3-update-detected`, with exact hidden build markers, old/new IDs, UTC time, links, and manual next steps. It emails through Resend with a build-derived idempotency key and advances the durable state only after the provider accepts the email. Concurrency, state and issue markers, and the provider key prevent ordinary duplicates. GitHub and an external provider cannot form one atomic transaction, so a crash after email acceptance but before state advancement can retry the same provider request; Resend's idempotency key is the final duplicate guard.

Required repository configuration:

- Secret `RESEND_API_KEY`.
- Variables `NOTIFICATION_EMAIL_FROM` (a verified Resend sender), `NOTIFICATION_EMAIL_TO`, and `BG3_BASELINE_BUILD_ID=24532579`.
- Default workflow permissions may stay read-only; the workflow declares only `issues: write` in its state job.

If discovery fails, inspect the SteamCMD and parser steps and rerun; never paste Steam output into an agent prompt. If state validation fails, repair the single state issue marker rather than deleting issues. If email fails, no new build is committed to state, so a rerun safely reuses the same detection issue and idempotency key.

### Sanitized local evidence

Run the collector on Windows after reviewing an update issue:

```powershell
pwsh -NoProfile -File .\scripts\collect-compatibility-evidence.ps1 `
  -SteamBuildId 24532579 `
  -Executable bg3_dx11.exe `
  -OutputPath .\artifacts\compatibility-evidence.json
```

The wrapper uses pinned `pefile` and Capstone packages. It emits executable and section SHA-256 hashes, PE metadata, candidate RVAs/counts, normalized instruction/control-flow fingerprint hashes, and validation booleans. It emits no executable bytes, raw disassembly, base64 executable content, username, Steam owner ID, or absolute local path. Run it once for `bg3_dx11.exe` and once with `-Executable bg3.exe` when both renderer paths need review. Review each JSON, place it at `compatibility-evidence/bg3-<build-id>-<executable>.json` in a short-lived commit, then select that executable and supply the exact 40-character commit SHA to the manual workflow. One run drafts one executable path, so trigger separate reviewed runs for DX11 and Vulkan. In a public repository this sanitized metadata is public; use a private fork or obtain approval before committing it if that is undesirable.

### Manual Codex compatibility draft

`.github/workflows/codex-compatibility-draft.yml` accepts a decimal Steam build ID, the matching update issue number, the executable covered by the evidence, an exact evidence commit SHA, and a constrained model choice. `gpt-5.6-terra` is the default; `gpt-5.6-sol` is the only override. Set `CODEX_WORKFLOW_ACTOR` to the only GitHub username allowed to dispatch it and create a protected `codex-compatibility` environment containing `OPENAI_API_KEY`. Keep required reviewers on that environment if a second human approval is desired.

Codex workflow configuration is therefore: environment secret `OPENAI_API_KEY`; repository secret `RESEND_API_KEY`; repository variables `CODEX_WORKFLOW_ACTOR`, `NOTIFICATION_EMAIL_FROM`, and `NOTIFICATION_EMAIL_TO`; and a protected `codex-compatibility` environment. No address, password, API key, or SMTP credential belongs in the repository.

The workflow validates the issue marker and strict evidence schema without copying issue text into the prompt. After the protected environment is approved it sends the start email, then invokes the official `openai/codex-action`, pinned to v1.11 commit `52fe01ec70a42f454c9d2ebd47598f9fd6893d56`, Codex CLI `0.146.0`, Linux `drop-sudo`, and the `:workspace` permission profile. The Codex step receives no Git credentials, email secret, proprietary executable, Steam output, release notes, or network access. Its fixed prompt treats typed evidence as untrusted data and its JSON output is limited to a 250 KB text patch. Fresh jobs enforce a narrow source/test/documentation allowlist, reject release/version/workflow/Nexus/binary/symlink/submodule/path-traversal changes, apply the patch, open a generated branch and draft PR, and run the full Windows test/build/package suite with the pinned CMake toolchain. Nothing merges, tags, releases, uploads to Nexus, changes `main`, or uploads a BG3 executable automatically.

API usage is billed to the OpenAI API project behind `OPENAI_API_KEY`, separately from ChatGPT or Codex subscriptions. The job is capped at 30 minutes and enables an 80,000 weighted-token rollout budget. Use a dedicated API project/key, set conservative project monthly budget alerts and rate limits, and revoke the key when automation is not needed. Budget alerts are not guaranteed hard spending cutoffs; the workflow timeout and rollout budget are the per-run controls.

Start and final emails use `RESEND_API_KEY`, `NOTIFICATION_EMAIL_FROM`, and `NOTIFICATION_EMAIL_TO`. Final status is `succeeded`, `failed`, or `needs intervention` and includes the Actions, update issue, and draft PR links when available. If preparation fails, correct the actor, issue marker, evidence path/schema, or SHA. If Codex fails, inspect only the trusted action log and rerun manually. If patch policy fails, review the rejected paths and revise the fixed prompt/evidence rather than weakening policy. If Windows validation fails, keep the PR in draft, fix it manually, and rerun tests. Never enable automatic merge or reuse the compatibility workflow as a release workflow.

The existing `.github/workflows/ci.yml` remains the only release workflow. Its `nexus-production` approval, `NEXUSMODS_FILE_ID`, and deliberately blank Nexus file description are protected by repository validation.

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

For the left-click entry specifically, compare a locked door and container
against their context-menu Lockpick actions. Confirm the first click begins
the normal lockpick flow without the red-X or world-space `Locked` feedback,
the roll opens without the failed-Use delay, rapid later clicks neither
replace nor postpone the first request, and exactly one roll appears after movement.
Also confirm
ordinary key use without a roll, the native no-tool rejection, coalescing of
rapid repeated clicks, and no automatic task in combat or forced turn-based
mode. Then validate keys, no-tool behavior, doors, containers, pressure
plates, vents, owned objects, stealth, forced turn-based mode, party changes,
larger parties, save reload, and multiplayer actors. Run the matrix separately
on DX11 and Vulkan.

Run the Eternal compatibility matrix with neither provider, each provider alone, and both together. Confirm the ordinary roll UI uses the provider item's native name and icon, failures renew exactly one provider item through provider-owned behavior, successes preserve it and award provider-owned XP once, and absent providers leave base-game tool behavior unchanged.

## Versioning

`VERSION` is the semantic-version source of truth. `Settings.lua`, the native bridge constant, CMake project version, and both `Version64` entries in `meta.lsx` must match it.

The first native release is 2.0.0 because it introduces a new required loader and replaces the runtime architecture. A future lockpick-only Script Extender build may continue separately in the 1.x line; it is not implemented here.

## Licensing and reference boundary

Best of Hands acknowledges Auto Lockpicking by Volitio, Use Best Sleight of Hand by JonHinkerton, Best in Party Skills by imCioco, and Eternal Lockpick and Eternal Trap Disarm Kit by SwissFred. Do not copy their source, assets, statuses, localization, or metadata. User-facing acknowledgements are in [README.md](README.md); additional project acknowledgements and reuse terms are maintained here and in [LICENSE](LICENSE).
