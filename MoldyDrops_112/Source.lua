local _, ns = ...

-- The 1.12 estimates from BaseData.lua (CMaNGOS classic-db, GPL-3.0) as a
-- MoldyDrops data source. These are the original game's numbers, not
-- measured on WoW Forever, so they're an estimate source: used for a mob
-- until there's enough recorded data.
local api = MoldyDrops
if type(api) ~= "table" or (api.API_VERSION or 0) < 1 then return end

local base, baseGrey, extra = ns.base or {}, ns.baseGrey or {}, ns.extra or {}
local gather, pick, contents = ns.gather or {}, ns.pick or {}, ns.contents or {}
local qty = ns.qty or {}
local questDrops, questFor = ns.questDrops or {}, ns.questFor or {}
local items, mobs = ns.items or {}, ns.mobs or {}
local questOnly, questOk = ns.questOnly or {}, ns.questOk or {}

-- qty.<section>[key] = { itemID, min, max, ... } -> { [itemID] = { min, max } }
local function Qty(section, key)
  local q = qty[section] and qty[section][key]
  if not q then return nil end
  local out = {}
  for i = 1, #q - 2, 3 do out[q[i]] = { q[i + 1], q[i + 2] } end
  return out
end

-- { itemID, percent, ... } from position first -> { [itemID] = percent }
local function Map(list, first)
  local out = {}
  for i = first or 1, #(list or {}) - 1, 2 do out[list[i]] = list[i + 1] end
  return out
end

local source = {
  id = "1.12",
  name = "1.12 estimates",
  label = "1.12 estimate",
  description = "Drop chances from the original 1.12 game (CMaNGOS data), bundled with MoldyDrops_112. "
    .. "Not measured on WoW Forever, so recorded data replaces them once there's enough.",
  observed = false,
  order = 30,
}

function source:Drops(npcID)
  local b, x = base[npcID], extra[npcID]
  if not b and not x then return nil end
  local e = { items = {}, greys = Map(baseGrey[npcID]), qty = Qty("drop", npcID) }
  for i = 1, #(b or {}) - 1, 2 do
    -- itemID 0 is the chance of at least one grey item
    if b[i] == 0 then e.grey = b[i + 1] else e.items[b[i]] = b[i + 1] end
  end
  if x then
    e.noItems = x[1]
    if x[3] and x[3] > 0 then e.gold = { x[2], x[3], (x[2] + x[3]) / 2 } end
  end
  return e
end

function source:Gather(npcID)
  local g = gather[npcID] -- { kind, itemID, percent, ... }
  if not g then return nil end
  return { kind = g[1], items = Map(g, 2), qty = Qty("gather", npcID) }
end

function source:Pick(npcID)
  local p = pick[npcID] -- { 5, itemID, percent, ... }
  if not p then return nil end
  return { kind = 5, items = Map(p, 2), qty = Qty("pick", npcID) }
end

function source:Quest(npcID)
  local q = questDrops[npcID]
  if not q then return nil end
  return { items = Map(q), qty = Qty("quest", npcID) }
end

function source:Contents(itemID)
  local c = contents[itemID]
  if not c then return nil end
  return { items = Map(c), qty = Qty("content", itemID) }
end

function source:ItemInfo(itemID)
  local i = items[itemID]
  if i then return i[1], i[2] end
end

function source:MobInfo(npcID)
  local m = mobs[npcID] -- { name, minLevel, maxLevel, modelDisplayID }
  if m then return m[1], m[2], m[3], m[4] end
end

-- Quest drops are known exactly: true for items that only drop on a quest,
-- false for quest-class items that drop for everyone (Gorilla Fang).
function source:IsQuestItem(itemID)
  if questOnly[itemID] then return true end
  if questOk[itemID] then return false end
end

function source:QuestsFor(itemID) return questFor[itemID] end

local NPCS = { drop = base, gather = gather, pick = pick, quest = questDrops, mob = mobs }
function source:Npcs(section) return NPCS[section] end

function source:Stats()
  local n, i = 0, 0
  for _ in pairs(base) do n = n + 1 end
  for _ in pairs(items) do i = i + 1 end
  return { ("|cffffffff%d|r mobs, |cffffffff%d|r items (bundled)"):format(n, i) }
end

api.RegisterSource(source)
ns.source = source
