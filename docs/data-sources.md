# Data sources

MoldyDrops itself only shows drop chances: in tooltips, the search windows and luck tags on loot messages. The numbers come from **data sources** that register with MoldyDrops. Three come with it, one built in and two as separate addons:

| Addon | Source | Kind |
|---|---|---|
| `MoldyDrops` (built in) | Your loot (`recorded`): what you loot, skin, gather and pick pocket, while **Record my loot** is on | recorded |
| `MoldyDrops_Community` ([own repository](https://github.com/zhirsch/MoldyDrops_Community)) | Community data (`community`): the website's snapshot, bundled with each release, or a newer one from `/drops import` | recorded |
| `MoldyDrops_112` | 1.12 estimates (`1.12`): CMaNGOS data from the original game | estimate |

Each source can be turned off in the options (Data sources). The built-in one registers through the same interface, and any other addon can add a source the same way.

## How a source is chosen

For each mob, and separately for its gathering and pick pocketing, the tooltip shows **one** source's numbers, never a mix. Your uploads are already part of the community numbers, so adding sources together would count the same kills twice. Among the sources that are turned on:

1. The **recorded** source (`observed = true`) with the most samples, once it has at least `MoldyDrops.MIN_SAMPLE` (20).
2. Otherwise the first **estimate** source (`observed = false`) that has the mob.
3. Otherwise whatever recorded data exists, marked as a small sample ("you, only 4 kills").

Stack counts (x1-2) come from recorded sources first, the one with most samples first, then from estimates. Names, levels and models come from every installed source, even ones turned off, in `order`. If none of them knows an item's name, the game client is asked.

## Registering a source

Add `## Dependencies: MoldyDrops` to your `.toc`, then, in a Lua file:

```lua
local source = {
  id = "mysite",            -- required, unique: letters, digits, _ - .
  name = "My site's data",  -- the options toggle
  label = "mysite",         -- the tooltip's note: "mysite, 120 kills"
  description = "...",      -- the toggle's tooltip
  observed = true,          -- true: counted kills; false: estimates
  order = 50,               -- lower comes first (bundled: recorded 10, community 20, 1.12 30)
  options = { ... },        -- optional AceConfig args shown under the toggle
}

function source:Drops(npcID)
  return { samples = 120, items = { [2589] = 35.5, [4306] = 12 }, grey = 40 }
end

MoldyDrops.RegisterSource(source)
```

Every method is optional and called with a colon (`source:Drops(npcID)`). A method that errors is reported once and treated as "no data", so a broken source can't break the tooltip.

### Data methods

These return an **entry**, or nil if the source has nothing. MoldyDrops caches entries. Call `MoldyDrops.DataChanged()` whenever your data changes.

| Method | Key | What |
|---|---|---|
| `Drops(npcID)` | NPC ID | The corpse's loot |
| `Gather(npcID)` | NPC ID | Skinning, herbalism, mining or engineering the corpse (`kind` 1-4) |
| `Pick(npcID)` | NPC ID | Pick pocketing |
| `Quest(npcID)` | NPC ID | Items that only drop while a quest needs them (see `QuestsFor`) |
| `Contents(itemID)` | container item ID | What's inside a container, per container opened |

An entry:

```lua
{
  samples = 120,      -- kills (corpses gathered, mobs pick pocketed) counted; recorded sources only
  items = { [itemID] = percent, ... },  -- chance per kill, 0-100
  greys = { [itemID] = percent },  -- optional: items listed under the "Grey items" row
                                   -- (items the game calls poor quality go there too)
  grey = 35.8,        -- optional: chance of at least one grey item (otherwise estimated)
  noItems = 51.3,     -- optional (Drops): chance of a corpse with no items
  gold = { min, max, avg },  -- optional (Drops), copper; avg defaults to the midpoint
  qty = { [itemID] = { min, max } },  -- optional: how many come at once
  counts = { [itemID] = { [count] = times } },  -- optional: how often exactly that many came
  kind = 1,           -- Gather only: 1 skinning, 2 herbalism, 3 mining, 4 engineering
}
```

Quest items are left out of `items` lists (except in `Quest`). A source can decide which items count as quest items with `IsQuestItem`.

Counted records in the `!MD1!` exchange format turn into entries with `MoldyDrops.Codec.Rates(record)`. See `Codec.lua`.

### Other methods

| Method | Returns |
|---|---|
| `ItemInfo(itemID)` | name, quality |
| `MobInfo(npcID)` | name, min level, max level, model display ID (any may be nil) |
| `IsQuestItem(itemID)` | true (quest-only drop), false (drops for everyone), or nil (don't know) |
| `QuestsFor(itemID)` | `{ questID, ... }`: the quests a `Quest` item is for |
| `Npcs(section)` | a table whose keys are NPC IDs, for `"drop"`, `"gather"`, `"pick"`, `"quest"`, or `"mob"` (NPCs you can name). Used by the search windows. |
| `Stats()` | `{ "line", ... }` for `/drops stats` |
| `Import(snapshot, items, mobs)` | takes a parsed website snapshot (from `/drops import`), returns true if it did |

## The MoldyDrops API

| Function | |
|---|---|
| `RegisterSource(source)` | add a data source |
| `DataChanged()` | your data changed: rebuild cached entries |
| `IsSourceEnabled(id)`, `GetSources()` | which sources exist and are on |
| `GetDrops(npcID)` | rows, grey rows and note, as the tooltip shows them |
| `ImportSnapshot(snapshot, items, mobs)` | hand a parsed snapshot to every source with `Import` |
| `RegisterLootListener(listener)` | follow loot windows: `OnLootOpened(ctx, event)`, `OnLootUpdated`, `OnLootClosed(ctx)`, `OnLootMessage(ctx, msg)`; ctx has `guid`, `npcID`, `section` ("drop", "gather", "pick") and `kind` |
| `RegisterCommand(names, help, run)` | add `/drops <name>` |
| `GetSetting(key)` | read a setting (`openWorldOnly`, `debug`, ...) |
| `Codec` | the `!MD1!` format: `Export`, `ParseSnapshot`, `Rates` |
| `ItemInfo`, `MobInfo`, `IsQuestItem`, `NpcIDFromGUID`, `SpellName`, `IsRogue` | lookups |
| `Print`, `Debug`, `OpenTextWindow(title, help)`, `ShowOptions`, `RefreshOptions` | UI |
| `BRAND`, `MIN_SAMPLE`, `GREY`, `PICKPOCKET`, `QUEST`, `GATHER_NAMES`, `API_VERSION` | constants |
