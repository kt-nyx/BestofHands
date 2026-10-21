# Best of Hands 2.4.1 release preparation

Version 2.4.1 is a performance and menu-layout patch after published 2.4.0.
The player tested the optimized build, reported that everything worked and the
click-to-roll delay had disappeared, then confirmed the revised MCM layout.
On October 21, 2026, they authorized merging, cleanup, publication through the
existing GitHub Actions workflow, and installation with the version increment.

## Changes for players

- Reduced background CPU usage while exploring.
- Improved responsiveness when starting lockpick and disarm rolls.
- Tidied the MCM settings layout and spacing.

All three independent feature modes, optional MCM, personal and host settings,
tool compatibility, stock/story interactions, Inspiration and cleanup remain.
Both DLL and PAK must be updated together. Protocol 9 is unchanged.

## Performance and functionality evidence

The original worker repeatedly asked Windows to describe game memory regions
through `VirtualQuery`. Aggregate timings attributed most of its CPU cost to
the server-world preflight, with file polling a smaller secondary contributor.
In focused DX11 gameplay at the same Jannath's Estate save, matched 29.3-second
windows measured 53.3296% of one logical CPU before and 0.0533% after the first
optimization pass. An 87-second optimized focused window recorded 0.0180%.
Windows CPU accounting has limited resolution; this establishes negligible
measured worker cost, not mathematical zero or a quantified FPS gain.

Stable optimized intervals recorded no bridge reads, timestamp checks, status
writes, refresh-lock attempts or memory-region queries. The remaining short
world and hook-slot observations took about 0.44 milliseconds per ten seconds.
Game-update wrapper overhead averaged 58.37 microseconds before and 0.17 after,
excluding the original game update. Action, startup and recovery work still runs
when needed. Detailed architecture and boundaries are in [DEVELOPMENT.md](DEVELOPMENT.md).

The subsequent pass reduces repeated roll reads, unnecessary action-file reads,
full client roll scans and unchanged writes. The player later confirmed the
combined build working and reported the disappearing delay. These observations
are distinct from the earlier matched CPU measurements; no new FPS percentage
or second-pass CPU comparison is claimed.

The first-pass functional capture covered lockpick and disarm profiles,
specialist bonuses, Inspiration and a save/session transition, followed by
empty action records and both capabilities ready, without Best of Hands native
warnings or errors. Fresh Vulkan, multiplayer, MCM-absent gameplay and prolonged
recovery testing are not independently established by this release session.
The coding agent did not launch or control BG3 for this release.

## Release checks and installation

Release validation includes 86 Lua tests, native Release CTest with assertions,
real directory-notification and guarded-read tests, source/metadata allowlists,
Lua/YAML syntax, release automation tests, Markdown links and workflow linting.
The build verifies all 19 extracted PAK files against source; packaging verifies
the ZIP contents, embedded notices and archived binaries. GitHub Actions repeats
validation before publication. Test output and rollback copies are kept in the
maintainer's dated archive outside the checkout.

Verbose native tracing and performance instrumentation are disabled in normal
builds; build checks reject their enable/output markers. Lua tracing defaults
off. Bounded startup/state-change notices and actionable errors remain for
recovery and support, without periodic gameplay logging.

The local install uses the incremented PAK and DLL and preserves saved feature
settings and load order. Merge the reviewed source into main, verify merged-head
CI, then push the annotated v2.4.1 tag. The tag workflow creates the GitHub
release and publishes through the protected `nexus-production` environment.
Retain that approval gate and preserve the current Nexus download instructions
and visible older versions. The official upload action does not expose a
changelog input; a Nexus page changelog requires signed-in editor access.
The short player-facing notes are in [CHANGELOG.md](CHANGELOG.md).

Only main should remain as a local branch after the release; retain branches
with unmerged work and all release tags.
