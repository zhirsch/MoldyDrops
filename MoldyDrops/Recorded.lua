local _, ns = ...

-- Your own loot, as a data source built into MoldyDrops. It registers like
-- any other source (MoldyDrops.RegisterSource), so it can be turned off in
-- the options like the others. Also the export string you upload to the
-- website and the import window for the snapshot it gives back (/drops
-- export, /drops import). Recorder.lua does the recording.
--
-- SavedVariables MoldyDropsRecorderDB:
--   clientId          random ID that identifies this install's uploads
--   own[npcID]        { [0] = kills, [-1] = corpses with any grey item, [-2] = no items,
--                       [-3..-6] = corpses with gold / total / min / max copper,
--                       [itemID] = corpses that dropped it, .q / .c = stack counts }
--   ownGather[npcID]  { kind = 1 skin/2 herb/3 mine/4 engineer, [0] = corpses gathered, [itemID] = ... }
--   ownPick[npcID]    { kind = 5, [0] = mobs pick pocketed, [itemID] = times it gave it }
--   items[itemID]     { name, quality } for items seen in loot
--   mobs[npcID]       { name } for mobs seen in game that the other sources can't name
--   lastExport        time of the last /drops export
local api = ns.api -- API.lua, loaded before this file

local function NewClientId()
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local t = {}
  for i = 1, 16 do
    local n = math.random(1, #chars)
    t[i] = chars:sub(n, n)
  end
  return table.concat(t)
end

local TABLES = { "own", "ownGather", "ownPick", "items", "mobs" }

local function InitDB()
  MoldyDropsRecorderDB = MoldyDropsRecorderDB or {}
  local db = MoldyDropsRecorderDB
  for _, k in ipairs(TABLES) do db[k] = type(db[k]) == "table" and db[k] or {} end
  if not db.clientId then
    -- No math.randomseed: WoW removes it and seeds math.random itself.
    db.clientId = NewClientId()
  end
  ns.rdb = db
end

local Rates = api.Codec.Rates
local source = {
  id = "recorded",
  name = "Your loot",
  label = "you",
  description = "What you've looted yourself, recorded while you play solo (and everything you skin, "
    .. "gather or pick pocket). Share it with /drops export.",
  observed = true,
  order = 10, -- before the community data, so names your own game showed win
}

function source:Drops(npcID) return ns.rdb and Rates(ns.rdb.own[npcID]) end
function source:Gather(npcID) return ns.rdb and Rates(ns.rdb.ownGather[npcID]) end
function source:Pick(npcID) return ns.rdb and Rates(ns.rdb.ownPick[npcID]) end

function source:ItemInfo(itemID)
  local i = ns.rdb and ns.rdb.items[itemID]
  if i then return i[1], i[2] end
end

function source:MobInfo(npcID)
  local m = ns.rdb and ns.rdb.mobs[npcID]
  if m then return m[1] end
end

function source:Npcs(section)
  local db = ns.rdb
  if not db then return nil end
  if section == "drop" then return db.own end
  if section == "gather" then return db.ownGather end
  if section == "pick" then return db.ownPick end
  if section == "mob" then return db.mobs end
end

-- Mobs, total kills, mobs with at least MIN_SAMPLE kills, distinct items.
local function CountNpcs(t)
  local n, kills, solid, items = 0, 0, 0, {}
  for _, e in pairs(t or {}) do
    n = n + 1
    local k = e[0] or 0
    kills = kills + k
    if k >= api.MIN_SAMPLE then solid = solid + 1 end
    for id in pairs(e) do if type(id) == "number" and id > 0 then items[id] = true end end
  end
  local ni = 0
  for _ in pairs(items) do ni = ni + 1 end
  return n, kills, solid, ni
end

function source:Stats()
  local db = ns.rdb
  if not db then return nil end
  local W = "|cffffffff"
  local n, k, solid, items = CountNpcs(db.own)
  local gn, gk = CountNpcs(db.ownGather)
  return {
    ("%s%d|r kills of %s%d|r mobs, %s%d|r different items; %s%d|r mobs have %d+ kills"):format(
      W, k, W, n, W, items, W, solid, api.MIN_SAMPLE),
    ("gathering: %s%d|r corpses of %s%d|r mobs (skinning, herbalism, mining)"):format(W, gk, W, gn),
    ("last export: %s"):format(db.lastExport and date("%Y-%m-%d %H:%M", db.lastExport) or "never"),
    ns.recordingDisabled and ("|cffff4040recording off (missing " .. ns.recordingDisabled .. ")|r")
      or ("recording while solo, kills seen by " .. (ns.killMethod or "?")),
  }
end

local function GetAddOnVersion()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return get and get("MoldyDrops", "Version") or "0"
end

function ns.ShowExport()
  local str, npcCount = api.Codec.Export(ns.rdb, GetAddOnVersion(), select(4, GetBuildInfo()))
  ns.rdb.lastExport = time()
  local f = api.OpenTextWindow("Export",
    "Press Ctrl+C to copy, then paste it on the MoldyDrops website. It contains only the loot you recorded, under a random ID.")
  f.edit:SetText(str)
  f.edit:HighlightText()
  f.edit:SetFocus()
  f.status:SetText(("%d mobs, %d characters"):format(npcCount, #str))
  -- Keep the text from being edited by accident.
  f.edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput then self:SetText(str); self:HighlightText() end
  end)
end

-- Paste a snapshot from the website. It goes to the sources that take
-- snapshots (MoldyDrops_Community); your own recordings are kept.
function ns.ShowImport()
  local f = api.OpenTextWindow("Import",
    "Paste the string from the MoldyDrops website (Ctrl+V), then click Import. It replaces the community data; your own recordings are kept.")
  f.edit:SetFocus()
  f.button:SetText("Import")
  f.button:SetScript("OnClick", function()
    local community, items, count, mobs = api.Codec.ParseSnapshot(f.edit:GetText())
    if not community then
      f.status:SetText("|cffff4040" .. items .. "|r")
      return
    end
    if api.ImportSnapshot(community, items, mobs) == 0 then
      f.status:SetText("|cffff4040Nothing to import into: enable MoldyDrops_Community in the AddOns list.|r")
      return
    end
    api.Print(("imported community data for %d mobs from %d contributors (generated %s)."):format(
      count, community.contributors or 0, community.generated or "?"))
    f:Hide()
  end)
end

function ns.ResetRecorded()
  local db = ns.rdb
  db.own, db.ownGather, db.ownPick = {}, {}, {}
  api.DataChanged()
end

source.options = {
  export = {
    type = "execute", order = 1, name = "Export...",
    desc = "Copy your recorded loot to upload to the website (/drops export).",
    func = function() ns.ShowExport() end,
  },
  import = {
    type = "execute", order = 2, name = "Import...",
    desc = "Paste the latest community data from the website (/drops import).",
    func = function() ns.ShowImport() end,
  },
}

api.RegisterSource(source)
api.RegisterCommand("export", "|cffffffff/drops export|r - copy your recorded loot to upload to the website",
  function() ns.ShowExport() end)
api.RegisterCommand("import", "|cffffffff/drops import|r - paste community data from the website",
  function() ns.ShowImport() end)
api.RegisterCommand("reset", "|cffffffff/drops reset|r - delete the loot you've recorded", function(rest)
  if rest == "confirm" then
    ns.ResetRecorded()
    api.Print("your recorded loot, gathering and pick pocketing were deleted.")
  else
    api.Print("this deletes all loot you've recorded. Type |cffffffff/drops reset confirm|r to do it.")
  end
end)
ns.recordedSource = source

-- Started from Core.lua once the saved variables are loaded.
ns.Recorded = {}
function ns.Recorded:Init()
  InitDB()
  api.DataChanged()
end
