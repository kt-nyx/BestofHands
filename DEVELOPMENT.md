# Developing Best of Hands

Best of Hands is a server-side BG3 Script Extender mod that changes only lockpick and trap-disarm interactions. This guide explains the current behavior, runtime design, source layout, validation, packaging, and diagnostic workflow.

## Behavior at a glance

Best of Hands has two related responsibilities:

- After ordinary interaction fails on a still-locked object, request permission for one lockpick roll against that exact target.
- When a lockpick or disarm check begins, select the eligible active-party character with the highest calculated Sleight of Hand modifier and make that character the actual active-roll roller.

The event actor remains the initiator for permission, ownership, stealth, visibility, and crime handling. The specialist supplies only the roll. No modifiers or conditional bonuses are copied between characters.

Delegated rolls use explicit tool handling. Before permission is requested, the runtime searches the specialist, initiator, and remaining active party, followed by the game's party-inventory query. It records a concrete template and owner so one matching tool can be removed after failure. Success and cancellation do not consume a tool.

The runtime responsibilities and design rules below define the implementation boundary.

## Runtime architecture

```text
Osiris listeners (Init.lua)
  |
  +-- InteractionCoordinator
  |     |-- PartySkillResolver -> eligible specialist
  |     |-- initiator permission/crime pipeline
  |     |-- specialist RequestActiveRoll
  |     `-- correlated result and tool/target completion
  |
  +-- RuntimeApi -> protected Osi / Ext calls
  +-- Diagnostics -> structured logs and trace toggle
  `-- LegacyAssistanceCleanup -> cleanup for older boost-based builds only
```

### Native Lockpick and Disarm actions

1. A `RequestCanLockpick` or `RequestCanDisarmTrap` event arrives.
2. The resolver compares calculated raw Sleight of Hand modifiers across eligible active-party members.
3. If the initiator is best or tied for best, Best of Hands leaves the native action unchanged.
4. Otherwise, a one-shot custom response blocks the original roll.
5. Best of Hands runs the normal permission/crime procedures as the initiator under a private request ID.
6. An accepted response starts `RequestActiveRoll` as the selected specialist.
7. A matching private `RollResult` completes the action and clears transient state.

### Automatic lockpick after ordinary interaction

1. Vanilla interaction runs first. A successful key or use path ends normally.
2. `UseFinished(success=0)` captures the initiating actor and exact target.
3. The coordinator verifies that the target is still locked, the actor is outside blocked modes, a tool is available, and the difficulty class can be resolved.
4. Permission processing is deferred until the `UseFinished` callback stack unwinds.
5. The normal permission/crime procedures run as the initiator.
6. The accepted active roll runs as the selected specialist.
7. Success unlocks and reuses the target; failure consumes one selected tool; cancellation consumes none.

The coordinator reserves one action-target pair at a time. A second attempt against the same target is suppressed while the first is active; actions against different targets remain independent. Permission and roll timeouts clear state without retry.

### Party and tool selection

Candidate enumeration starts from `DB_Players`; it is not capped at the vanilla party size. A specialist must be an active member of the initiator's party, in the same loaded region, alive/available, and not a summon. The initiator wins ties.

Direct tool search order is:

1. specialist inventory, across every recognized template state;
2. initiator inventory;
3. other active party members in stable identity order;
4. `GetItemByTemplateInPartyInventory` as the final game-provided fallback.

The explicit scan makes failure consumption deterministic. The final fallback supports inventory arrangements the direct search cannot see, including nested or shared-inventory behavior.

## Source layout

```text
src/BestOfHands/Mods/BestOfHands/
  meta.lsx
  ScriptExtender/
    Config.json
    Lua/
      BootstrapServer.lua
      Server/
        Settings.lua
        Diagnostics.lua
        RuntimeApi.lua
        PartySkillResolver.lua
        LegacyAssistanceCleanup.lua
        InteractionCoordinator.lua
        Init.lua
tests/lua/test_runner.lua
scripts/
  validate.ps1
  validate-release-tag.ps1
  test.ps1
  run_lua_tests.py
  build.ps1
  package-release.ps1
VERSION
```

| Module | Responsibility |
| --- | --- |
| `Settings.lua` | Stable identity, timeouts, recognized tool templates, and unavailable statuses |
| `Diagnostics.lua` | Structured `[best_of_hands]` logging and trace state |
| `RuntimeApi.lua` | Protected engine queries and mutations |
| `PartySkillResolver.lua` | Pure candidate filtering and deterministic modifier comparison |
| `InteractionCoordinator.lua` | Permission, roll, target, resource, timeout, and duplicate-request state machine |
| `LegacyAssistanceCleanup.lua` | Removes exact temporary boosts persisted by older Best of Hands builds; current interactions never add boosts |
| `Init.lua` | Listener, lifecycle, and console-command registration |

Backend naming is fixed by surface:

- Module/folder/table: `BestOfHands`
- Repository: `BestofHands`
- Lua/log/local names: `best_of_hands`
- Public title: `Best of Hands - Quick Lockpick & Disarm`

Do not change the module UUID during ordinary development.

## Design rules

- Begin every decision from the event actor, never a universal host character.
- Keep resolver code free of subscriptions and engine mutations.
- Keep engine access behind `RuntimeApi`.
- Rank candidates by the calculated raw Sleight of Hand modifier, not a passive-check score.
- Preserve initiator-owned permission and crime context.
- Use the specialist as the literal active-roll roller; never add two characters' modifiers.
- Keep tool selection and failure consumption paired through one recorded owner/template.
- Reserve state by action and target, with additional request and roll indexes for correlation.
- Do not retry permission, roll, use, or resource operations automatically.
- Treat uncertain engine state conservatively: skip delegation or automation rather than guessing.
- Keep trace listeners observational.

