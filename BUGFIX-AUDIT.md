# Best of Hands 2.3.1 bugfix audit

Reviewed October 2, 2026, at commit `583b05a9f10896aafb166a449ec24c5ea8727b7e`.

## What this means for the patch

There are real defects to fix beyond installation/version mismatch. A temporary startup delay or failed file read can disable features indefinitely. The feature-failure message is also long enough to trigger a documented game memory-overwrite bug. Additional problems affect repeated attempts, roll bonuses, simultaneous characters, and the left-click fallback.

This catalog contains **12 findings**: eight demonstrated failure mechanisms, two integration gaps established by source inspection, and two conditional event-order/lifecycle problems. Demonstrating a mechanism in an isolated test does not establish that it caused either user's incident. No game session was launched, no installed mod was changed, and no runtime source fix or release was made during this review.

The recommended first patch includes safe warning text, correct startup waiting states, recoverable file communication, and the demonstrated gameplay lifecycle defects. Custom-profile and remote-multiplayer support need explicit scope decisions and suitable runtime testing. They must not be described as working merely because a single-player test passes.

## Evidence and priorities

Here, **P1** means a crash risk or a failure that can disable core features for a session. **P2** means incorrect behavior under a narrower configuration, event sequence, or gameplay condition. These are proposed patch priorities, not claims about how often users encounter each issue.

**Demonstrated** means a controlled reproduction exercised the production Lua module or an extracted native function. **Source-established** means the necessary paths are visible in code, but the full gameplay outcome was not run. **Conditional** means the code fails under a specified ordering or missing event whose occurrence in a real session still needs confirmation.

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| B01 | P1 | Feature-failure warning exceeds the game's safe notification buffer | Measured message; documented game crash mechanism |
| B02 | P1 | Ordinary startup waiting can produce a failure warning before startup succeeds | Demonstrated in Lua |
| B03 | P1 | Native readers remember a failed read and skip retries until the file changes | Demonstrated for server reader; same ordering in both client readers |
| B04 | P1 | Lua never recovers after handshake exhaustion or one lost current-status read | Both branches demonstrated in Lua |
| B05 | P2 | A fresh challenge written before native worker initialization is rejected as preexisting | Conditional ordering; gate exercised |
| B06 | P2 | Script Extender custom profiles put Lua and DLL communication files in different folders | Source-established |
| B07 | P1 | Remote multiplayer clients have no local challenge or delegation-data transport | Source-established integration gap |
| B08 | P2 | Retained failed actions swallow new requests from the same character for the same target | Demonstrated in Lua |
| B09 | P2 | Roll-bonus spell requests are associated by character rather than the originating roll | Demonstrated handler behavior; unrelated-roll impact needs runtime confirmation |
| B10 | P1 | Late fallback rewrites a lockpick task that is already running | Demonstrated with extracted native functions |
| B11 | P2 | A previous character's stop event clears a replacement character's delegation | Demonstrated in Lua |
| B12 | P2 | A rejected permission request can suppress fallback forever if no stop event follows | Conditional event lifecycle; suppression demonstrated |

## Startup, warnings, and file communication

### B01 — Warning text can trigger the game's notification overflow

**Impact.** The message intended to explain unavailable features can itself crash the game. This is the strongest explanation found for the report of a crash after the feature-failure notice, although that user's crash has not been reproduced or identified from a dump.

