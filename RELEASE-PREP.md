# Best of Hands 2.3.2 release preparation

The bugfix candidate is packaged and has passed the user's short local DX11
test. Its logs show that both native features became ready, with no Best of
Hands warnings or errors. Publication was authorized on October 2 through the
existing GitHub Actions release workflow.

## Changes for players

- Prevent a normal startup delay from immediately showing a feature-failure
  warning. Shorten and bound genuine warnings so they fit BG3's message box.
- Recover after delayed startup or a failed communication-file read, including
  cases that previously left features disabled for the session.
- Remove a startup-order dependency and use the configured Script Extender
  profile folder for native communication.
- Provide remote clients with their own native startup exchange and host
  action data mapped to each computer's local entities.
- Keep new attempts separate from retained failed rolls, prevent unrelated
  roll bonuses from being redirected, and protect an active lockpick from a
  delayed fallback.
- Keep old-character events and rejected or abandoned permission requests from
  clearing or blocking a later action.

The detailed findings, evidence, and correction record are in
[the audit](BUGFIX-AUDIT.md).

## Package and validation

The local release artifact is `dist/BestofHands-v2.3.2.zip`, with its checksum
in `dist/BestofHands-v2.3.2.zip.sha256`. It contains exactly:

- `BestofHands.pak`
- `bin/NativeMods/BestofHands.dll`
- `info.json`

Archive SHA-256 (its file fingerprint):
`BFA1E1FC7A0E7FFB89E7ADA139C4659DBCC11F1D63E1D536729BDD7B6F6BF693`.
The installed DLL and PAK match those archived build inputs. The source uses
version 2.3.2 and communication protocol 9, so both halves must be updated
together.

Repository validation passes all 71 Lua tests, syntax checks, workflow and
automation checks, and native CTest. The PAK's 19 approved files match source
after extraction. The archive's contents, embedded notices, metadata, and
binary files have been verified. Retained evidence is under
`artifacts/bugfix-audit-2026-10-02/` and
`artifacts/release-prep-2.3.2/`.

## Normal logging

Lua tracing defaults to off, and the native Release build excludes verbose
trace and performance payloads. Ordinary startup state and useful failure
diagnostics remain enabled. Local Script Extender settings now have
`CreateConsole: false` and `LogRuntime: false`, disabling the automatic console
and full runtime capture on the next launch. These machine settings are not
shipped in the ZIP. Their previous values are backed up alongside the test
evidence.

## Coverage and publication

The user reported completing [the short checklist](BUGFIX-TESTING.md). The
captured run verifies startup on DX11 with BG3 `4.1.1.7631656`, Script Extender
32, and native session `6704-4064953`. Detailed per-action tracing was off;
individual optional steps are not independently established by the log.
Remote multiplayer and custom-profile behavior have simulated regression
coverage, but no live sessions were run. Vulkan gameplay, deliberate warning
dismissal, and the external users' exact failures also remain unverified.

Use the existing release workflow when publication is authorized: merge the
reviewed source into `main`, wait for its CI checks, then tag that clean commit
`v2.3.2`. A pushed tag publishes the GitHub release and starts the protected
Nexus upload. The existing `nexus-production` approval gate remains in place.
The workflow copies the current main file's raw BBCode description, including
formatting tags, keeps the previous
version visible as an old version, and leaves the Nexus changelog and GitHub
release notes blank. Its post-upload check verifies these metadata outcomes.
Do not describe the untested scenarios above as confirmed runtime results.

## Published v2.3.2

Published through release run `37059905039` at tag commit
`e5a5b95a760681149c5aeef5ad50152e24b74308`. GitHub and Nexus uploads succeeded.
The published ZIP SHA-256 is
`E8FD60C834482D958923FDE65A8C6C38C2ABF7730D3BDD5AE12E21239A5D35DC`.
Nexus global version ID is `14920716518244` (game-scoped file `131940`).

The original post-upload check failed because API v1 returned the same breaks
as `&lt;br /&gt;` for the new upload instead of `<br />` for the legacy source.
The public page renders both descriptions identically, including red, bold,
and paragraph breaks. Protected read-only run `37061439639` retrieved both
API descriptions and confirmed v2.3.2 is main, v2.3.1 is `old_version`, and
the new changelog is null. A focused correction normalizes only line breaks
before upload and comparison, retaining the BBCode tags. The published file
and release tag were preserved; no second package was uploaded.
