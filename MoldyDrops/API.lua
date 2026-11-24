local _, ns = ...

-- The global MoldyDrops table: what other addons, the bundled data sources
-- included, can use. docs/data-sources.md describes it. Functions are called
-- with a dot: MoldyDrops.RegisterSource(source).
local api = {
  API_VERSION = 1,
  BRAND = ns.BRAND,            -- "MoldyDrops" with "Moldy" in purple
  MIN_SAMPLE = ns.MIN_SAMPLE,  -- kills before recorded rates replace estimates
  GREY = ns.GREY,              -- pseudo item ID of the "Grey items" row
  PICKPOCKET = ns.PICKPOCKET,  -- section kinds: 1-4 gathering, 5 pick pocket, 6 quest
  QUEST = ns.QUEST,
  GATHER_NAMES = ns.GATHER_NAMES,
}

-- Data sources
function api.RegisterSource(source) return ns.Sources.Register(source) end
-- Call when your source's data changes, so cached entries are rebuilt.
function api.DataChanged() ns.Sources.DataChanged() end
function api.IsSourceEnabled(id) return ns.Sources.IsEnabled(id) end
-- { { id, name, enabled }, ... } in order
function api.GetSources()
  local out = {}
  for _, src in ipairs(ns.Sources.All()) do
    out[#out + 1] = { id = src.id, name = src.name, enabled = ns.Sources.IsEnabled(src) }
  end
  return out
end

-- Hands a website snapshot (Codec.ParseSnapshot's results) to every installed
-- source with an Import method. Returns how many took it.
function api.ImportSnapshot(snapshot, items, mobs)
  local n = 0
  for _, src in ipairs(ns.Sources.All()) do
    if src.Import and ns.Sources.Call(src, "Import", snapshot, items or {}, mobs or {}) then n = n + 1 end
  end
  if n > 0 then ns.Sources.DataChanged() end
  return n
end

-- What the tooltip would show for a mob: rows { { itemID, percent }, ... },
-- grey rows, and the note naming the source.
function api.GetDrops(npcID) return ns.Tooltip.Choose(npcID) end

-- Loot windows: see LootWindow.lua for the listener's methods.
function api.RegisterLootListener(listener) ns.LootWindow.AddListener(listener) end
function api.SelfLootPrefixes() return ns.SelfLootPrefixes() end

-- /drops <name>: RegisterCommand("export", "|cffffffff/drops export|r - ...", function(rest) end)
function api.RegisterCommand(names, help, run) ns.RegisterCommand(names, help, run) end

-- Settings are read-only from outside (openWorldOnly, debug, ...).
function api.GetSetting(key)
  local s = ns.db and ns.db.settings
  return s and s[key]
end

-- Helpers
api.Codec = ns.Codec -- the !MD1! exchange format and Codec.Rates
function api.ItemInfo(itemID) return ns.ItemInfo(itemID) end
function api.MobInfo(npcID) return ns.MobInfo(npcID) end
function api.IsQuestItem(itemID, isQuestFlag) return ns.IsQuestItem(itemID, isQuestFlag) end
function api.NpcIDFromGUID(guid) return ns.NpcIDFromGUID(guid) end
function api.SpellName(spellID) return ns.SpellName(spellID) end
function api.IsRogue() return ns.IsRogue() end
function api.Print(msg) ns.Print(msg) end
function api.Debug(msg) ns.Debug(msg) end
function api.OpenTextWindow(title, help) return ns.OpenTextWindow(title, help) end
function api.ShowOptions() ns.ShowOptions() end
function api.RefreshOptions() if ns.Options then ns.Options.Refresh() end end

ns.api = api
MoldyDrops = api