**Evidence.** `Server/NativeBridge.lua:194–243` builds the message and passes it directly to `Osi.OpenMessageBox`. The ordinary combined failure message is **454 ASCII characters** in version 2.3.1. There is no length guard. The Script Extender maintainer identifies a 255-character game notification buffer and explains that exceeding it overwrites memory; the issue reports crashes after dismissing an oversized message. See the [maintainer's explanation](https://github.com/Norbyte/bg3se/issues/248#issuecomment-1925489825).

The earlier release-artifact inspection verified that the published 2.3.1 PAK contains the same warning implementation. This is not dependent on mixing package versions.

**Patch direction.** Use a short, bounded player message with comfortable headroom under the documented limit. Put detailed reasons and troubleshooting in the console/log. Guard every route into this warning, including partial capability failure and update-required variants. A Lua `pcall` cannot make a native memory overwrite safe.

**Minimum verification.** Measure all generated warning variants, including version substitutions. In a disposable runtime test, trigger one genuine unavailable-feature warning and dismiss it. Offline measurements alone cannot establish that the reported crash is fixed.

### B02 — Waiting for startup is presented as a failure

**Impact.** A correctly installed mod can tell a player it could not start and recommend reinstalling even though startup completes on the next scheduled check. B01 makes this inaccurate warning especially dangerous.

**Evidence.** Native `WriteStatus` reports quick lockpick as `unavailable` until its hooks are installed, including `waiting_for_bridge` (`native/src/BestOfHandsNative.cpp:2319–2365`). Lua imports that state into the warning data. `Init.lua:256` schedules `NotifyGameplayReady` when gameplay begins, and that function allows warning delivery while the handshake is still pending (`NativeBridge.lua:267–274`).

The reproduction starts with `waiting_for_bridge`, calls `BeginHandshake` and `NotifyGameplayReady`, observes one 454-character failure warning, then supplies the matching acknowledgement and observes successful readiness on the next poll.

**Patch direction.** Represent expected startup waiting as pending. Warn only after a genuine terminal failure or a defined startup deadline. Keep real compatibility and installation failures visible. Both sides of the state exchange need coherent meanings; shortening the text alone does not solve the false warning.

### B03 — A transient native read failure becomes a cached failure

**Impact.** A brief unavailable or incomplete communication file can leave startup or client features disabled until another write happens. The bridge is the file exchange through which Lua supplies requests to the DLL.

**Evidence.** `RefreshDocument`, `RefreshClientDocument`, and `RefreshLeftClickDocument` record the observed file modification time **before** reading and validating its contents (`BestOfHandsNative.cpp:2406–2497`). Invalid contents clear the corresponding data. Later checks return immediately when the timestamp is unchanged, including when the previous read failed.

An extracted production `RefreshDocument` with the real protocol parser was given one failed read. After the file became readable, **400 further polls made no additional read** and the document remained invalid. Changing the timestamp restored it. The two client readers use the same retry-suppression ordering; their complete runtime effects were inspected, not separately reproduced.

Script Extender's [file-writing implementation](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/Extender/Shared/ScriptHelpers.cpp) writes directly to the destination file. It does not publish a completed temporary file by replacing the destination. That makes an incomplete read a plausible trigger; the reproduction does not measure how often such a race occurs on Windows.

**Patch direction.** Do not treat an unsuccessful read as successfully processed. Retry incomplete/unreadable documents with bounded backoff while keeping invalid data disabled. Apply the policy consistently to all three readers. Preserve rejection of stale sessions and incomplete envelopes.

### B04 — Lua has no recovery path once readiness is lost

**Impact.** A delayed DLL acknowledgement or one failed status-file read can leave native features disabled for the rest of that Lua session, even after the correct status is available.

**Evidence.** `NativeBridge.lua:345–401` stops polling after the configured attempt limit. The default is 40 polls at 250 ms (`Settings.lua:12–13`), approximately ten seconds of scheduled game time. A matching ready acknowledgement supplied after exhaustion is ignored.

Separately, `nativeStatusIsCurrent` at line 324 marks the bridge unavailable after a missing or invalid status read. `IsCapabilityReady` at line 425 rereads status only while the internal `ready` flag is true. Once a read turns that flag false, restoring the same valid status cannot recover it. Both cases were reproduced against the production Lua module. `BeginHandshake` on a later session load/reset provides a reset, not an ongoing recovery mechanism.

**Patch direction.** Add deliberate recovery checks or a fresh handshake after bounded delay. Recover temporary absence without accepting old process/session data. Retain the current rule that a stale acknowledgement cannot activate native hooks.

### B05 — The startup freshness check assumes the DLL worker runs first

**Impact.** If Lua writes a valid current-process challenge before the DLL worker establishes its initial timestamp, both sides can wait indefinitely.

**Evidence.** `Worker` stores `actionWriteTimeAtStartup` and copies it to the reader's processed timestamp (`BestOfHandsNative.cpp:7320–7321`). It requires a later timestamp change before `currentChallengeObserved` becomes true (line 7398). `NativeStartupGate.h:101` then rejects every challenge until that flag is true. Lua's pending handshake polls status; it does not periodically rewrite its challenge.

A valid fresh challenge already on disk when the worker initializes is therefore skipped and rejected. The actual gate was exercised in the native reproduction. **The delayed-worker ordering has not been observed in a live session.** Normal loader ordering may usually prevent it.

**Patch direction.** Establish freshness through an explicit current-process exchange rather than requiring one particular startup order. Do not simply trust preexisting files or remove the stale-file safeguard.

### B06 — Custom-profile paths disagree

**Impact.** A supported Script Extender custom-profile configuration can cause a correct install to write requests in one folder while the DLL watches another.

**Evidence.** `Worker` hardcodes `%LOCALAPPDATA%/Larian Studios/Baldur's Gate 3` at `BestOfHandsNative.cpp:7303–7319`. Script Extender's external file I/O resolves paths through the game profile root. Its [`CustomProfile` implementation](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/Extender/ScriptExtender.cpp#L381-L389) can change that root. The DLL never reads or discovers the alternate root.

**Patch direction.** Resolve one agreed storage location or explicitly detect and report this configuration. Do not assume that a reinstall changes it. Whether either reporting user uses a custom profile is unknown.

## Gameplay and multiplayer

### B07 — Remote clients cannot receive the local startup/data exchange they need

**Impact.** A guest on another computer lacks the startup challenge required by their DLL and the delegation data needed by their roll UI. Host-side delegated calculation and guest-side display/left-click behavior are separate concerns.

**Evidence.** `BootstrapClient.lua` starts the presentation bridge, which reads the **local** `BestOfHandsNative.actions` (`Client/NativePresentationBridge.lua:152–172`). That file is written by `Server/NativeBridge.lua`. Script Extender creates the server only on the host and a client on each peer, as explained in its [client/server documentation](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md#client-server).

`Shared/Channels.lua` exposes only the quick-lockpick channel. Its handlers exchange fallback operations; they do not deliver startup challenges or the host's delegation records to guests. The guest DLL also shares the server-challenge gate in `Worker`. There is no other transport in this codebase that supplies these missing inputs.

**Confidence boundary.** The missing communication path is established by inspection. A two-computer reproduction has not been run. Local single-player/split-screen behavior cannot validate remote-client support, and host roll math may still work while the guest's UI does not.

**Patch direction.** Provide a client-local startup exchange and a host-to-client delegation contract that carries stable identities rather than host memory addresses. Validate guest joining, reconnecting, client preferences, and roll display on two machines. This can be a larger change than the startup hotfix and should be scoped explicitly.

### B08 — A completed failed attempt can prevent a new attempt from being admitted

**Impact.** A later attempt on the same target can retain an earlier specialist and ignore a newly disabled feature. The old record can survive for the production five-minute action timeout.

**Evidence.** `NativeInteractionCoordinator.lua:447–454` returns immediately for any existing action/target record whose initiator matches, without considering the incoming request ID or phase. Failed roll results are retained for retry (line 685), destruction retains the bridge mapping (line 858), and stop events defer cleanup whenever a roll has been associated (line 616).

The controlled sequence was: admit lockpick; associate roll; fail; destroy roll; receive stop; turn the feature Off; send a different request ID from the same character to the same target. The original delegation remains and no new admission is performed. The comment that a new request supersedes an accepted failure is not implemented for this same-character case.

**Patch direction.** Distinguish a retry belonging to an accepted roll from a genuinely new action. Preserve Inspiration and the lockpick retry UI. Confirm the exact runtime completion/closure boundary before choosing teardown events; unconditional cleanup on roll destruction would break existing retry support.

### B09 — Bonus spells can be retargeted using an unrelated retained action

**Impact.** A Guidance-like request from another roll involving the same character can be sent to the retained specialist rather than the intended character.

**Evidence.** `OnStartSpellRequest` (`NativeInteractionCoordinator.lua:1057–1155`) scans all pending actions and selects a record when a target, caster, or source matches either participant. It does not establish that the spell request belongs to that action's roll. It then rewrites initiator targets to the specialist.

After the stale record in B08, a controlled roll-bonus request with no association to the original roll was retargeted. This handler receives **roll UI bonus-spell requests**, not arbitrary world spellcasts. The audit does not claim that ordinary combat spells or healing are intercepted. Dispatching an unrelated dialogue/check bonus through this handler still needs an in-game reproduction.

**Patch direction.** Require association with the active delegated roll, and ensure retained post-roll records cannot claim unrelated bonus requests. When the association is ambiguous, preserve the original target. Verify intended Guidance retargeting still works.

### B10 — Fallback mutates a running task before checking for duplication

**Impact.** A delayed fallback can change the target of an existing lockpick and reset its progress flags.

**Evidence.** `ProcessQuickLockpick` reads the current task, calls `ConfigureStockLockpickTask`, then checks whether that lockpick task is already running (`BestOfHandsNative.cpp:1686–1751`). The configuration contains a new target/network ID and default flags, including `lockpickingStarted = 0` (`QuickLockpickState.h:19–25`).

The reproduction extracts both production functions, substitutes memory buffers for game objects, and supplies an already-running task. A request for a different target changes **target 111 to 222** and **started 1 to 0**, then returns through the duplicate check. No game routine needs to be invoked to demonstrate the mutation. The primary task-selection interception checks `alreadyRunning` before writing; this defect is in the fallback path.

**Patch direction.** Validate existing running-task ownership and target before writing. A late request must not overwrite a live task. Distinguish an already satisfied same-target request from a different-target request. Validate delayed/duplicate fallback alongside the ordinary click path.

### B11 — Stop/start events do not validate the owning character

**Impact.** An old stop event from one character can discard another character's newly armed request for the same target.

**Evidence.** `OnNativeStarted` and `OnNativeStopped` look up records only by action and target (`NativeInteractionCoordinator.lua:600–636`). They do not compare the event character to the record's initiator.

The reproduction admits character A, replaces it with character B's request for the same target, then delivers A's stop before B's roll is associated. B's record is removed. Timing determines whether the actual game delivers this sequence; the handler's ownership error is demonstrated.

**Patch direction.** Require participant ownership for lifecycle events, in addition to action/target matching. Check stale events after replacement and concurrent attempts without weakening valid stop cleanup.

### B12 — Permission rejection has no suppression cleanup

**Impact.** A failed native permission request can disable future failed-use fallback for that character/target if the game never sends `StoppedLockpicking` for the rejected action.

**Evidence.** `QuickLockpickCoordinator.lua:219–230` marks permission requests active. `OnUseFinished` at line 82 suppresses fallback unconditionally while that marker is active; its time-based grace period applies only after the marker becomes inactive. `Init.lua:153` observes `RequestProcessed` but only logs it. It does not notify either coordinator of rejection.

The controlled case marks a request active, supplies no stop event, advances time ten minutes, and still cannot admit fallback. A stop event plus the grace period restores it. **Whether a particular permission rejection emits a stop event needs a runtime trace**, so this remains conditional rather than a claim that all rejected requests cause it.

**Patch direction.** Correlate rejection/completion to its request and retire abandoned suppression safely. Cover permission rejection, missing tools, cancellation before task start, and valid native interactions that must continue suppressing duplicate fallback.

## Leads ruled out or left unproven

- **Version mismatch is not the working explanation.** The first reporter already performed a fresh reinstall. The identified mechanisms can occur with matching 2.3.1 components.
- **The shown log is not proof that the DLL failed to load.** It contains the native `waiting_for_bridge` status. That means a native component wrote status at some point; it does not prove that the status belongs to the current process or that hook validation completed. The snippet lacks the current native process/session log needed to decide which failure occurred.
- **The reported `game_version` does not establish exact native compatibility.** The diagnostic needs the executable identity and capability failure reasons from the native status/log. No exact-build or antivirus cause has been established for this reporter.
- **The deferred-entity warning is not proof that the bonus-spell observer failed.** Script Extender's [entity-event helper](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/Lua/Shared/EntityEventHelpers.inl) automatically converts one-frame component subscriptions to deferred subscriptions while emitting that warning. Deferred means the callback runs later. Timing relative to consumption remains a runtime question; the registration itself is not rejected.
- **No broad roll-ownership defect was demonstrated.** Existing tests and inspected routing preserve the initiating character and native success/failure ownership. The new lifecycle/retarget findings do not establish that all delegated rolls are incorrect.
- **No new release-pipeline defect was established in this pass.** Build/package allowlists, embedded notices, release-tag checks, and workflow guards were inspected. This was not a live release rehearsal or an exhaustive audit of all maintenance automation.
- Native object lifetime, cached bonus-presentation identity, and hook replacement/conflict recovery were inspected. No additional evidence-backed defect is promoted from those areas. A crash dump or matched runtime trace would be needed to attribute failures there.

## Verification and reproducible evidence

The production source was unchanged during this review. The retained evidence is under `artifacts/bugfix-audit-2026-10-02/`, which is ignored by Git and is local evidence rather than part of the release.

- **Existing suite:** 64 Lua tests pass; syntax checks pass for 15 Lua files and 6 YAML files.
- **Native suite:** the existing `build/native/Release/BestOfHandsNativeTests.exe` passes. It was not rebuilt in this pass.
- **Additional Lua reproductions:** six audit cases exercise the production modules, including premature/oversized warning, late acknowledgement, lost status, retained action/bonus retargeting, wrong-character stop, and abandoned suppression. The output reports 70 total passing cases. The audit cases intentionally assert the current defective behavior; their passing does not mean those bugs are fixed.
- **Native mutation reproduction:** newly compiled extracted `ProcessQuickLockpick` and `ConfigureStockLockpickTask` demonstrate the running-task target/flag overwrite. The same harness exercises the startup gate with a preexisting fresh challenge.
- **Sticky-reader reproduction:** the earlier extracted `RefreshDocument` harness was rerun: one read, 400 skipped polls after recovery, then a successful read after a timestamp change.
- Earlier release inspection extracted the published 2.3.1 package. The official ZIP SHA-256 was `8396DC28DA4EA7C3D57B0B0F41261DDE7B8A2A7EE55E0933690D87D80B0A7276`. That inspection and the current source review are separate from any installed-game identity.

The following were the audit reproduction commands against the unchanged
2.3.1 baseline. Their defective-behavior assertions are historical evidence;
use the fixed-code checks below after applying this patch:

```powershell
uv run --python 3.13 --with 'lupa==2.6' python artifacts/bugfix-audit-2026-10-02/reproduce.py
uv run --python 3.13 python artifacts/bugfix-audit-2026-10-02/generate_native_repro.py
cmd.exe /c artifacts\bugfix-audit-2026-10-02\compile-native-repro.cmd
.\artifacts\bugfix-audit-2026-10-02\native-state-repro.exe
.\artifacts\reported-issues-2026-10-01\read-retry-repro.exe
```

The native compiler script uses the Visual Studio installation present on this workstation. These reproductions simulate file reads, scheduling, and game memory; they do not measure real race frequency or replace game testing.

## Proposed patch order and release checks

1. **Make warnings safe and accurate:** B01–B02. Bound the message before any player sees it, and separate normal waiting from confirmed failure.
2. **Make file communication recoverable:** B03–B05. Test delayed startup, one failed read, exhausted polling, and stale previous-session files together. Changing one side alone can leave the other stuck.
3. **Correct live-task and action lifecycle handling:** B08–B11. Preserve valid retry behavior while isolating new requests, bonus requests, and event owners. Fix B10 before shipping fallback changes.
4. **Resolve configuration/client scope:** B06–B07. Either implement and test the required integration or state the actual limitation accurately. B07 deserves two-machine verification before claiming multiplayer support.
5. **Trace and close the rejection path:** B12. Capture whether rejection produces a stop, then add focused cleanup for the actual terminal event.

For the original startup report, the next useful diagnostic is the same run's native status and `BestOfHandsNative.log`, including process/session, executable identity, capability reasons, and handshake progression. Another reinstall would not distinguish the mechanisms in this catalog.

Before release, run focused regression checks for the implemented fixes, then test a fresh install in both supported renderers: startup; real warning dismissal; left-click and normal menu lockpicking; delegated disarm; failure/Inspiration/Try Again; bonus spells; cancel/close followed by a new request; and simultaneous characters. Add custom-profile and remote-guest cases if those fixes are included. Package and release verification should follow those product checks. No such runtime verification or patch release has been performed yet.

## Implemented follow-up: local 2.3.2 candidate, October 2

All twelve findings now have code corrections. This section records the
post-audit state; the findings and baseline reproductions above describe the
original 2.3.1 behavior. The candidate is installed locally for testing and has
not been published. Neither reporter's exact runtime failure has been
reproduced, so successful automated checks do not establish that every reported
crash is explained or eliminated.

| Finding | Implemented correction |
| --- | --- |
| B01 | Warning text is ASCII and bounded to 240 characters before calling the game's message box. Full failure reasons remain in diagnostics. |
| B02 | Native waiting states remain pending during startup. A confirmed failure or expired startup deadline can warn; ordinary waiting cannot immediately warn. |
| B03 | All three native readers record a processed timestamp only after a valid read. Failed or incomplete reads retry after bounded backoff without requiring a new timestamp. |
| B04 | Lua continues recovery checks after the fast startup budget expires and after current status disappears or loses its acknowledgement. Recovery timers are coalesced and generation-scoped. |
| B05 | Startup requires the current DLL process identifier echoed by Lua, removing dependence on worker/file ordering while rejecting old-process files. |
| B06 | Native storage reads Script Extender's `CustomProfile` setting and decodes escaped or Unicode profile names. |
| B07 | Each client starts its local native session separately. Host action metadata travels over a network channel as stable UUIDs and is resolved to guest-local handles, including updated advantage values. Guest presentation no longer requires a local host server world. |
| B08 | An accepted record is reused only for the same actor and permission-request ID. A new request retires an old failed mapping before consulting the current feature setting. |
| B09 | Bonus retargeting requires a live accepted roll and its exact initiator target. Another live roll for that actor makes the request ambiguous and prevents rewriting. Destroyed retained records cannot claim unrelated bonuses. |
| B10 | The running-task guard executes before task configuration. A delayed fallback is consumed without changing an already running lockpick's target or flags. |
| B11 | Stop/start cleanup checks actor ownership, and rejected permission cleanup also checks request identity, preserving a replacement character's action. |
| B12 | `RequestProcessed` rejection releases matching permission markers. Unstarted markers expire, allowing fallback after an abandoned request. Started actions retain their normal stop lifecycle. |

### Verification of the candidate

- The complete repository checks pass: metadata, source allowlists, Markdown
  links, Lua and YAML syntax, all **71 Lua tests**, automation policy tests, and
  workflow validation. The Lua regressions include simulated late startup,
  lost status, stale actors/requests, expired suppression, unrelated bonus
  requests, and guest mapping with different memory handles.
- A fresh native Release build and CTest pass. Native assertions cover the
  current-process startup gate, stale sessions, client-only selection, invalid
  or ambiguous client records, and custom-profile decoding.
- Newly compiled reproductions extracted from the fixed production functions
  preserve the running task's target `111` and started flag `1`, accept a fresh
  challenge that predates worker initialization, reject an old session, and
  recover from a failed read with an unchanged file timestamp (`reads=2`).
- The PAK contains exactly 19 approved files; extraction matches source
  byte-for-byte. The local ZIP's allowlist, embedded notices, PAK, DLL, and
  metadata are verified. Installed DLL and PAK hashes match those build inputs.
- Previous installed DLL and PAK, load-order file, and Script Extender settings
  are backed up under `artifacts/local-test-2.3.2/backup-20261002-153721/`.
  Installation changed only the DLL and PAK. Full identities and paths are in
  `artifacts/local-test-2.3.2/install.json`.

The final DLL SHA-256 is
`5BDBB2D4D54CE07201DB4846021DE8577CF1E744FEAC214A59B4A045920A5EE6`;
the PAK SHA-256 is
`AD9FCEF921D1311543866EE2301562F301AF09FF8D6BC7CE7432B7E8F3EE5CF9`.
The local ZIP SHA-256 is
`BFA1E1FC7A0E7FFB89E7ADA139C4659DBCC11F1D63E1D536729BDD7B6F6BF693`.

Final check output is retained in `patch-full-checks-final.txt`,
`patch-lua-final.txt`, `patch-build-final.txt`, and `patch-package-final.txt`
under the audit artifact directory. Generate the fixed native reproductions
with `uv run --python 3.13 python
artifacts/bugfix-audit-2026-10-02/verify_fixed_native.py`, compile using
`compile-native-fixed.cmd`, then run `native-state-fixed.exe` and
`read-retry-fixed.exe` from that directory. These checks simulate native memory
and file reads; they do not replace game testing.

[The short local checklist](BUGFIX-TESTING.md) was ready at installation. Actual game startup,
warning dismissal, multiplayer, and custom-profile sessions remain untested
at this point. Live testing of the deferred bonus-spell event timing also
remains necessary before claiming that edge fully verified.

### Review after the user's local test

The user reported completing the short test on October 2. The captured DX11
runtime log identifies the PAK as 2.3.2; the native log identifies the DLL as
2.3.2. Both installed hashes still match the tested package. The retained
native status is protocol 9, session `6704-4064953`, executable
`bg3_dx11.exe`, product version `4.1.1.7631656`, with quick lockpick,
delegated rolls, and client presentation all ready through the exact build
table.

The startup log's earlier partial state and `waiting_for_server_validation`
reason resolve to the final ready status. There are **zero Best of Hands Lua
or native warning/error records** in this run. One modifier callback took
7.95 ms; this isolated timing notice is not an exception or a demonstrated
recurring performance defect. Other mods and the game's UI emit their own
messages, which are not attributed to this mod or changed here. No additional
Best of Hands correction is justified by the captured run.

Evidence copies and a structured summary are retained in
`artifacts/release-prep-2.3.2/`, including `test-review.json`. Detailed action
tracing was off, so the log does not independently demonstrate every optional
checklist step. Real multiplayer, Vulkan gameplay, custom-profile gameplay,
deliberate warning dismissal, and reproduction of the external users' exact
incidents remain outside this test's coverage.

Release preparation disables local Script Extender `LogRuntime` and
`CreateConsole`. Lua `TRACE_EVENTS` remains false and native performance
diagnostics remain compiled out. Useful startup and failure diagnostics are
retained. The release ZIP contains only the PAK, DLL, and `info.json`; test
captures and local Script Extender settings are not included. See
[the release record](RELEASE-PREP.md).
