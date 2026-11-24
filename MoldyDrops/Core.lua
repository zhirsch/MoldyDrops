local ADDON, ns = ...

-- The addon's name as shown in the game: "Moldy" in purple, "Drops" as is.
ns.MOLDY_COLOR = "ffa335ee"
ns.BRAND = "|c" .. ns.MOLDY_COLOR .. "Moldy|rDrops"
ns.PREFIX = "|c" .. ns.MOLDY_COLOR .. "Moldy|r|cffffd100Drops:|r "
ns.MIN_SAMPLE = 20   -- kills an observed source needs before its rates replace an estimate
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

function ns.Debug(msg)
  if ns.db and ns.db.settings.debug then ns.Print("|cff808080[debug]|r " .. msg) end
end

-- SavedVariables: MoldyDropsDB.settings
--   enabled, topN, openWorldOnly, requireModifier, modifierKey, luck, chanceAlways, record, debug
--   sources[sourceID] = false for a data source you turned off
-- Your recorded loot is in MoldyDropsRecorderDB (Recorded.lua). The other
-- data lives in the data source addons (MoldyDrops_112, MoldyDrops_Community).

ns.GATHER_NAMES = { "Skinning", "Herbalism", "Mining", "Engineering", "Pick Pocket", "Quest" }
ns.PICKPOCKET = 5
ns.QUEST = 6 -- quest drops: only shown while one of your quests needs the item
ns.GREY = 0  -- pseudo item ID for "any grey (poor quality) item"

-- Which Tooltip.Qty section a section kind's counts are in.
function ns.SectionOf(kind)
  if kind == ns.PICKPOCKET then return "pick" end
  if kind == ns.QUEST then return "quest" end
  return "gather"
end

function ns.NpcIDFromGUID(guid)
  if not guid then return nil end
  local unitType, _, _, _, _, npcID = strsplit("-", guid)
  if unitType == "Creature" then return tonumber(npcID) end
end

-- Is the player on a quest that still needs itemID? The data sources say which
-- quests an item is for. An objective naming the item decides; otherwise the
-- quest counts as needing it until it's complete.
local function OnQuest(questID)
  if C_QuestLog and C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(questID) end
  if GetQuestLogIndexByID then return (GetQuestLogIndexByID(questID) or 0) > 0 end
  return false
end
local function QuestComplete(questID)
  if C_QuestLog and C_QuestLog.IsComplete then return C_QuestLog.IsComplete(questID) end
  if C_QuestLog and C_QuestLog.ReadyForTurnIn then return C_QuestLog.ReadyForTurnIn(questID) end
  return false
end
function ns.NeedsQuestItem(itemID)
  local quests = ns.Sources.QuestsFor(itemID)
  if not quests then return false end
  for _, questID in ipairs(quests) do
    local ok, on = pcall(OnQuest, questID)
    if ok and on then
      local matched = false
      local okObj, objectives = pcall(function()
        return C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
      end)
      if okObj and type(objectives) == "table" then
        local names = { (ns.ItemInfo(itemID)), (ns.ClientItemInfo(itemID)) }
        for _, obj in ipairs(objectives) do
          local text = type(obj.text) == "string" and obj.text or ""
          for _, name in ipairs(names) do
            if name and name ~= "" and (obj.type == nil or obj.type == "item") and text:find(name, 1, true) then
              if not obj.finished then return true end
              matched = true
            end
          end
        end
      end
      if not matched then
        local okC, complete = pcall(QuestComplete, questID)
        if not (okC and complete) then return true end
      end
    end
  end
  return false
end

-- Is Shift held? A focused edit box swallows the key, so the search box
-- reports Shift itself through ns.shiftOverride.
function ns.ShiftHeld()
  if ns.shiftOverride ~= nil then return ns.shiftOverride end
  return IsShiftKeyDown() and true or false
end

-- The keys the tooltip can wait for (settings.modifierKey), with their
-- MODIFIER_STATE_CHANGED names. Shift isn't one: it already expands rows.
ns.MODIFIER_KEYS = {
  CTRL = { name = "Ctrl", left = "LCTRL", right = "RCTRL", down = function() return IsControlKeyDown() end },
  ALT = { name = "Alt", left = "LALT", right = "RALT", down = function() return IsAltKeyDown() end },
}

