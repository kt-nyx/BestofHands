# Best of Hands 2.4.0: quick manual test

The Features page has three independent selectors: Left-click lockpick,
Best-in-party lockpick, and Best-in-party disarm. Each offers **On / Only while
sneaking / Off**, with **On** as its default. The left-click mode belongs to
this computer; the two party-roll modes belong to the host in multiplayer.

Only while sneaking checks the character attempting the action, not the party
member supplying the bonuses. Hide mode is enough; being completely unseen is
not required. Standing characters still have manual Lockpick and Disarm, using
their own bonuses when the matching party-roll mode is conditional or Off.

The user confirmed the local 2.4.0 build working on October 19, 2026. The
captured DX11 session shows healthy startup and expected lockpick mode
decisions, without Best of Hands warnings or errors. It does not independently
establish every row below, multiplayer, or scripted-door coverage. No in-game
tests were run by the coding agent.

## Prepare once

1. Start BG3 with MCM and Best of Hands active. Load a room with ordinary locks
   and detected traps, then save in a separate slot for easy retries.
2. Control a character with lower Sleight of Hand than another eligible active
   party member. Carry lockpick and disarm tools, and avoid a lock you have a key for.
3. In the Script Extender **server console**, run each command separately:

   ```text
   !best_of_hands_trace on
   !best_of_hands_status
   ```

   Enable CreateConsole and LogRuntime in `bin/ScriptExtenderSettings.json`
   before launching if capturing another test. Normal local settings disable both.
4. Open **MCM -> Best of Hands -> Features**. Expect exactly three selectors,
   each with the same three choices, a reset to On, and a multiplayer scope note.

## Five-minute room check

Compare the displayed bonuses, not the random dice result. Cancel lockpick
rolls or reload your preparation save to reuse the same lock and traps.

| Set all three modes to | While standing | While in Hide mode |
| --- | --- | --- |
| On | Left-click starts lockpicking; lockpick and disarm use the best eligible party member's bonuses. | Same behavior. |
| Only while sneaking | Left-click does not start a roll. Manual Lockpick and Disarm use your selected character's own bonuses. | Left-click starts lockpicking; lockpick and disarm use the best eligible party member's bonuses. |
| Off | Left-click does not start a roll. Manual Lockpick and Disarm use your selected character's own bonuses. | Same behavior. |

Then set Left-click to On, Best-in-party lockpick to Off, and Best-in-party
disarm to Only while sneaking. A standing left-click should open a roll using
your own bonuses; a trap disarmed while hiding should use party bonuses. This
checks that the three settings are independent.

Successfully unlock one object, then click it again. It should open normally
without another lockpick roll. A brief normal Locked notice before automatic
lockpicking is expected. If a special dialogue door is already nearby, confirm
its story interaction wins; no travel is needed solely to find one.

## Persistence and active actions

- Set three different modes, close/reopen MCM, and reload the save. The choices
  should persist without duplicate selectors. Restart once if convenient.
- If the game permits changing MCM while a roll is open, change that feature's
  mode. Its current bonuses and Inspiration rerolls should remain unchanged;
  the next action must follow the new mode. Do not force UI access.
- Each reset should restore On. Reopening MCM should show the reset value.
- Optional multiplayer check: the guest controls their personal click mode,
  while both players' rolls follow the host's two party modes and the Hide
  state of the character actually attempting the action.
- Without MCM, all three modes default On even if previously configured Off.

## Finish and report

Run these commands separately:

```text
!best_of_hands_status
!best_of_hands_trace off
```

The status command reports `best_in_party_lockpick` and `best_in_party_disarm`
as On, Only while sneaking, or Off. Tell the coding agent which row failed,
the selected character and stronger party member, what happened, and roughly
when. The agent can read the local files; no upload is needed:

- Runtime logs and `BestOfHandsNative.log` in
  `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs`.
- `BestOfHandsNative.status` in the sibling `Script Extender` directory.
- Personal preference in `Script Extender\BestOfHands\ClientSettings.json`.

An ordinary room test does not establish behavior at every scripted door,
multiplayer compatibility, or recovery from an actual storage failure.