Review the runtime responsibilities and design rules in this file before changing the runtime contract.

## Prerequisites

- Windows and PowerShell 7
- Git
- [uv](https://docs.astral.sh/uv/) for the ephemeral Python/Lupa test environment
- [BG3 Script Extender](https://github.com/Norbyte/bg3se), API v29 or newer
- [LSLib ExportTool](https://github.com/Norbyte/lslib/releases/tag/v1.20.4), including `Divine.exe`
- A Patch 8 Baldur's Gate 3 installation for manual validation

Pinned tool versions and hashes are in `tools/tool-versions.json`. Do not commit tool binaries, extracted game data, saves, packages, or runtime logs.

## Validation

Run the complete non-game suite:

```powershell
pwsh -NoProfile -File .\scripts\test.ps1
```

The suite:

1. validates metadata, identity, versions, configuration, licensing, SPDX headers, source allowlists, and reference-boundary markers;
2. validates local Markdown links;
3. creates an ephemeral CPython 3.13 environment through `uv` with pinned Lupa and PyYAML versions;
4. parses every packaged Lua file and GitHub workflow;
5. runs pure Lua resolver, runtime-adapter, state-machine, lifecycle, and bootstrap tests.

Add generic tests for each state-machine, tool-selection, or resolver change. Avoid named-character, location, save-specific, or fixed-party-size cases.

## Packaging

Provide `Divine.exe` with one of:

- `-DivinePath 'C:\path\to\Divine.exe'`
- the `DIVINE_PATH` environment variable
- `tools\ExportTool\Packed\Tools\Divine.exe`
- `tools\ExportTool\Tools\Divine.exe`
- `tools\Divine.exe`

Build:

```powershell
pwsh -NoProfile -File .\scripts\build.ps1 -DivinePath 'C:\path\to\Divine.exe'
```

Output:

```text
dist\BestofHands.pak
```

The build creates an LZ4HC package, lists its contents, enforces the exact ten-file allowlist, extracts it, compares every packaged file byte-for-byte with source, and prints SHA-256. A mismatched package is deleted.

Create the Nexus-ready release archive after a successful build:

```powershell
pwsh -NoProfile -File .\scripts\package-release.ps1
```

This produces `dist\BestofHands.zip` with exactly `BestofHands.pak` and `info.json` at the archive root. The sidecar duplicates the module identity from `meta.lsx` and records the PAK's MD5 for compatibility with managers that consume the legacy metadata format. The script expands the ZIP, enforces that two-file allowlist, compares the archived PAK byte-for-byte with the verified build, and validates the sidecar before succeeding.

Local installation is explicit:

```powershell
pwsh -NoProfile -File .\scripts\build.ps1 -DivinePath 'C:\path\to\Divine.exe' -Install
```

Normal validation and release builds must not edit the load order or install files into the game profile.

## Diagnostics

Trace output is disabled by default. Enable Script Extender console/runtime logging in `bin\ScriptExtenderSettings.json`:

```json
{
  "CreateConsole": true,
  "LogRuntime": true
}
```

Use the Script Extender server console commands:

```text
!best_of_hands_trace on
!best_of_hands_status
!best_of_hands_trace off
```

Trace records are single-line, pipe-delimited, and field-sorted:

```text
[best_of_hands]|TRACE|request_can_lockpick|actor=...|request_id=...|target=...
```

An idle coordinator should report `legacy_assistance_cleanup=0` and `pending_delegations=0`. Disable tracing after reproduction and remove personal paths, save names, unrelated logs, and multiplayer identifiers before sharing output.

## Manual validation

For each manual release test, record:

- BG3, BG3SE, and Best of Hands versions;
- package SHA-256 and relevant load order;
- initiator and specialist sheet modifiers;
- roller and modifiers displayed in active-roll UI;
- tools before and after the action;
- result of `!best_of_hands_status` after completion or cancellation;
- relevant `[best_of_hands]` lines.

Validate keys, no-tool behavior, success, failure, cancellation, doors, containers, traps, owned objects, stealth, blocked modes, party changes, larger parties, and concurrent actors. A single successful object is not sufficient release evidence.

## Versioning and releases

`VERSION` is the semantic-version source of truth and contains a stable `MAJOR.MINOR.PATCH` value. `scripts/validate.ps1` verifies that `Server/Settings.lua` and BG3's encoded `Version64` match it.

To publish a release:

1. Update `VERSION`, `Server/Settings.lua`, and both `Version64` values in `meta.lsx`.
2. Run the complete test and package flow locally.
3. Commit and push the version change.
4. Create and push the matching tag, such as `v1.0.0`.

The CI workflow accepts only tags that exactly match `vMAJOR.MINOR.PATCH`, rebuilds and verifies the package, and publishes only `BestofHands.zip` as the GitHub release asset. GitHub supplies its standard source archives separately.

[README.md](README.md) is the player-facing description; this file is the developer-facing implementation and release guide.

## Licensing and reference boundary

Best of Hands acknowledges Auto Lockpicking by Volitio, Use Best Sleight of Hand by JonHinkerton, and Best in Party Skills by imCioco. Do not copy their source, assets, statuses, localization, or metadata. The public acknowledgements and reuse terms are maintained in [README.md](README.md) and [LICENSE](LICENSE).
