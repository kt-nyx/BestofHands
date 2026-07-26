# Best of Hands - Quick Lockpick & Disarm

![Best of Hands](https://staticdelivery.nexusmods.com/mods/3474/images/23881/23881-1784097647-418941884.png)

Tired of switching to Astarion whenever you find a chest?

Does your soul burn with the fires of Avernus every time you have to click *twice* to pick a lock?

Now you can leave it in the ***Best of Hands***.

## Description

Best of Hands is a focused QoL mod for lockpicking and trap disarming:

- Left-clicking a locked door or container starts its ordinary lockpick action automatically.
- Lockpick and disarm checks use the complete native modifier profile of the eligible active-party character with the **highest Sleight of Hand**.

If your party has the key for a door or chest, the key is still used instead of starting a lockpick.

The character who starts the interaction remains responsible for movement, visibility, ownership, permission, and crime. The selected specialist supplies the roll profile only. The initiator's bonuses are not added to it.

Version 2 turns a failed ordinary left-click on a lock into BG3's own reusable client lockpick task, then uses BG3's original action and roll pipelines. This preserves movement to the target, permissions, keys, one visible roll, Inspiration retries, lockpick **Try Again**, trap activation on failure, success callbacks, and ordinary tool consumption. The mod does not copy a hand-picked list of bonuses, so equipment, statuses, advantage, consumables, and mod-added native roll modifiers can participate normally. Context-menu lockpicking remains available and enters the same pipeline.

For delegated advantage or disadvantage, the native plugin supplies the specialist's aggregate roll mode at BG3's own active-roll viewmodel boundary and retains that local presentation value through the click-to-roll transition. BG3 still constructs the dice, modifier rows, and animations; the mod does not replace the roll UI or change replicated gameplay state.

Bonuses selected from the roll UI use the normal caster and initiator-based availability/range check, then apply their effect to the specialist's delegated profile. If the party has no appropriate thieves' tools or trap disarm toolkit, Best of Hands blocks the roll and uses BG3's native non-modal error notification.

This mod affects only lockpicking and trap disarming. It does not share best-in-party skills for dialogue or other checks, change the DC, create tools, make tools reusable, bypass the roll, or force success.

## Requirements

- [BG3 Script Extender](https://github.com/Norbyte/bg3se/releases/latest), API v29 or newer
- [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944)

Both are required for version 2. If the native DLL is missing, incompatible, or invalidated by a game update, Best of Hands disables its delegation behavior for that session and displays an in-game warning. The original unmodified lockpick/disarm behavior remains available.

## Installation

The download contains both parts of the mod:

```text
BestofHands.pak
THIRD_PARTY_NOTICES.txt
bin\NativeMods\BestOfHandsNative.dll
```

Install BG3 Script Extender and Native Mod Loader first, then:

1. Import `BestofHands.zip` into BG3 Mod Manager, move *Best of Hands - Quick Lockpick & Disarm* to Active Mods, and export the load order.
2. Open the same ZIP and copy `bin\NativeMods\BestOfHandsNative.dll` to your game's `Baldurs Gate 3\bin\NativeMods` folder.
3. Start or reload a game. A visible warning means the native half did not load correctly.

BG3 Mod Manager handles the PAK but should not be assumed to install the DLL. Vortex users may install and deploy the combined archive normally, then confirm that the DLL reached the folder above and that the PAK is active.

## Compatibility

Best of Hands leaves BG3's native permission, task, roll, result, and resource paths in control. Mods that merely observe those paths should therefore continue to receive one normal action and one normal result. Mods that directly replace lockpick/disarm behavior or alter all ability checks may conflict.

Party-limit mods are supported: the specialist may be any eligible character in the initiator's active party and loaded region. The initiator wins a tie.

Compatibility with [Eternal Lockpick](https://www.nexusmods.com/baldursgate3/mods/15080) and [Eternal Trap Disarm Kit](https://www.nexusmods.com/baldursgate3/mods/15085) is deliberately deferred until the native v2 path is validated. Best of Hands does not reproduce, create, remove, consolidate, or regrant their items. Formal support should be added on top of the stable native event path so those mods continue to own their behavior.

## Game updates

The DLL supports only executable builds whose native layouts were validated. A BG3 patch may require an updated Best of Hands DLL even when the PAK still loads. An unknown build is not patched: the mod warns once and leaves vanilla behavior untouched.

## Uninstallation

Finish or cancel any active lockpick/disarm roll, exit the game, deactivate the PAK, and remove `BestOfHandsNative.dll` from `Baldurs Gate 3\bin\NativeMods`. Best of Hands adds no items, spells, passives, statuses, world objects, or permanent character bonuses.

For an extra check before removal, enable the Script Extender console and run `!best_of_hands_status`. An idle session reports `pending_delegations=0` and `legacy_assistance_cleanup=0`.

## Why not the other mods?

Other mods solve related problems with different scopes and tradeoffs, including [Auto Lockpicking](https://www.nexusmods.com/baldursgate3/mods/6188), [Use Best Sleight of Hand](https://www.nexusmods.com/baldursgate3/mods/5036), and [Best in Party Skills](https://www.nexusmods.com/baldursgate3/mods/20091). Best of Hands is intentionally limited to locks and traps while keeping the initiating character's world interaction intact.

## Thanks <3

Thank you to the following authors and projects, which inspired or informed Best of Hands:

- [BG3 Script Extender](https://www.nexusmods.com/baldursgate3/mods/2172) by Norbyte
- [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944) by ShinyHobo
- [SafetyHook](https://github.com/cursey/safetyhook) by cursey
- [Zydis](https://github.com/zyantific/zydis) by zyantific
- [Auto Lockpicking](https://www.nexusmods.com/baldursgate3/mods/6188) by Volitio
- [Use Best Sleight of Hand](https://www.nexusmods.com/baldursgate3/mods/5036) by JonHinkerton
- [Best in Party Skills](https://www.nexusmods.com/baldursgate3/mods/20091) by imCioco
- [Eternal Lockpick](https://www.nexusmods.com/baldursgate3/mods/15080) by SwissFred
- [Eternal Trap Disarm Kit](https://www.nexusmods.com/baldursgate3/mods/15085) by SwissFred

## License

Best of Hands is released under [The Unlicense](https://unlicense.org/). You may copy, modify, fork, redistribute, sell, relicense, or incorporate it without permission or credit. You do not need to publish source, use the same license, or notify the author.
