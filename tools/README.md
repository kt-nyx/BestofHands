# Local tools

This directory is reserved for untracked development tools.

For CLI packaging, extract a current [LSLib ExportTool release](https://github.com/Norbyte/lslib/releases) so that one of these paths exists:

```text
tools/ExportTool/Packed/Tools/Divine.exe
tools/ExportTool/Tools/Divine.exe
tools/Divine.exe
```

The build script also accepts `-DivinePath` or the `DIVINE_PATH` environment variable. Tool binaries are intentionally excluded from version control.

Pinned/tested versions and the game/API baseline are recorded in `tool-versions.json`. The current LSLib archive is `ExportTool-v1.20.4.zip`, whose upstream SHA-256 is:

```text
5e02368fb8acafda9b45acba37a3f3bf507fc3d65a083a159abbeab06337190e
```

The CI workflow downloads this archive directly from the official Norbyte/lslib GitHub release, verifies that hash, and does not commit or redistribute the tool.