function ns.ModifierKey()
  return ns.MODIFIER_KEYS[ns.db.settings.modifierKey] or ns.MODIFIER_KEYS.CTRL
end

-- Should the tooltip show drops right now? Always, unless the "only while a
-- key is held" option is on and that key is up.
function ns.TooltipModifierOk()
  local s = ns.db.settings
  if not s.requireModifier then return true end
  return ns.ModifierKey().down() and true or false
end

function ns.IsRogue()
  return UnitClass and select(2, UnitClass("player")) == "ROGUE"
end

local function InitDB()
  MoldyDropsDB = MoldyDropsDB or {}
  local db = MoldyDropsDB
  -- Only settings live here; 0.1 also kept its data here. That's dropped, not moved.
  for k in pairs(db) do if k ~= "settings" then db[k] = nil end end
  db.settings = db.settings or {}
  if db.settings.enabled == nil then db.settings.enabled = true end
  if db.settings.openWorldOnly == nil then db.settings.openWorldOnly = true end
  if db.settings.luck == nil then db.settings.luck = true end
  if db.settings.record == nil then db.settings.record = true end
  if db.settings.modifierKey == nil then db.settings.modifierKey = "CTRL" end
  db.settings.sources = db.settings.sources or {}
  ns.db = db
end

-- Item name and quality: from the data sources, then the game client.
function ns.ItemInfo(itemID)
  if itemID == ns.GREY then return "Grey items", 0 end
  local name, quality = ns.Sources.ItemInfo(itemID)
  if name then return name, quality or 1 end
  name, quality = ns.ClientItemInfo(itemID)
  if name then return name, quality end
  return "item:" .. itemID, 1
end

-- Quest drops (items that only drop while you're on the quest) are left out of
-- all loot tables. Items that drop for everyone stay, even when the game calls
-- them quest items (Gorilla Fang). A data source that knows the item decides
-- (the 1.12 data does); otherwise the loot window's "quest item" flag
-- (isQuestFlag) or the item class (12 = Quest) does.
local questCache = {}
function ns.IsQuestItem(itemID, isQuestFlag)
  local known = ns.Sources.IsQuestItem(itemID)
  if known ~= nil then return known end
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

-- Mob name, level range and model ID, from the data sources.
function ns.MobInfo(npcID)
  return ns.Sources.MobInfo(npcID)
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  InitDB()
  -- Start each part on its own, so an error in one (still reported through
  -- the normal error handler) doesn't stop the others.
  for _, part in ipairs({ ns.Tooltip, ns.LootWindow, ns.Recorded, ns.Recorder, ns.Options }) do
    xpcall(function() part:Init() end, geterrorhandler())
  end
end)

local function PrintStats()
  local db = ns.db
  local W = "|cffffffff"
  ns.Print("database status")
  local sources = ns.Sources.All()
  if #sources == 0 then
    print("  No data sources installed. Enable MoldyDrops_112 or MoldyDrops_Community.")
  end
  for _, src in ipairs(sources) do
    local on = ns.Sources.IsEnabled(src)
    print(("  %s%s|r%s"):format(W, src.name, on and "" or " |cff808080(turned off)|r"))
    local lines = ns.Sources.Call(src, "Stats")
    for _, line in ipairs(type(lines) == "table" and lines or {}) do print("    " .. tostring(line)) end
  end
  print(("  Tooltip: %s, %s%s"):format(
    db.settings.enabled and "on" or "off", db.settings.openWorldOnly and "open world only" or "everywhere",
    db.settings.requireModifier and (", while " .. ns.ModifierKey().name .. " is held") or ""))
end

-- Commands other addons add (MoldyDrops.RegisterCommand): [name] = { help, run }.
local extra, extraOrder = {}, {}
ns.commands = extra -- for tests

