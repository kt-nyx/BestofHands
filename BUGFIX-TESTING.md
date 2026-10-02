# Local test: Best of Hands 2.3.2

This is an unpublished bugfix candidate addressing the twelve findings in
[the audit](BUGFIX-AUDIT.md). The automated checks pass; the game test below
checks that your installed build starts and performs ordinary interactions.

## Completed test

On October 2, the user reported completing this short test. Review of the
DX11 run confirmed version 2.3.2, both native capabilities ready, and no Best
of Hands warnings or errors. The native session was `6704-4064953` on BG3
`4.1.1.7631656`. The log contains one 7.95 ms modifier callback timing notice
without a failure. Individual checklist steps were not traced, so the log does
not independently prove every optional step ran.

Full Script Extender runtime logging and its automatic console window have
now been disabled locally. Mod tracing is off by default and native performance
diagnostics are compiled out. Normal startup diagnostics and useful warnings
or errors remain available. See [release preparation](RELEASE-PREP.md).

## Quick check, about two to three minutes

1. Start BG3 and load an existing save with Astarion, or another character
   better at lockpicking than your selected character, in the party. Wait
   about ten seconds. There should be no feature warning or crash.
2. With the weaker character selected, left-click a locked chest or door.
   Confirm that the lockpick roll opens and shows the better character's
   bonuses. Add Guidance if it is readily available. Cancel, click the same
   object again, and finish that attempt. If it fails, use Try Again once.
3. Reload the save and try left-clicking the object once more. Disarm a trap
   too if one is already nearby; there is no need to search for one.

Report whether startup, clicking, bonuses, and retry/reload worked, plus any
warning or crash. No console commands are needed for the ordinary check. The
native status and log can be read directly afterward; full Script Extender
runtime logging would need enabling again for another detailed capture.

## Installed files and rollback

The DLL goes in the game's `bin/NativeMods/BestofHands.dll`; the PAK goes in
your BG3 `Mods/BestofHands.pak`. The installer records their full paths,
SHA-256 hashes (file fingerprints), and backup location in
`artifacts/local-test-2.3.2/install.json`. Previous installed files are retained
in that backup directory. Close BG3 before restoring either file.

## Limits of this check

The automated tests cover delayed startup, loss and recovery of file
communication, bounded warnings, action lifecycle cleanup, custom-profile
decoding, and simulated guest-client mapping with different local handles.
They do not reproduce either reporter's real game crash. Real multiplayer,
Vulkan gameplay, custom-profile sessions, and deliberate feature-warning
dismissal remain untested. The completed short DX11 check does not establish
those release claims.
