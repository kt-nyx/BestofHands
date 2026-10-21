# Developing Best of Hands

The current source is **2.4.1**. On October 21, 2026, the player confirmed the
optimized build working, reported that the click-to-roll delay had disappeared,
and approved the revised MCM layout. See [release preparation](RELEASE-PREP.md)
for measured performance evidence and remaining coverage limits.

Best of Hands 2.4.1 consists of a normal BG3 PAK and a small Windows native plugin. The PAK selects the specialist and owns diagnostics; the DLL changes the roll-profile source at narrow validated server action boundaries and supplies the specialist's aggregate advantage at the exact client `DCActiveRoll` presentation boundary. A bounded, exact-roll-UUID client lease retains that presentation value after the replicated `RequestedRoll` is destroyed and preserves it through BG3's signature-validated modifier-aggregation and click-to-roll boundaries. These hooks never change the server roll component or outcome. On the client they may correct only presentation state, including the local advantage byte and immediate-total fallback flag; numeric result values and ownership remain unchanged. Neither half completes actions, rolls dice, consumes tools, or synthesizes success/failure outcomes. The left-click adapter activates only BG3's stock client Lockpick task through its validated native controller lifecycle; the only gameplay target rewrite is an accepted active-roll bonus: its already validated initiator target is changed to the specialist so the effect enters the delegated profile.

## Runtime contract

### Optional feature settings

Players choose On, Only while sneaking, or Off independently for left-click
lockpick, best-in-party lockpick, and best-in-party disarm. All default to On, and MCM remains optional:
`MCM_blueprint.json` declares `Optional: true`, with no metadata dependency.

`Server/FeatureSettings.lua` reads the two party-roll settings through the
public `MCM.Get(id, moduleUuid)` API at action admission. Missing APIs, missing
values, errors, and invalid modes retain On defaults. Legacy booleans are
also readable as On/Off. Resetting MCM
settings or switching profiles therefore takes effect on the next action
without a settings cache or an event-order dependency. Once accepted, a
delegation keeps its existing specialist/bridge record throughout the roll
and Inspiration retries. Settings do not clear or rewrite active records.

