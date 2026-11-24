local _, ns = ...

-- Data sources. Anything that knows drop rates can register one with
-- MoldyDrops.RegisterSource(source); docs/data-sources.md describes the
-- interface. Your own loot is built in (Recorded.lua); the 1.12 estimates
-- and the community data are separate addons, MoldyDrops_112 and
-- MoldyDrops_Community.
--
-- For each mob and section the tooltip shows ONE source's numbers, never a
-- mix: your uploads are already part of the community numbers, so adding
-- sources together would count the same kills twice. Tooltip.lua decides
-- which source that is.
local Sources = {}
ns.Sources = Sources

-- Methods a source may have. Data methods (cached) return an entry or nil.
local DATA = { Drops = true, Gather = true, Pick = true, Quest = true, Contents = true }
local METHODS = { "Drops", "Gather", "Pick", "Quest", "Contents", "ItemInfo", "MobInfo",
  "IsQuestItem", "QuestsFor", "Npcs", "Stats", "Import" }

local list, byId = {}, {}
local enabled -- cached list of the sources that are turned on
local memo = {} -- [source][method][key] = entry, or false for none
local reported = {}

local function Report(src, method, err)
  local key = src.id .. ":" .. method
  if reported[key] then return end -- once per source and method, not on every hover
  reported[key] = true
  geterrorhandler()(("MoldyDrops: data source %q failed in %s: %s"):format(src.id, method, tostring(err)))
end

-- Calls one of a source's methods (source:Method(...)). A source that errors
-- is reported once and treated as having no data, so it can't break the tooltip.
function Sources.Call(src, method, ...)
  local fn = src[method]
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d = pcall(fn, src, ...)
  if not ok then Report(src, method, a) return nil end
  return a, b, c, d
end

-- A data method's entry, cached until MoldyDrops.DataChanged().
function Sources.Get(src, method, key)
  if not DATA[method] or key == nil then return nil end
  local bySource = memo[src]
  if not bySource then bySource = {} memo[src] = bySource end
  local cache = bySource[method]
  if not cache then
    -- Weak values: entries the game no longer uses are collected and rebuilt on demand.
    cache = setmetatable({}, { __mode = "v" })
    bySource[method] = cache
  end
  local e = cache[key]
  if e == nil then
    e = Sources.Call(src, method, key)
    if type(e) ~= "table" then e = false end
    cache[key] = e
  end
  return e or nil
end

function Sources.Register(src)
  if type(src) ~= "table" then error("MoldyDrops.RegisterSource: expected a table", 3) end
  if type(src.id) ~= "string" or not src.id:find("^[%w_%-%.]+$") then
    error("MoldyDrops.RegisterSource: the source needs an id (letters, digits, _ - .)", 3)
  end
  if byId[src.id] then
    error(("MoldyDrops.RegisterSource: a source called %q is already registered"):format(src.id), 3)
  end
  for _, m in ipairs(METHODS) do
    if src[m] ~= nil and type(src[m]) ~= "function" then
      error(("MoldyDrops.RegisterSource: %s.%s must be a function"):format(src.id, m), 3)
    end
  end
  src.name = type(src.name) == "string" and src.name or src.id
  src.label = type(src.label) == "string" and src.label or src.name
  src.order = tonumber(src.order) or 100
  src.observed = src.observed and true or false
  byId[src.id] = src
  list[#list + 1] = src
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
  Sources.Changed()
  return src
end

function Sources.ById(id) return byId[id] end

-- Every registered source, in order (lowest order first).
function Sources.All() return list end

function Sources.IsEnabled(src)
  if type(src) == "string" then src = byId[src] end
  if not src then return false end
  local s = ns.db and ns.db.settings.sources
  return not (s and s[src.id] == false)
end

function Sources.SetEnabled(id, on)
  if on then ns.db.settings.sources[id] = nil else ns.db.settings.sources[id] = false end
  Sources.Changed()
end

-- The sources that are turned on, in order. Only these give drop rates;
-- names and levels come from every installed source.
function Sources.Enabled()
  if not enabled then
    enabled = {}
    for _, src in ipairs(list) do
      if Sources.IsEnabled(src) then enabled[#enabled + 1] = src end
    end
  end
  return enabled
end

-- A source's data changed: forget cached entries and the item search index.
function Sources.DataChanged()
  memo = {}
  if ns.InvalidateDropIndex then ns.InvalidateDropIndex() end
end

-- Sources were added or turned on or off.
function Sources.Changed()
  enabled = nil
  Sources.DataChanged()
  if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
end

-- Info that isn't a drop rate comes from every installed source, first answer wins.
function Sources.ItemInfo(itemID)
  for _, src in ipairs(list) do
    local name, quality = Sources.Call(src, "ItemInfo", itemID)
    if type(name) == "string" and name ~= "" then return name, tonumber(quality) end
  end
end

-- Name, level range and model: each from the first source that has it.
function Sources.MobInfo(npcID)
  local name, minL, maxL, model
  for _, src in ipairs(list) do
    local n, lo, hi, m = Sources.Call(src, "MobInfo", npcID)
    if not name and type(n) == "string" and n ~= "" then name = n end
    if not minL and tonumber(lo) then minL, maxL = tonumber(lo), tonumber(hi) or tonumber(lo) end
    if not model and tonumber(m) then model = tonumber(m) end
    if name and minL and model then break end
  end
  return name, minL, maxL, model
end

function Sources.IsQuestItem(itemID)
  for _, src in ipairs(list) do
    local v = Sources.Call(src, "IsQuestItem", itemID)
    if v ~= nil then return v and true or false end
  end
end

-- The quests an item is for, from every source: { questID, ... } or nil.
function Sources.QuestsFor(itemID)
  local out, seen
  for _, src in ipairs(list) do
    local q = Sources.Call(src, "QuestsFor", itemID)
    if type(q) == "table" then
      for _, id in ipairs(q) do
        out, seen = out or {}, seen or {}
        if not seen[id] then seen[id] = true out[#out + 1] = id end
      end
    end
  end
  return out
end

-- Calls fn(npcID) once for every NPC the sources have for a section ("drop",
-- "gather", "pick", "quest", or "mob" for NPCs they can name). onlyEnabled
-- limits it to the sources that are turned on.
function Sources.EachNpc(section, onlyEnabled, fn)
  local seen = {}
  for _, src in ipairs(onlyEnabled and Sources.Enabled() or list) do
    local t = Sources.Call(src, "Npcs", section)
    if type(t) == "table" then
      for npcID in pairs(t) do
        if type(npcID) == "number" and not seen[npcID] then
          seen[npcID] = true
          fn(npcID)
        end
      end
    end
  end
end
