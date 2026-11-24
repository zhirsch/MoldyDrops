local ADDON, ns = ...

ns.PREFIX = "|cffffd100MoldyDrops:|r "
ns.MIN_SAMPLE = 20   -- kills needed before observed rates replace the 1.12 estimate
ns.TOP_N_DEFAULT = 5 -- drop rows in the tooltip (setting: settings.topN)
ns.TOP_N_MAX = 10    -- the bundled 1.12 data keeps each mob's top 10

-- How many drop rows the tooltip shows.
function ns.TopN()
  local n = ns.db and tonumber(ns.db.settings.topN) or ns.TOP_N_DEFAULT
  return math.max(1, math.min(ns.TOP_N_MAX, math.floor(n)))
end

-- The search windows always list every known drop; the setting is only for tooltips.
ns.ALL_ROWS = math.huge

function ns.Print(msg) print(ns.PREFIX .. msg) end

-- SavedVariables layout
--   MoldyDropsDB.clientId          random ID that identifies this install's uploads
--   MoldyDropsDB.settings          { enabled, openWorldOnly }
--   MoldyDropsDB.own[npcID]        { [0] = kills, [-1] = corpses with any grey item,
--                                    [itemID] = corpses that dropped it }
--   MoldyDropsDB.community         { npcs = same shape as own, contributors, generated }
--   MoldyDropsDB.items[itemID]     { name, quality } for items seen in loot or imported
--   MoldyDropsDB.mobs[npcID]       { name } for mobs seen in game or imported
--   MoldyDropsDB.ownGather[npcID]  { kind = 1 skin/2 herb/3 mine/4 engineer, [0] = corpses
--                                    gathered, [itemID] = corpses that gave it }
--   MoldyDropsDB.community.gather  same shape as ownGather, from the website
--   MoldyDropsDB.ownPick[npcID]    { kind = 5, [0] = mobs pick pocketed, [itemID] = times it gave it }
--   MoldyDropsDB.community.pick    same shape as ownPick, from the website

ns.GATHER_NAMES = { "Skinning", "Herbalism", "Mining", "Engineering", "Pick Pocket" }
ns.PICKPOCKET = 5

-- Is Shift held? A focused edit box swallows the key, so the search box
-- reports Shift itself through ns.shiftOverride.
function ns.ShiftHeld()
  if ns.shiftOverride ~= nil then return ns.shiftOverride end
  return IsShiftKeyDown() and true or false
end

function ns.IsRogue()
  return UnitClass and select(2, UnitClass("player")) == "ROGUE"
