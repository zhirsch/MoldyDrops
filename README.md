# MoldyDrops

A World of Warcraft: Forever addon that shows a mob's most likely drops, with drop rates, in its tooltip. It records the loot you get, and you can share it through a community website (planned) by copying and pasting strings.

## Install

Copy the `MoldyDrops` folder into `World of Warcraft\_forever_\Interface\AddOns\`. Use whatever folder your client uses for WoW Forever addons.

## Commands

| Command | What it does |
|---|---|
| `/drops search <mob name>` | Opens a window that finds mobs by name and shows their drops |
| `/drops export` | Opens a window with your recorded loot as a string to upload |
| `/drops import` | Opens a window to paste community data from the website |
| `/drops stats` | Prints the state of the database |
| `/drops tooltip` | Turns the tooltip on or off |
| `/drops instances` | Also shows the tooltip in dungeons and raids (off by default) |
| `/drops reset` | Deletes the loot you've recorded |

All grey (poor quality) items share one "Grey items" row. Hold **Shift** to list them individually, in the tooltip or the search window.

## Where the numbers come from

For each mob, the addon uses the first of these that applies:

1. **Observed rates:** the community snapshot or your own recordings, whichever has more kills, once it covers at least 20 kills.
2. **1.12 estimate:** drop chances from the [CMaNGOS classic-db](https://github.com/cmangos/classic-db) loot tables, bundled in `BaseData.lua`. These come from the original game, not WoW Forever, and don't include new WoW Forever mobs.
3. **Small sample:** observed data with fewer than 20 kills, labeled as such.

Recording rules, which keep the rates unbiased:
- It records only while you're solo, because in a group other people loot corpses you never see.
- A kill counts when you loot the corpse, or when a mob you were fighting dies and its corpse turns out to be empty. Corpses you skip aren't counted.
- WoW Forever doesn't let addons read the combat log, so deaths are spotted through your target, focus, mouseover and enemy nameplates. Turn on enemy nameplates (default key: V) so empty corpses of mobs you weren't targeting are counted too.
- Pick pocketing, skinning, gathering and fishing are ignored.

## Rebuilding the 1.12 data

Download `ClassicDB_1_12_1_*.sql.gz` from [classic-db/Full_DB](https://github.com/cmangos/classic-db/tree/master/Full_DB), then run:

```powershell
.\tools\Build-BaseData.ps1 -Dump path\to\ClassicDB_1_12_1_z2815.sql.gz
```

## Tests

`tests/harness.lua` runs the addon's logic against stand-ins for the WoW API, using [Fengari](https://fengari.io) (Lua in the browser). To run it:

1. Run `tests\build.ps1` to build `tests\index.html`.
2. Run `tests\serve.ps1` to serve it at http://localhost:8765/.
3. Open that page.

The window and frame code (`ExportUI.lua`, the UI half of `Search.lua`) isn't covered; check it in the game.

## Docs

- [docs/exchange-format.md](docs/exchange-format.md) specifies the `!MD1!` export and import strings.
- [docs/website-plan.md](docs/website-plan.md) plans the community website.

## License

MoldyDrops is licensed under the [GNU General Public License v3.0](LICENSE).

`MoldyDrops/BaseData.lua` is generated from the [CMaNGOS classic-db](https://github.com/cmangos/classic-db) loot tables, which are also GPL-3.0. World of Warcraft names and game data are trademarks and copyrights of Blizzard Entertainment. This project isn't affiliated with Blizzard or CMaNGOS.