function ns.RegisterCommand(names, help, run)
  if type(names) == "string" then names = { names } end
  if type(names) ~= "table" or type(run) ~= "function" then
    error("MoldyDrops.RegisterCommand(names, help, run): names is a string or a list, run a function", 2)
  end
  local cmd = { help = help, run = run }
  for _, n in ipairs(names) do extra[n:lower()] = cmd end
  if help then extraOrder[#extraOrder + 1] = cmd end
end

local HELP = {
  "|cffffffff/drops search <mob name>|r - find a mob and show its drops (short: /drop s, or just /drops <mob name>)",
  "|cffffffff/drops item <item name>|r - find an item and show the mobs that drop it (short: /drop i)",
  "|cffffffff/drops options|r - open the options window (and choose the data sources)",
  "|cffffffff/drops stats|r - show the state of the data sources",
  "|cffffffff/drops tooltip|r - turn the tooltip on or off",
  "|cffffffff/drops modifier [ctrl, alt or off]|r - only show the tooltip drops while Ctrl (or Alt) is held",
  "|cffffffff/drops luck|r - turn the [4.2%] (Lucky!) tags on unlikely loot on or off",
  "|cffffffff/drops chance|r - always show the drop chance on loot messages, or only when lucky",
  "|cffffffff/drops record|r - turn recording your loot on or off",
  "|cffffffff/drops debug|r - print what each loot window recorded (to check recording)",
  "|cffffffff/drops instances|r - also show the tooltip inside dungeons and raids",
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
  elseif cmd == "tooltip" then
    db.settings.enabled = not db.settings.enabled
    ns.Print(db.settings.enabled and "tooltip enabled" or "tooltip disabled")
  elseif cmd == "modifier" or cmd == "mod" then
    -- "/drops modifier" toggles; with ctrl or alt it turns on with that key; off turns it off.
    local arg = rest:lower()
    if arg == "ctrl" or arg == "control" then
      db.settings.requireModifier, db.settings.modifierKey = true, "CTRL"
    elseif arg == "alt" then
      db.settings.requireModifier, db.settings.modifierKey = true, "ALT"
    elseif arg == "off" or arg == "none" then
      db.settings.requireModifier = false
    else
      db.settings.requireModifier = not db.settings.requireModifier
    end
    ns.Print(db.settings.requireModifier
      and ("tooltip drops shown only while " .. ns.ModifierKey().name .. " is held")
      or "tooltip drops always shown")
  elseif cmd == "options" or cmd == "config" then
    ns.ShowOptions()
  elseif cmd == "record" then
    db.settings.record = not db.settings.record
    ns.Print(db.settings.record and "recording your loot" or "not recording your loot (what's recorded so far is kept)")
  elseif cmd == "debug" then
    db.settings.debug = not db.settings.debug
    ns.Print(db.settings.debug and "debug on: each loot window prints what was recorded" or "debug off")
  elseif cmd == "luck" then
    db.settings.luck = not db.settings.luck
    ns.Print(db.settings.luck and "luck tags on loot messages enabled" or "luck tags on loot messages disabled")
  elseif cmd == "chance" then
    db.settings.chanceAlways = not db.settings.chanceAlways
    ns.Print(db.settings.chanceAlways and "drop chance shown on every loot message"
      or "drop chance shown only on unlikely loot (with /drops luck)")
  elseif cmd == "instances" then
    db.settings.openWorldOnly = not db.settings.openWorldOnly
    ns.Print(db.settings.openWorldOnly and "open world only" or "showing in instances too")
  elseif cmd == "stats" then
    PrintStats()
  elseif extra[cmd] then
    extra[cmd].run(rest)
  elseif cmd == "" or cmd == "help" then
    ns.Print("commands:")
    for _, line in ipairs(HELP) do print("  " .. line) end
    for _, c in ipairs(extraOrder) do print("  " .. c.help) end
  else
    -- Not a subcommand: treat the whole text as a mob search ("/drops defias thug").
    ns.ShowSearch((msg:gsub("^%s+", ""):gsub("%s+$", "")))
  end
  -- Keep the options window in step with settings changed by commands.
  if ns.Options then ns.Options.Refresh() end
end
