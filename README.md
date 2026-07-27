<p align="center"><strong>Tired of switching to Astarion whenever you find a chest?</strong></p>
<p align="center"><strong>Does your soul burn with the fires of Avernus every time you have to click <u><em>twice</em></u> to pick a lock?</strong></p>
<p align="center"><strong>Now you can leave it in the <em>Best of Hands</em>.</strong></p>

---

## Description

Best of Hands is a simple, focused QoL mod for lockpicking and trap disarming:

- Simply **left-click any locked chest or door** and you will attempt a lockpick. *No more lockpicking from the dropdown menu!*
- Every lockpick and disarm check will now roll using the stats of the character in your party with the **highest modifiers**. *No more switching to Astarion just to open a box!*

If your party has the key for the door or chest, **the key will still be used** rather than starting the lockpick.

Visibility and crime permission remain attached to the character who initiates the lockpick/disarm. So if they see you trying to steal, ***you still get caught*** (not Astarion, even though he does the roll).

This mod *only* affects lockpicking and trap disarming. It does *not* share best-in-party skills for dialogue or any other ability checks. It does *not* change the target DC, create extra thief/trap tools, let you fail the check without using tools, bypass the roll, or force success. In other words, you won't feel like you're cheating.

The party member with highest modifiers is calculated when you start the roll so that you always use the best roller. For example, if Astarion has +3 from Dex and +3 from Sleight of Hand proficiency (total +6), but Shadowheart has a temporary total of +8 from Bardic Inspiration, Shadowheart's modifiers will be used for the roll.

---

## Requirements

- [BG3 Script Extender](https://github.com/Norbyte/bg3se/releases/latest)
- [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944)

---

## Installation

**Before you do anything, install [BG3 Script Extender](https://github.com/Norbyte/bg3se/releases/latest) and [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944).**

**And use [BG3 Mod Manager](https://github.com/LaughingLeader/BG3ModManager/releases/latest) ya animal!**

1. Download this mod manually.
2. In BG3 Mod Manager, select **File > Import Mod** and choose the downloaded `BestofHands.zip`.
3. Move *Best of Hands - Quick Lockpick & Disarm* to the **Active Mods** side.
4. Export the load order to the game.
5. Navigate to your game folder (typically `C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3` for Steam installs).
6. Open the downloaded `BestofHands.zip`.
7. Drag the **bin** folder from the ZIP file into your game folder.
8. Profit!

### [Manual Install (for my freaks <3)](https://bg3.wiki/wiki/Modding:Installing_mods#Manually)

---

## Compatibility

Best of Hands should be compatible with pretty much everything, so long as it doesn't overlap directly with lockpick/disarm behaviour (e.g. [Auto Lockpicking](https://www.nexusmods.com/baldursgate3/mods/6188), [Use Best Sleight of Hand](https://www.nexusmods.com/baldursgate3/mods/5036)) or mods that alter *all* ability checks (e.g. [Best in Party Skills](https://www.nexusmods.com/baldursgate3/mods/20091)).

It works with party limit mods; so long as the character you want for lockpick/disarm checks is *in your active party*, their stats will be used for the roll.

---

## Uninstallation

Best of Hands should be safe to remove from an existing playthrough. It doesn't add items, spells, passives, statuses, world objects, permanent character bonuses, etc. so removing it should just stop the new lockpick/disarm script from running.

If you want to be *super* safe though:

1. Finish or cancel every active lockpick or trap-disarm roll.
2. [Enable and open the Script Extender server console](https://www.nexusmods.com/baldursgate3/articles/169) and run `!best_of_hands_status`. Confirm `pending_delegations=0` and `legacy_assistance_cleanup=0`. This guarantees the active part of the script is not running.
3. Make a new manual save in a new slot, then exit the game completely.
4. Disable Best of Hands in your preferred mod manager (or delete the PAK from your BG3 AppData folder and manually remove it from your load order, if you're a freak <3).
5. Delete `BestofHands.dll` from `[BG3 game folder]\bin\NativeMods`.
6. Export the updated load order, launch BG3, and load the new save.
7. ...un-profit?

---

## Why Not The *Other* Mods?

Other mods have fixed these issues separately before, namely [Auto Lockpicking](https://www.nexusmods.com/baldursgate3/mods/6188) and [Use Best Sleight of Hand](https://www.nexusmods.com/baldursgate3/mods/5036), but:

- *Auto Lockpicking*'s implementation is, in Volitio's own words, "shitty" (sorry) and works very inconsistently, or not at all for some people (me) on the latest patch.
- *Use Best Sleight of Hand* currently crashes my game, and before it crashes it sometimes stacks the ability modifiers from both my own character and the character with the highest Sleight of Hand. This makes me feel like I'm cheating and that makes me sad. :(

[Best in Party Skills](https://www.nexusmods.com/baldursgate3/mods/20091) also technically works, but it mandatorily uses the best-in-party rolls for dialogue checks, which also makes me feel like I'm cheating and also makes me sad. :(

It's up to you what you use, but this is why I initially created this mod for my own playthrough.

---

## Thanks <3

Thank you so much to the following mod authors for making these mods, which inspired and informed the development of Best of Hands:

- [BG3 Script Extender](https://www.nexusmods.com/baldursgate3/mods/2172) by the marvelous Norbyte
- [Native Mod Loader](https://www.nexusmods.com/baldursgate3/mods/944) by the glorious dukethedropkicker
- [Auto Lockpicking](https://www.nexusmods.com/baldursgate3/mods/6188) by Volitio
- [Use Best Sleight of Hand](https://www.nexusmods.com/baldursgate3/mods/5036) by JonHinkerton
- [Best in Party Skills](https://www.nexusmods.com/baldursgate3/mods/20091) by imCioco

---

## [GitHub Repo](https://github.com/kt-nyx/BestofHands)

---

## License

Best of Hands is released under [The Unlicense](https://unlicense.org/). You may copy, modify, fork, redistribute, sell, relicense, or incorporate it without permission or credit. You do not need to publish source, use the same license, or notify the author.
