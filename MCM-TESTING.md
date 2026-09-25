# MCM integration: manual test

This change adds three independent toggles. Left-click lockpick belongs to
each client; the host's two best-in-party settings control rolls for everyone.
All start enabled, and MCM is optional. The checks below require you to run BG3;
automated checks do not establish that the in-game menu or multiplayer works.

On 2026-09-25, the maintainer confirmed that all settings combinations worked
and subsequently approved the reset-button and description polish. No live
tests were performed by the coding agent. This checklist remains available for
future regression testing; that confirmation does not separately establish
testing on every renderer or in multiplayer.

## Install the test build

1. Exit BG3 completely.
2. Back up your currently installed `BestofHands.pak` and `BestofHands.dll`.
3. Import the ZIP produced in `dist` with BG3 Mod Manager, keep Best of Hands
   active, and export the load order. Copy the ZIP's `bin` folder into the BG3
   installation as with a normal update. For version 2.3.0, the archive is
   `BestofHands-v2.3.0.zip` and replaces both installed mod files.
4. For the MCM checks, install a current MCM version and export the load order.
5. Load a save near a locked container/door and a detected trap. Use a character
   whose Sleight of Hand is noticeably lower than another eligible active-party
   member's. Have lockpick and trap-disarm tools available. Avoid a matching key
   for the lock being tested. Save in a separate slot so you can repeat checks.

## Check the controls and defaults

Open MCM, choose **Best of Hands → Features**, and check that there are exactly
three checkboxes on this single page, with plain setting names and a short
multiplayer note at the end of each description. All descriptions should use
the same faded-white style. Disable left-click lockpick: its reset icon should
appear next to the title. Click it and confirm the checkbox turns On, the icon
disappears, and the preference remains On after restarting. Close and reopen MCM,
then reload the save and verify that no duplicate controls appear. With untouched settings,
all must be checked. Left-click a locked target: it should open the normal roll
using the best eligible party member's modifiers. Disarm the trap and confirm
the same selection of modifiers.

Use the following table to check each combination. Reload the preparation save
as needed. If left-click is Off, use the context-menu **Lockpick** action to check
the roll. Compare modifiers, not the random dice result.

| Left-click | Party lockpick | Party disarm | Lockpick modifiers | Disarm modifiers |
| --- | --- | --- | --- | --- |
| On | On | On | Best eligible party member | Best eligible party member |
| Off | On | On | Best eligible party member | Best eligible party member |
| On | Off | On | Initiating character | Best eligible party member |
| On | On | Off | Best eligible party member | Initiating character |
| Off | Off | On | Initiating character | Best eligible party member |
| Off | On | Off | Best eligible party member | Initiating character |
| On | Off | Off | Initiating character | Initiating character |
| Off | Off | Off | Initiating character | Initiating character |

When left-click is Off, an ordinary click must keep vanilla locked-object behavior
and must not start a delayed fallback roll. Context-menu Lockpick must still work.
Turn it On again and verify the next click works without restarting. A matching
key should still open its lock normally with either setting.

## Persistence and active rolls

1. Set different values for lockpick and disarm, then reload the save and restart
   BG3. Both choices should persist. Your personal left-click choice should also
   persist on that computer.
2. Reset a party-roll setting in MCM, and optionally change MCM profiles. The next
   action should use the new host setting. The personal left-click preference
   should be unchanged by profile changes; check its checkbox to restore On.
3. Start a delegated roll, then change its party-roll toggle to Off while the
   roll is open **if MCM can be opened at that point**. The existing modifier
   profile must remain unchanged. If you fail and use Inspiration, the reroll
   must also retain it. A new action after finishing/canceling must use the
   initiating character. Also check the reverse, turning On during a vanilla
   roll: only the next action should use the specialist. Do not force UI access
   with console commands if the game will not let you open MCM there.

## Without MCM

Exit BG3, disable MCM in the mod manager, and export the load order. Leave Best
of Hands enabled and load a test save that does not require other MCM-dependent
mods. All three features must work again, **even if they were previously Off**.
Re-enable MCM afterward; previous explicit preferences may return.

## Multiplayer

Use the same test build on the host and guest. The decisive check needs two
clients; a solo session cannot verify it.

1. Set left-click Off on the guest and On on the host. Each should get their own
   click behavior. Swap the choices and check again. The guest must be able to
   edit **Left-click lockpick** while MCM's host-only mode is enabled.
2. On the host, set party lockpick Off and party disarm On. Actions initiated by
   **either** player should use their own lockpick modifiers and the best eligible
   party member's disarm modifiers. Swap the two settings and repeat. Normal
   active-party eligibility still applies.
3. Reconnect the guest. Their personal click choice must survive, and rolls must
   still follow the host's settings. MCM's normal host-only mode controls edits
   to shared party-roll settings; disabling that mode deliberately lets guests
   edit the host's shared configuration too.

## Report the result

Please report whether the menu appeared, which row/action failed (if any),
expected versus displayed modifiers, and whether it was solo, host, or guest.
For party-roll settings, the Script Extender **server** console command
`!best_of_hands_status` reports `best_in_party_lockpick` and
`best_in_party_disarm` as `1` (On) or `0` (Off).

Your personal preference is stored in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\BestOfHands\ClientSettings.json`.
Menu errors are logged to the Script Extender console with the `best_of_hands`
prefix. Existing native diagnostics remain in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\BestOfHandsNative.log`.