MCM blueprint settings normally belong to the host. To provide a personal
left-click mode, `Client/LocalSettings.lua` adds a three-choice selector to the
same **Features** page as the two blueprint settings through the public
`MCM.InsertModMenuTab` API, using the matching tab name. Repeated render callbacks
reuse the existing personal-control group instead of appending duplicates or
clearing MCM's host controls. Each control has only its short multiplayer scope description.
The personal selector uses a separate title above it, MCM's standard muted-gold
description color below it, and the standard reset icon. The menu callback adds
spacing to the two known blueprint groups so all three features have a 16-pixel
gap between groups (including MCM's existing 10-pixel spacer after the first).
These layout adjustments run only when the menu is built.
Its reset button appears away from On and saves On through the same path as a selection change.
The client saves its mode using
`Ext.IO` to `BestOfHands/ClientSettings.json` under the local Script Extender
directory. This file is independent of MCM profiles and save files. It is
ignored when MCM is unavailable, so removing MCM restores all-enabled behavior.
Failed writes restore the previous selection and show an inline error.
The old personal boolean and separate sneak preference are read together:
Off wins, otherwise the old sneak restriction becomes Only while sneaking.
New saves contain just the mode string. Split-screen players sharing one
client share this preference.

The client checks the current preference when admitting an automatic action.
Changing it does not remove accepted fallback requests or roll presentation
records. The failed-Use fallback checks the preference on the owning client before
publishing a native activation request, so the server cannot re-enable a
guest's disabled click feature. No native hook or bridge-protocol change is
needed. Context-menu interactions still reach the independent server-side
party-roll gates. Both sides read `Darkness.CharacterSneaking`; missing Hide
state does not satisfy a conditional mode. The server checks the initiator
only when admitting a new action, preserving accepted rolls and Inspiration.
Status diagnostics report the two host mode strings rather than 1/0 flags.

MCM validates stored values before exposing them through its public API. Since
an enum cannot retain a saved checkbox boolean, public upgrades from 2.3.x
reset the two party-roll modes to On. README documents the one-time need to
reapply Off. The earlier local test install preserved these values by converting
profile JSON offline with backups; that local conversion is not part of the ZIP.
Personal left-click booleans migrate in Lua and retain their previous behavior.

The integration uses MCM's [public API and custom-tab contract](https://github.com/AtilioA/BG3-MCM/blob/main/wiki.md).
See [MCM-TESTING.md](MCM-TESTING.md) for the manual game checks.

### Interaction flow

Automatic lockpicking now gives the normal interaction priority. In 2.4.0,
no task-selection hook replaces ItemUse before its story scripts run. The
base game's `_Global.txt` emits `GLO_UsedLockedItem` only after a failed Use
on a locked object without `DB_CustomUseItemResponse(..., 0)`. Server Lua
listens to this `DualEntityEvent`, never to raw `UseFinished`, and also rejects
current dialogue/custom responses before admission and again on deferred
activation. This covers scripted ordinary Door actions such as Cazador's
ballroom door without maintaining an object-name exception list.

The owning client checks its personal left-click mode and current combat/
turn-based/dialogue state before publishing a new native request. Each of the
three features has an independent On / Only while sneaking / Off mode.
For conditional party sharing, server Lua checks the initiating character's
Hide state at `OnNativeRequest`, before selecting a specialist. It does not
check the specialist's Hide state. `Darkness.CharacterSneaking` represents Hide mode;
being unseen (`ActuallySneaking`) is not required. No frame polling, new
native hook, or protocol change is needed for this preference. Accepted
requests and active rolls retain their admitted behavior.

The DLL consumes that one-shot request at the validated controller-update
boundary using the controller's stock Lockpick task and SetRunningTask
routine. It checks for an existing running task before writing any task
configuration. BG3 owns movement, permission, keys, tools, crime and outcomes.
The normal Locked notice may appear before the roll. Both manual Lockpick and
automatic entry converge on the same permission and delegation flow below.
The compatibility resolver retains its conservative exact-layout signature
checks, including the old task-selection boundary, but installs only the
controller-update hook for automatic activation.

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

Native readiness is capability-scoped. `quick_lockpick` uses controller update, `GetCharacterTask`, and `SetRunningTask`; its resolver conservatively retains the reviewed task-selection signature check. `delegated_roll` is atomic: its two server profile/math substitutions, two server-world update slots, and the complete client roll-presentation/reconciliation set must all work together. The status protocol reports `ready`, `pending`, or `unavailable`, a stable reason, and `exact_table` or `structural_compatibility` for each capability. Lua validates each capability's complete hook manifest, gates Quick Lockpick and delegated rolls separately, refreshes pending state, and deduplicates visible warnings by capability, executable, and failure reason. Detailed executable identity and resolution failures remain in the native log.

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
The challenge must echo the DLL's current process session, a fresh identifier
written into its status file. This avoids depending on which side starts first
or on file modification times. An identifier from an older process is rejected.
Only then are
the signature-validated code hooks installed, after which the same server-world
pointer must pass four consecutive observations. Before either refresh slot is
written, the server/world objects and the two exact update-pointer slots must be
committed non-image data memory, their metadata must remain stable across two
reads, and both original update functions must belong to executable pages in
the selected BG3 image. Validation deliberately does not require the complete
ECS systems allocation to share one Windows memory region or protection. A
transient, stale, or malformed candidate is rejected and polling continues
without modifying the game.

After installation, inexpensive fault-guarded reads check the two update slots
against the exact Best of Hands hook addresses. Full memory-region and executable
protection validation runs on bridge input changes,
rather than during exploration. The originals were fully validated at installation
and are never discarded while an installed hook could still call them. A
temporary null server-world observation does not retire live hooks; a stable
non-null replacement world drops only the retired slot addresses and reuses
the callable originals while installing the replacement slots.

### September 2026 compatibility update (2.3.1)

BG3 `4.1.1.7631656`, Steam build `25605617`, moved several functions used by
the mod. Version 2.3.1 adds separate DX11 and Vulkan tables, preserving older
tables and the existing signature checks. No gameplay behavior or bridge
protocol changed.

| Executable | PE timestamp | SizeOfImage | SHA-256 |
| --- | --- | --- | --- |
| `bg3_dx11.exe` | `0x6AB1357D` | `0x065B5000` | `6FA3CD43E1ADE63C49D7AB9D82231F6E60FF5FC906DB62C1BE76CD926F37AF00` |
| `bg3.exe` | `0x6AB1367E` | `0x0683F000` | `E37DACD2FE5E9B781E44DE7220266B9228F23F52C20F73099E9FACB2E62ECDA0` |

All 33 guarded hook/helper addresses per executable match their exact
signatures and instruction boundaries. The leaf `GetCharacterTask` routine
has no unwind record; its complete short body was inspected separately.
Server globals were located through the Script Extender's server/client
mapping; system-index addresses through the named type-registration routines.
Client collection, presentation, property-notification, and translated-name
helpers were checked through their callers and field accesses. In particular,
the translated-name assignment moved independently to `0x0410EDB0` (DX11)
and `0x041450E0` (Vulkan), so a uniform address shift is incorrect. DX11's
source-context call now matches the existing common exact signature.
Game memory layouts used by these reviewed paths remain unchanged.
Static validation is separate from gameplay validation. The maintainer
confirmed normal mod behavior in-game on September 29 after installing 2.3.1;
the renderer was not specified. Separate gameplay checks of both renderers and
visual confirmation of the warning remain unverified.

The missing warning was reproduced from the September 29 runtime log:
both capabilities reported unavailable, but all three message attempts failed
because `GetHostCharacter()` returned no character during loading. Lua now
combines affected features into one plain-language message, rearms exhausted
attempts on the server's `GameStateChanged` transition to `Running`, and retries
on an affected action if necessary. Successful delivery is recorded as
`native_bridge_warning_shown`; already shown failures remain deduplicated.
The regression test exhausts every loading-time retry, makes the host
available, and verifies one update notice plus no duplicates on later checks.

The warning includes `nexusmods.com/baldursgate3/mods/23881` as plain text.
The installed game's `MessageBoxTemplates.xaml` uses `TextBlockFormatter`,
but offers no verified arbitrary-URL command. Other game pages explicitly
bind their special hyperlinks to `OpenURLInBrowserCommand` with predefined
parameters. Script Extender's ImGui `TextLink` emits a click callback and does
not itself launch a browser. Do not promise a clickable link in this message
box without validating a supported browser-opening route.

Native version-resource strings are truncated at their first NUL terminator:
this BG3 resource reports an overlong string length, which previously appended
adjacent resource fields to the logged game version.

## Architecture

```text
PAK / server Lua
  Init.lua
    +-- FeatureSettings.lua -- optional host MCM settings at action admission
    +-- PartySkillResolver.lua
    +-- QuickLockpickCoordinator.lua -- ordinary locked-Use signal + request lifecycle
    +-- NativeInteractionCoordinator.lua
    +-- NativeBridge.lua <---- files ----> BestofHands.dll
    +-- NativeRuntimeApi.lua
    +-- LegacyAssistanceCleanup.lua
    `-- Diagnostics.lua

PAK / client Lua
  LocalSettings.lua -> personal three-choice click mode and local persistence
  Channels.lua
  NativePresentationBridge.lua -> accept automatic requests after ordinary locked Use
                               -> check personal mode/combat/turn-based/dialogue/Hide
                               -> publish one-shot request with local entity handles
                               -> roll UUID -> client specialist handle

Native DLL
  stock task adapter -> exact-signature controller-update boundary
                     -> native controller/GetCharacterTask lookup
                     -> configure existing Lockpick task after vanilla Use finishes
                     -> one SetRunningTask attempt per admitted request
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

The Lua and native parts exchange small files under
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender`. If Script
Extender's `CustomProfile` setting is present, both use that profile name in
place of the `Baldur's Gate 3` folder.

- `BestOfHandsNative.actions`
- `BestOfHandsNative.client`
- `BestOfHandsNative.status`
- `BestOfHandsNative.handshake`

In protocol 9, each client performs its own startup exchange through the
handshake file. The host separately sends action records through the
`NativeActions` network channel using stable character, target, and roll UUIDs
(identifiers shared across computers). Each client resolves those identifiers
to its own memory handles before publishing its client file; host memory
handles and the host's native session are never used on a guest. Updated
advantage values are also published in that client file.

### Idle runtime work

The mod waits for Windows to report changes to its bridge files using
[`ReadDirectoryChangesW`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw).
Notifications from unrelated mods are ignored. No
timestamps, documents, status files, eligibility lists, or memory regions are
polled during stable exploration. The retired `BestOfHandsNative.leftclick`
producer and reader are removed; automatic eligibility and story permissions
are checked at action admission instead.

A 25 ms notification wait permits constant-size, fault-guarded reads of the
server/world pointers and installed hook slots. These detect world replacement
and hook removal without querying Windows memory regions. New worlds retain
the complete installation preflight and four-observation stability requirement.
The game system wrappers only call their originals; synchronous bridge refresh
moves to actual profile-selection boundaries so a roll cannot race ahead of
the worker's notification. Action processing may still read files and take
short document locks; idle updates do neither.

Status writes run exclusively on the worker, without holding a game-visible
mutex during disk operations. Equal payloads are not republished. A notification
of a removed/replaced status file triggers repair; failed writes retain bounded
backoff. Notification overflow triggers reconciliation, while unavailable
notification storage is retried every two seconds. Incomplete input gets three
short read retries after a notification; subsequent changes and actual rolls
can retry again. This recovery work is separate from stable exploration.

Once the local client receives its acknowledgement, its startup timer stops.
Session/reset events restart the exchange, and actual client actions recheck
status and restart recovery when necessary. Settings, ownership boundaries,
roll leases, Inspiration and action cleanup retain their existing behavior.
Individual roll hooks retain their existing memory checks before using game
objects or writing presentation values. Hook lifecycle state remains owned
by the worker; game hooks do not inspect its mutable installation-slot metadata.

October 21 local DX11 validation used the same latest manual save at Jannath's
Estate for standing and walking/camera samples. Independently identified workers
used 53.3296% versus 0.0533% of one logical CPU in matched 29.3-second focused
windows. An 87-second focused optimized window recorded 0.0180%. Windows CPU
accounting is quantized; these figures establish negligible measured overhead,
not mathematical zero. Aggregate timings isolated the main baseline cost to the
server-world `VirtualQuery` preflight: about 4.9 seconds per ten seconds. The
remaining world/slot observations took about 0.44 ms per ten seconds afterward.
Settled optimized intervals recorded no bridge reads, timestamps, status writes,
refresh-lock attempts or memory-region queries. Wrapper overhead before calling
the original game update averaged 58.37 microseconds before and 0.17 microseconds
after in the diagnostic build.

The player reported the requested lockpick, disarm, specialist-bonus and
Inspiration checks working on the older test save; native logs captured five
completed delegated roll profiles after that transition and empty action records
after cleanup. All 77 Lua tests, native tests (including real directory
notifications), existing repository checks and package byte verification passed.
The installed normal build has diagnostics compiled out and verified hashes.
Raw investigation evidence and rollback copies are retained outside the
checkout in the maintainer's dated BestofHands archive. This does not establish an FPS improvement, Vulkan behavior,
or a fresh multiplayer/MCM-absent gameplay test.

### Further roll and action-update improvements

The follow-up changes reduce work during actual rolls and action-data updates.
The player subsequently reported these working and the click-to-roll delay gone.
The numeric live measurements above describe the first pass; the follow-up
has no separate matched CPU or frame-time measurement.

Five read-only native sites now copy bounded roll data through the existing
fault-guarded reader and inspect the local bytes. This replaces repeated
`VirtualQuery` preflights for roll identity, the active-roll state/viewmodel
span, and result fields. A failed copy does not publish partial bytes. This is
not an atomic engine snapshot: exact roll/session/actor matching still matters.
Checks before writes, game-function calls, hook installation and world replacement
remain. No page-validation cache can outlive a game object.

The client reads its local action file only when the host fallback needs it.
Network data uses local client handles and the current local native session.
Roll create/change/destroy observations maintain a cache of relevant rolls;
ordinary action updates remap only affected rolls. Source changes, resets and
local-session recovery retain a full engine rescan, including rolls that arrived
before their metadata. Identity changes re-resolve the specialist handle even
when the roll UUID is unchanged. Accepted quick requests survive ordinary updates.

Equal client output and server action output are not rewritten. Before skipping
such a write, an event-time read verifies that the file still has those contents;
removed/replaced files are repaired. Failed publications are never cached as
successful, recovery retries can force writes, and server network resends retain
their existing semantics. These checks run on action updates, not idle timers.

All 86 Lua tests and the native tests pass. Focused counters show 100 identical
network updates doing zero engine scans, roll lookups, client writes or speculative
action-file reads, with 100 client-file confirmation reads for recovery. An
advantage update resolves the affected roll once, leaves the unrelated roll
untouched and writes once. Native tests cover null/inaccessible addresses,
cross-page faults, unchanged destinations after failed capture, read-only memory,
and the production field spans. `BestOfHandsReadBenchmark` is an isolated Windows
microbenchmark of the region preflight versus the same guarded copy without it;
its timings do not predict BG3 frame time or end-to-end roll latency.

Release builds have performance recording/output disabled by default. Developers
can opt in with `scripts/build.ps1 -PerformanceDiagnostics`; normal builds omit
the output and enable markers, checked by the build script. Diagnostic roll
summaries include `snapshot_read` alongside the remaining `memory_probe`
queries and ten-second aggregate runtime summaries. Build with BG3 closed and
use `scripts/build.ps1 -Install` without the diagnostic switch to restore the
normal build. The one-off paired diagnostic binaries and switch helper from the
investigation are archived outside the checkout and are not release tools.

Temporary startup waiting does not immediately show a failure notice. Failed
reads are retried without requiring another file modification. After the fast
startup polling expires, Lua continues recovery checks every two seconds.
Confirmed feature failures still produce one deduplicated warning, bounded to
240 ASCII characters before calling BG3's message box. Full reasons stay in
diagnostics.

The native log is `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\BestOfHandsNative.log`.

## Source layout

```text
native/
  CMakeLists.txt
  include/BridgeProtocol.h
  include/CapabilityResolver.h
  include/FixedSnapshot.h
  include/NativeStartupGate.h
  include/NativeStorage.h
  src/BestOfHandsNative.cpp
  tests/BridgeProtocolTests.cpp
src/BestOfHands/Mods/BestOfHands/
  meta.lsx
  MCM_blueprint.json
  ScriptExtender/
    Config.json
    Lua/
      BootstrapClient.lua
      BootstrapServer.lua
      Client/
        LocalSettings.lua
        NativePresentationBridge.lua
        NativeSession.lua
      Shared/
        Channels.lua
      Server/
        FeatureSettings.lua
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
- Automatic entry must follow the stock `GLO_UsedLockedItem` signal and may activate only BG3's stock client Lockpick task. It must never own permission, movement, rolls, outcomes, keys, or tools.
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
dist\BestofHands-v2.3.0.zip
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

That switch also emits ten-second `runtime_profile` summaries: each named
metric is `calls,total_microseconds,max_microseconds`, and worker user/kernel
CPU is reported separately. Nested timings overlap and must not be added
together. `game_refresh` excludes the original game update. Normal builds
compile these counters and periodic output out. `scripts/measure-runtime.ps1`
independently finds the current worker by its start address inside the loaded
DLL, records Windows thread CPU and foreground-process samples, and saves CSV
under `artifacts/runtime-performance`. A foreground sample alone cannot
distinguish gameplay from a menu; record the player's test phase separately.

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

The existing `.github/workflows/ci.yml` remains the only release workflow. Its
`nexus-production` approval and `NEXUSMODS_FILE_ID` remain in place. Before
uploading, `scripts/nexus_release_metadata.py` reads the newest active main
version in that file's update chain through Nexus API v3, then reads its
raw BBCode description through the game-scoped API v1 file endpoint. The helper
converts API line breaks (`<br />` and `&lt;br /&gt;`) to real newlines while
preserving BBCode tags. Nexus returns those two encodings for the legacy and
newly uploaded files respectively; the verification compares equivalent breaks.
The protected, manual `Inspect published Nexus metadata` workflow can read
public descriptions and categories after publication without another upload.
It uses the same tag restrictions and approval gate as publication. The helper
requires formatting tags and preserves them unchanged; it does not scrape the
rendered page or strip tags. The official upload
action receives that same description and `archive_existing_version: false`,
so the preceding version becomes publicly visible under old versions. A
post-upload check verifies its category, the copied description, and a blank
file changelog. Missing descriptions or duplicate versions stop before upload.
GitHub release notes remain empty, and no Nexus changelog is submitted.
Repository validation enforces this publication policy. Merge the release
changes into `main`, wait for its CI/package checks, and tag that clean merged
commit to publish.

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

## 2.4.0 status publication and diagnosis

The DLL retains its latest status until publication succeeds. Its worker
retries failures with 250 ms to 2 s backoff even while waiting for a Lua
challenge, and republishes the current status every 5 s to recover a removed
file, recreating its parent directory if necessary. New status supersedes older pending text without resetting failure
backoff. Diagnostics log the resolved status/action paths, failing operation,
OS error and recovery; repeated identical failures do not flood the log.
Current-process nonce, version, protocol, completion and acknowledgement
checks remain required before either feature can activate.

Client and server use one status reader. Nil loads, read exceptions, empty/incomplete/malformed documents and
version/protocol mismatches have distinct reasons. Ext.IO cannot distinguish
all missing-file and access-denied cases when it returns nil, so that outcome
is described as unavailable rather than proof that the DLL is missing. Mixed-component diagnostics show expected and observed
versions. Details stay in logs; the player warning remains bounded to 240
ASCII characters. These offline guarantees do not establish reporter-specific
recovery or gameplay qualification of the 2.4.0 candidate.
