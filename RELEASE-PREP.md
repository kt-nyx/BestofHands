# Best of Hands 2.4.0 release preparation

Version 2.4.0 is the minor release after published 2.3.2. The user confirmed the
local build working on October 19, 2026 and authorized publication through the
existing GitHub Actions release workflow.

## Changes for players

- Independently choose On, Only while sneaking, or Off for left-click
  lockpicking, best-in-party lockpicking, and best-in-party trap disarming.
- Keep automatic input personal and the two party-roll choices controlled by
  the multiplayer host. Sneak-only modes check the character attempting the
  action. Accepted rolls and Inspiration retain their original behavior.
- Let normal object use, keys and story permissions run before automatic
  lockpicking. Scripted doors can keep their dialogue or cutscene behavior.
- Recover native status publication after temporary storage failures or a
  removed status file. Report missing/read-failed/invalid/mismatched status
  separately, without claiming every unavailable file means a missing DLL.
- Keep MCM descriptions to the short multiplayer scope notes.

MCM is optional and defaults all features to On. Public upgrades from 2.3.x
reset the two old party-roll checkboxes to On when MCM validates their new
selector format; README asks users to reapply Off if needed. Personal
left-click preferences are retained. Both DLL and PAK must be updated together.

## Test evidence

The captured user session was DX11, BG3 4.1.1.7631656, Script Extender 33,
native session 74260-88181500. Both native capabilities reached ready. The log
shows On lockpick delegation to Astarion, conditional automatic lockpicking
being skipped and admitted, conditional party-lockpick sharing being admitted
and skipped, Off suppressing party lockpick and disarm delegation, and canceled
rolls clearing their records with no pending requests left at those snapshots.

There were no Best of Hands Lua or native warnings/errors in the reviewed
candidate logs. The startup partial state resolved normally. Other-mod startup
errors and verbose-trace dispatch timing notices were not Best of Hands faults.
The capture does not independently establish every manual test row, a shared
trap roll, scripted-door behavior, deliberate storage-failure recovery, Vulkan,
or multiplayer. The user reported the feature working; the coding agent did
not control BG3 or run in-game tests.

Local release validation passes 77 Lua tests (including all 27 mode
combinations while standing and hiding), native Release build and CTest,
source/metadata allowlists, Lua/YAML syntax, automation/release metadata tests,
Markdown links, and workflow linting. The PAK's 19 files match source after
extraction. ZIP contents, embedded notices, metadata and archived binaries
are verified. GitHub Actions repeats release validation before publication.

## Installation, publication and cleanup

The local install preserves current modes and load order, with verified
backups outside the repository. Normal Script Extender configuration disables
CreateConsole and LogRuntime while preserving unrelated settings. Release
binaries omit verbose native tracing and performance instrumentation.

Merge the reviewed source into main, verify the merged-head CI run, then push
an annotated v2.4.0 tag. The tag workflow publishes the verified GitHub archive
and starts the existing protected nexus-production job. Publication is
explicitly authorized for this release; retain the environment approval gate.
The workflow preserves the current Nexus file description and visible older
versions, leaves changelog/release notes blank, and verifies metadata afterward.

Transient run artifacts and rollback copies are archived outside the working
repository. Only main should remain as a local branch after the release.