end
local function NewClientId()
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local t = {}
  for i = 1, 16 do
    local n = math.random(1, #chars)
    t[i] = chars:sub(n, n)
  end
  return table.concat(t)
end

local function InitDB()
  MoldyDropsDB = MoldyDropsDB or {}
  local db = MoldyDropsDB
  db.settings = db.settings or {}
  if db.settings.enabled == nil then db.settings.enabled = true end
  if db.settings.openWorldOnly == nil then db.settings.openWorldOnly = true end
  if db.settings.luck == nil then db.settings.luck = true end
  db.own = db.own or {}
  db.ownGather = db.ownGather or {}
  db.ownPick = db.ownPick or {}
  db.community = db.community or { npcs = {} }
  db.community.gather = db.community.gather or {}
  db.community.pick = db.community.pick or {}
  db.items = db.items or {}
  db.mobs = db.mobs or {}
  if not db.clientId then
    -- No math.randomseed: WoW removes it and seeds math.random itself.
    db.clientId = NewClientId()
  end
  ns.db = db
end

-- Item name/quality: what we've seen in game first, then the bundled table.
ns.GREY = 0  -- pseudo item ID for "any grey (poor quality) item"

function ns.ItemInfo(itemID)
  if itemID == ns.GREY then return "Grey items", 0 end
  local seen = ns.db and ns.db.items[itemID]
  if seen then return seen[1], seen[2] end
  local base = ns.items and ns.items[itemID]
  if base then return base[1], base[2] end
  local name, quality = ns.ClientItemInfo(itemID)
  if name then return name, quality end
  return "item:" .. itemID, 1
end

-- Quest items are left out of all loot tables. The bundled 1.12 data already
-- has none; this catches recorded and imported ones. isQuestFlag is the loot
-- window's "quest item" flag when known; otherwise the item class decides
-- (class 12 = Quest).
local questCache = {}
function ns.IsQuestItem(itemID, isQuestFlag)
  if isQuestFlag then questCache[itemID] = true return true end
  if questCache[itemID] ~= nil then return questCache[itemID] end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not getInstant then return false end
  local classID = select(6, getInstant(itemID))
  if classID == nil then return false end -- unknown yet; don't cache
  questCache[itemID] = classID == ((Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12)
  return questCache[itemID]
end

-- WoW Forever uses the newer namespaced API (C_Spell, C_Item) and drops some
-- old globals, so look functions up in both places.
function ns.SpellName(spellID)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
  if GetSpellInfo then return (GetSpellInfo(spellID)) end
end

function ns.ClientItemInfo(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local name, _, quality = getInfo(itemID)
  return name, quality
end

-- Mob name and level range (levels only known for bundled 1.12 mobs).
function ns.MobInfo(npcID)
  local base = ns.mobs and ns.mobs[npcID]
  local seen = ns.db and ns.db.mobs[npcID]
  local name = (seen and seen[1]) or (base and base[1])
  return name, base and base[2], base and base[3], base and base[4] -- name, min level, max level, model ID
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  InitDB()
  -- Start each part on its own, so an error in one (still reported through
  -- the normal error handler) doesn't stop the others.
  for _, part in ipairs({ ns.Tooltip, ns.Recorder, ns.Options }) do
    xpcall(function() part:Init() end, geterrorhandler())
  end
end)

-- Returns mobs, total kills, mobs with at least MIN_SAMPLE kills, distinct items.
local function CountNpcs(t)
  local n, kills, solid, items = 0, 0, 0, {}
  for _, e in pairs(t or {}) do
    n = n + 1
    local k = e[0] or 0
    kills = kills + k
    if k >= ns.MIN_SAMPLE then solid = solid + 1 end
    for id in pairs(e) do if type(id) == "number" and id > 0 then items[id] = true end end
  end
  local ni = 0
  for _ in pairs(items) do ni = ni + 1 end
  return n, kills, solid, ni
end

local function Count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function PrintStats()
  local db = ns.db
  local W = "|cffffffff"
  ns.Print("database status")
  print(("  1.12 estimates (bundled): %s%d|r mobs, %s%d|r items"):format(W, Count(ns.base), W, Count(ns.items)))

  local n, k, solid, items = CountNpcs(db.own)
  print(("  Your recordings: %s%d|r kills of %s%d|r mobs, %s%d|r different items; %s%d|r mobs have %d+ kills"):format(
    W, k, W, n, W, items, W, solid, ns.MIN_SAMPLE))
  local gn, gk = CountNpcs(db.ownGather)
  print(("    gathering: %s%d|r corpses of %s%d|r mobs (skinning, herbalism, mining)"):format(W, gk, W, gn))
  print(("    last export: %s"):format(db.lastExport and date("%Y-%m-%d %H:%M", db.lastExport) or "never"))

  local c = db.community
  if c and c.generated then
    local cn, ck, csolid, citems = CountNpcs(c.npcs)
    print(("  Community data: %s%d|r kills of %s%d|r mobs, %s%d|r different items; %s%d|r mobs have %d+ kills"):format(
      W, ck, W, cn, W, citems, W, csolid, ns.MIN_SAMPLE))
    print(("    from %s%d|r contributors, generated %s"):format(W, c.contributors or 0, c.generated))
  else
    print("  Community data: none yet. Get it from the website and use /drops import.")
  end

  print(("  Names known in game: %s%d|r mobs, %s%d|r items"):format(W, Count(db.mobs), W, Count(db.items)))
  print(("  Tooltip: %s, %s; %s"):format(
    db.settings.enabled and "on" or "off", db.settings.openWorldOnly and "open world only" or "everywhere",
    ns.recordingDisabled and ("|cffff4040recording off (missing " .. ns.recordingDisabled .. ")|r")
      or ("recording while solo, kills seen by " .. (ns.killMethod or "?"))))
end

local HELP = {
  "|cffffffff/drops search <mob name>|r - find a mob and show its drops (short: /drop s, or just /drops <mob name>)",
  "|cffffffff/drops item <item name>|r - find an item and show the mobs that drop it (short: /drop i)",
  "|cffffffff/drops export|r - copy your recorded loot to upload to the website",
  "|cffffffff/drops import|r - paste community data from the website",
  "|cffffffff/drops options|r - open the options window",
  "|cffffffff/drops stats|r - show the state of the database",
  "|cffffffff/drops tooltip|r - turn the tooltip on or off",
  "|cffffffff/drops luck|r - turn the (Lucky!) tags on loot messages on or off",
  "|cffffffff/drops debug|r - print what each loot window recorded (to check recording)",
  "|cffffffff/drops instances|r - also show the tooltip inside dungeons and raids",
  "|cffffffff/drops reset|r - delete the loot you've recorded",
}

SLASH_MOLDYDROPS1 = "/drops"
SLASH_MOLDYDROPS2 = "/moldydrops"
SLASH_MOLDYDROPS3 = "/drop"
SlashCmdList.MOLDYDROPS = function(msg)
  local db = ns.db
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "search" or cmd == "s" then
    ns.ShowSearch(rest)
  elseif cmd == "item" or cmd == "i" then
    ns.ShowItemSearch(rest)
  elseif cmd == "export" then
    ns.ShowExport()
  elseif cmd == "import" then
    ns.ShowImport()
  elseif cmd == "tooltip" then
    db.settings.enabled = not db.settings.enabled
    ns.Print(db.settings.enabled and "tooltip enabled" or "tooltip disabled")
  elseif cmd == "options" or cmd == "config" then
    ns.ShowOptions()
  elseif cmd == "debug" then
    db.settings.debug = not db.settings.debug
    ns.Print(db.settings.debug and "debug on: each loot window prints what was recorded" or "debug off")
  elseif cmd == "luck" then
    db.settings.luck = not db.settings.luck
    ns.Print(db.settings.luck and "luck tags on loot messages enabled" or "luck tags on loot messages disabled")
  elseif cmd == "instances" then
    db.settings.openWorldOnly = not db.settings.openWorldOnly
    ns.Print(db.settings.openWorldOnly and "open world only" or "showing in instances too")
  elseif cmd == "stats" then
    PrintStats()
  elseif cmd == "reset" then
    if rest == "confirm" then
      db.own, db.ownGather, db.ownPick = {}, {}, {}
      ns.Print("your recorded loot, gathering and pick pocketing were deleted.")
    else
      ns.Print("this deletes all loot you've recorded. Type |cffffffff/drops reset confirm|r to do it.")
    end
  elseif cmd == "" or cmd == "help" then
    ns.Print("commands:")
    for _, line in ipairs(HELP) do print("  " .. line) end
  else
    -- Not a subcommand: treat the whole text as a mob search ("/drops defias thug").
    ns.ShowSearch((msg:gsub("^%s+", ""):gsub("%s+$", "")))
  end
  -- Keep the options window in step with settings changed by commands.
  if ns.Options then ns.Options.Refresh() end
end
