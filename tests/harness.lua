local js = require "js"
local SRC = js.global.SRC
local out = {}
local fails = 0
local function log(s) out[#out + 1] = tostring(s) end
local function check(name, cond, extra)
  if cond then log("PASS " .. name) else fails = fails + 1; log("FAIL " .. name .. (extra and (" :: " .. tostring(extra)) or "")) end
end
local function near(a, b) return math.abs(a - b) < 0.01 end

-- ---------- WoW API stubs ----------
local now = 1000
function GetTime() return now end
function time() return 1795400000 end
date = os.date
-- Functions WoW's Lua doesn't have, so the tests fail if the addon uses them.
math.randomseed = nil
io = nil
loadstring = nil
function print(s) log("[print] " .. tostring(s)) end
function strsplit(sep, s)
  local t = {}
  for p in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do t[#t + 1] = p end
  return table.unpack(t)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames = {}
-- Ace3 and the Settings API, faked: the addon's options are checked through them.
local aceRegistered, aceBlizAdded, aceNotified, aceOpened, openedCategory = {}, nil, nil, nil, nil
local aceLibs = {
  ["AceConfig-3.0"] = { RegisterOptionsTable = function(_, app, t) aceRegistered[app] = t end },
  ["AceConfigDialog-3.0"] = {
    AddToBlizOptions = function(_, app, name) aceBlizAdded = name; return {}, 42 end,
    Open = function(_, app) aceOpened = app end,
  },
  ["AceConfigRegistry-3.0"] = { NotifyChange = function(_, app) aceNotified = app end },
}
LibStub = setmetatable({}, { __call = function(_, name) return aceLibs[name] end })
Settings = { OpenToCategory = function(id) openedCategory = id end }
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
local chatFilters = {}
function ChatFrame_AddMessageEventFilter(event, fn) chatFilters[event] = fn end
SlashCmdList = {}
local frames = {}
-- Any method you call on a stub returns another stub, so UI-building code
-- (CreateFontString():SetPoint() and so on) runs without a real client.
local stubMT = {}
local function Stub() return setmetatable({}, stubMT) end
-- Only capitalized keys (WoW methods) are invented; data fields stay nil.
stubMT.__index = function(_, k)
  if type(k) == "string" and k:find("^%u") then return function() return Stub() end end
end
UIParent = Stub()
ChatFontNormal = Stub()
function CreateFrame(_, name)
  local f = Stub()
  f.frameName = name
  f.events = {}
  f.RegisterEvent = function(self, e) self.events[e] = true end
  f.UnregisterEvent = function(self, e) self.events[e] = nil end
  f.SetScript = function(self, k, fn) self[k] = fn end
  f.HookScript = function(self, k, fn) self["hook_" .. k] = fn end
  -- visibility and position, so window behavior can be checked
  f.shown = false
  f.Show = function(self) self.shown = true end
  f.Hide = function(self)
    local was = self.shown
    self.shown = false
    if was and rawget(self, "OnHide") then self.OnHide(self) end -- like the real client
  end
  f.IsShown = function(self) return self.shown end
  f.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
  f.SetChecked = function(self, v) self.checked = v and true or false end
  f.GetChecked = function(self) return self.checked end
  f.SetValue = function(self, v) -- like the client, SetValue fires OnValueChanged
    self.value = v
    if rawget(self, "OnValueChanged") then self.OnValueChanged(self, v) end
  end
  f.GetValue = function(self) return self.value end
  f.left, f.top = 300, 700
  f.GetLeft = function(self) return self.left end
  f.GetTop = function(self) return self.top end
  f.SetPoint = function(self, point, rel, relPoint, x, y)
    if point == "TOPLEFT" and relPoint == "BOTTOMLEFT" then self.left, self.top = x, y end
  end
  frames[#frames + 1] = f
  return f
end
local function FrameNamed(name)
  for _, f in ipairs(frames) do if f.frameName == name then return f end end
end
local function Fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.OnEvent then f.OnEvent(f, event, ...) end
  end
end
GameTooltip = CreateFrame()
local spellNames = { [8613] = "Skinning", [2575] = "Mining", [2366] = "Herb Gathering", [921] = "Pick Pocket" }
-- WoW Forever has the namespaced API only: no GetSpellInfo or GetItemInfo globals.
GetSpellInfo = nil
GetItemInfo = nil
C_Spell = { GetSpellName = function(id) return spellNames[id] end }
local itemClass = { [884] = 12, [1357] = 12, [55555] = 12 } -- quest items; everything else trade goods
C_Item = {
  GetItemInfo = function() return nil end,
  GetItemInfoInstant = function(id) return id, "Type", "Sub", "", 0, itemClass[id] or 7, 0 end,
}
-- Quest log: questLog[questID] = { complete = bool, objectives = { ... } }
local questLog = {}
C_QuestLog = {
  IsOnQuest = function(id) return questLog[id] ~= nil end,
  IsComplete = function(id) return questLog[id] and questLog[id].complete or false end,
  GetQuestObjectives = function(id) return questLog[id] and questLog[id].objectives or {} end,
}
local errors = {}
function geterrorhandler() return function(e) errors[#errors + 1] = tostring(e) end end
function IsInInstance() return false end
local grouped = false
function IsInGroup() return grouped end
local units = {}
function UnitGUID(u) return units[u] and units[u].guid end
function UnitIsDead(u) return units[u] and units[u].dead end
function UnitIsTapDenied(u) return units[u] and units[u].tapDenied end
function UnitExists(u) return units[u] ~= nil end
function UnitIsPlayer() return false end
function UnitCanAttack(_, u) return units[u] ~= nil and not units[u].friendly end
function UnitName(u) return units[u] and units[u].name end
local lootable = {}
function CanLootUnit(guid) return lootable[guid] end
C_Timer = { After = function(_, fn) fn() end }
-- Like WoW Forever, no readable combat log: kills come from unit tokens.
CombatLogGetCurrentEventInfo = nil
C_CombatLog = nil
function UnitThreatSituation(who, u) return units[u] and units[u].threat end
function UnitAffectingCombat(u) return units[u] and units[u].combat end
function UnitIsUnit(a, b) return UnitGUID(a) ~= nil and UnitGUID(a) == UnitGUID(b) end
local loot = {}
function GetNumLootItems() return #loot end
function GetLootSourceInfo(slot) return loot[slot].guid, loot[slot].copper or loot[slot].qty or 1 end
local playerClass = "WARRIOR"
function UnitClass() return "Class", playerClass end
function GetLootSlotType(slot) return loot[slot].money and 2 or 1 end
function GetLootSlotLink(slot) return loot[slot].item and ("|cffffffff|Hitem:" .. loot[slot].item .. "::::::::|h[x]|h|r") end
function GetLootSlotInfo(slot) return nil, loot[slot].name, 1, nil, loot[slot].q, false, loot[slot].quest end
function IsFishingLoot() return false end
local shift = false
function IsShiftKeyDown() return shift end
local ctrl = false
function IsControlKeyDown() return ctrl end
function GetBuildInfo() return "1.60.1", "1", "Nov 1 2026", 16001 end
function GetAddOnMetadata() return "0.1.0" end

-- ---------- load addon ----------
local ns = {}
for file in tostring(SRC.FILES):gmatch("[^\n]+") do
  local chunk, err = load(SRC[file], "@" .. file)
  if not chunk then error(err) end
  chunk("MoldyDrops", ns)
end
Fire("ADDON_LOADED", "MoldyDrops")
check("no errors during startup", #errors == 0, errors[1])
check("db initialised", MoldyDropsDB and #MoldyDropsDB.clientId == 16, MoldyDropsDB and MoldyDropsDB.clientId)
check("base data loaded (grey row first)", ns.base[6] and ns.base[6][1] == 0 and ns.baseGrey[6][1] == 755 and ns.mobs[6][1] == "Kobold Vermin")

local PLAYER = "Player-1-00000001"
units.player = { guid = PLAYER }
local function guid(npc, n) return ("Creature-0-1-0-12-%d-%08d"):format(npc, n) end
-- A mob on a nameplate fights you (or not, if engaged is false), then dies.
local function Kill(g, hasLoot, killName, engaged)
  lootable[g] = hasLoot
  units.nameplate1 = { guid = g, name = killName or "Kobold Vermin", combat = true,
    threat = (engaged ~= false) and 1 or nil }
  Fire("UNIT_THREAT_LIST_UPDATE", "nameplate1")
  units.nameplate1.dead = true
  Fire("UNIT_HEALTH", "nameplate1")
  Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
  units.nameplate1 = nil
end
check("kills seen by threat tracking", ns.killMethod == "threat tracking", ns.killMethod)
local function Loot(items)
  loot = items
  Fire("LOOT_OPENED")
  loot = {}
  Fire("LOOT_CLOSED")
end

-- 1: killed and looted (candle + money)
local g1 = guid(6, 1)
Kill(g1, true)
Loot({ { guid = g1, item = 755, name = "Melted Candle", q = 0 }, { guid = g1, money = true, copper = 150 } })
-- 2: empty corpse
Kill(guid(6, 2), false)
-- 3: has loot but walked past
Kill(guid(6, 3), true)
-- 4: reopen corpse 1, then skin it
Loot({ { guid = g1, item = 755 } })
now = now + 10
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 8613)
Loot({ { guid = g1, item = 2318, name = "Light Leather", q = 1 } })
now = now + 10
-- 5: pick pocket a living kobold
local g5 = guid(6, 5)
units.target = { guid = g5, dead = false }
Loot({ { guid = g5, item = 159, name = "Refreshing Spring Water", q = 1 } })
units.target = nil
-- 6: mob tapped by someone else, then we land the killing blow
local g6 = guid(6, 6)
units.target = { guid = g6, tapDenied = true }
Fire("PLAYER_TARGET_CHANGED")
units.target = nil
Kill(g6, false)
-- 6b: a mob dies that you never fought (someone else's kill): ignored
Kill(guid(6, 66), false, nil, false)
-- 7: in a group: ignored
grouped = true
local g7 = guid(6, 7)
Kill(g7, false)
Loot({ { guid = g7, item = 755 } })
grouped = false
-- 8: killed by a pet-less DoT etc. but looted with two items
local g8 = guid(6, 8)
Loot({ { guid = g8, item = 755, q = 0 }, { guid = g8, item = 159, name = "Refreshing Spring Water", q = 1 } })

local own = MoldyDropsDB.own[6]
check("kills counted = 3 (looted, empty, looted-without-kill-event)", own and own[0] == 3, own and own[0])
check("candle count = 2", own and own[755] == 2, own and own[755])
check("water count = 1 (pick pocket ignored)", own and own[159] == 1, own and own[159])
check("skinning ignored", own and own[2318] == nil)
check("item name stored", MoldyDropsDB.items[755] and MoldyDropsDB.items[755][1] == "Melted Candle")

check("grey corpses counted", own and own[-1] == 2, own and own[-1])
check("empty corpse counted as no items", own and own[-2] == 1, own and own[-2])
check("gold recorded", own and own[-3] == 1 and own[-4] == 150 and own[-5] == 150 and own[-6] == 150)
local pp = MoldyDropsDB.ownPick[6]
check("pick pocket recorded", pp and pp.kind == 5 and pp[0] == 1 and pp[159] == 1)

-- no items + gold lines (1.12 data while the sample is small)
local noItems, gold = ns.Tooltip.Extras(6)
check("base no-items chance", noItems and near(noItems, 51.3), noItems)
check("base gold range", gold and gold[1] == 1 and gold[2] == 4 and gold[3] == 2.5)
local xl = ns.Tooltip.ExtraLines(6)
check("No items and Gold lines", #xl == 2 and xl[1][1]:find("No items", 1, true) and xl[2][1]:find("1c", 1, true)
  and xl[2][1]:find("4c", 1, true) and xl[2][2]:find("avg", 1, true), xl[2] and xl[2][1])
-- "No items" sits among the drops in order of chance; gold stays last.
local function checkPlacement(npcID, expand, label)
  local rows = ns.Tooltip.DropSection(npcID, 5, expand)
  local ni = ns.Tooltip.Extras(npcID)
  local at
  for i, r in ipairs(rows) do if r[1]:find("No items", 1, true) then at = i end end
  local ok = at ~= nil
  for i, r in ipairs(rows) do
    local line = r[3]
    if ok and line and line[3] == nil then -- top-level drop
      if i < at and line[2] < ni then ok = false end
      if i > at and line[2] > ni then ok = false end
    end
  end
  -- never between a row and its grey items / container contents
  if ok and rows[at + 1] and rows[at + 1][3] and rows[at + 1][3][3] ~= nil then ok = false end
  if ok and rows[#rows][1]:find("Gold", 1, true) == nil and ns.Tooltip.Extras(npcID) and select(2, ns.Tooltip.Extras(npcID)) then ok = false end
  check("No items sorted: " .. label, ok, at)
  return rows, at
end
local drake, at = checkPlacement(7044, false, "Black Drake (71%) goes first")
check("Black Drake: No items is the first row", at == 1 and drake[#drake][1]:find("Gold", 1, true), at)
-- chances are colored like the item's rarity; grey row and No items are grey
local function rightOf(rows, text)
  for _, r in ipairs(rows) do if r[1]:find(text, 1, true) then return r[2] end end
end
local GREYHEX, WHITE, GREEN = "|cff9d9d9d", "|cffffffff", "|cff1eff00"
check("green item's chance is green", (rightOf(drake, "Star Ruby") or ""):sub(1, 10) == GREEN, rightOf(drake, "Star Ruby"))
check("white item's chance is white", (rightOf(drake, "Wicked Claw") or ""):sub(1, 10) == WHITE, rightOf(drake, "Wicked Claw"))
check("Grey items chance is grey", (rightOf(drake, "Grey items") or ""):sub(1, 10) == GREYHEX, rightOf(drake, "Grey items"))
check("No items chance is grey", (rightOf(drake, "No items") or ""):sub(1, 10) == GREYHEX, rightOf(drake, "No items"))
local expanded = ns.Tooltip.DropSection(6, 5, true)
check("individual grey item's chance is grey (Shift)", (rightOf(expanded, "Melted Candle") or ""):sub(1, 10) == GREYHEX,
  rightOf(expanded, "Melted Candle"))
checkPlacement(6, false, "Kobold Vermin")
checkPlacement(6, true, "Kobold Vermin with Shift")
checkPlacement(113, false, "Stonetusk Boar")
checkPlacement(126, true, "Murloc Coastrunner with Shift (container)")
noItems, gold = ns.Tooltip.Extras(113) -- Stonetusk Boar: beasts drop no gold
check("no gold line for beasts", noItems ~= nil and gold == nil and #ns.Tooltip.ExtraLines(113) == 1)
check("money formatting", ns.FormatMoney(12345):find("1g", 1, true) and ns.FormatMoney(12345):find("23s", 1, true)
  and ns.FormatMoney(12345):find("45c", 1, true) and ns.FormatMoney(200) == "|cffc7c7cf2s|r", ns.FormatMoney(200))
check("0% formats as 0%", ns.FormatPct(0) == "0%")

-- pick pocket section only for rogues
local function hasPick(npcID)
  for _, s in ipairs(ns.Tooltip.Sections(npcID)) do if s[1] == ns.PICKPOCKET then return s end end
end
check("no pick pocket section for a warrior", hasPick(38) == nil)
playerClass = "ROGUE"
local ps = hasPick(38)
check("pick pocket section for a rogue (1.12 data)", ps and ps[3] == "1.12 estimate" and ps[2][1][1] == 5363, ps and ps[3])
playerClass = "WARRIOR"

-- gathering
local sk = MoldyDropsDB.ownGather[6]
check("skinning recorded separately", sk and sk.kind == 1 and sk[0] == 1 and sk[2318] == 1)
local gk, grows, gnote = ns.Tooltip.Gather(113) -- Stonetusk Boar, bundled skinning data
check("bundled skinning data", gk == 1 and grows[1] and near(grows[1][2], 60.7) and gnote == "1.12 estimate",
  tostring(gk) .. " " .. tostring(gnote))
check("skinning item name", ns.ItemInfo(grows[1][1]) == "Ruined Leather Scraps", ns.ItemInfo(grows[1][1]))
-- herbalism on a new mob, while grouped (gathering is personal, so it still counts)
grouped = true
local gH = guid(274400, 1)
now = now + 10
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 2366)
Loot({ { guid = gH, item = 88888, name = "Skybloom", q = 1 } })
Loot({ { guid = gH, item = 88888 } }) -- reopening doesn't count twice
grouped = false
now = now + 10
gk, grows, gnote = ns.Tooltip.Gather(274400)
check("herbalism recorded", gk == 2 and grows[1][1] == 88888 and grows[1][2] == 100 and gnote == "you, only 1 corpse",
  tostring(gk) .. " " .. tostring(gnote))
check("no gathering for a humanoid", ns.Tooltip.Gather(38) == nil) -- Defias Thug



-- small own sample -> base estimate, greys folded
local rows, greys, note = ns.Tooltip.Choose(6)
check("small sample uses 1.12 estimate", note == "1.12 estimate (you: 3 kills)", note)
check("base grey row first", rows[1][1] == 0 and near(rows[1][2], 35.8), rows[1][1] .. " " .. rows[1][2])
check("no individual grey in base rows", (function() for _, r in ipairs(rows) do if r[1] == 755 then return false end end return true end)())
check("base grey list", greys[1][1] == 755 and near(greys[1][2], 29.8))
local lines, n2, hasGreys = ns.Tooltip.Lines(6, 5, false)
check("collapsed: 5 lines", #lines == 5 and hasGreys, #lines)
local left = ns.Tooltip.LineText(lines[1], false, true)
check("grey row label with Shift hint", left:find("Grey items", 1, true) and left:find("(Shift)", 1, true), left)
lines = ns.Tooltip.Lines(6, 5, true)
check("expanded: grey children follow grey row", #lines > 5 and lines[2][1] == 755 and lines[2][3] == "grey", #lines)
left = ns.Tooltip.LineText(lines[2], true, true)
check("child indented, no hint", left:sub(1, 4) == "    " and not left:find("Shift", 1, true), left)
left = ns.Tooltip.LineText(lines[1], true, true)
check("grey row without hint when expanded", not left:find("Shift", 1, true), left)

-- containers: Murloc Coastrunner (126) drops Small Barnacled Clam (5523)
check("clam contents bundled", ns.contents[5523] and ns.contents[5523][1] == 5503 and ns.contents[5523][2] == 100)
lines = ns.Tooltip.Lines(126, 5, false)
local clamLine
for _, l in ipairs(lines) do if l[1] == 5523 then clamLine = l end end
check("collapsed: container listed, contents hidden", clamLine ~= nil and (function()
  for _, l in ipairs(lines) do if l[3] == "content" then return false end end return true end)())
left = ns.Tooltip.LineText(clamLine, false)
check("container shows Shift hint", left:find("Small Barnacled Clam", 1, true) and left:find("(Shift)", 1, true), left)
lines = ns.Tooltip.Lines(126, 5, true)
local at
for i, l in ipairs(lines) do if l[1] == 5523 then at = i end end
check("expanded: contents follow the container", at and lines[at + 1][1] == 5503 and lines[at + 1][3] == "content"
  and lines[at + 2][1] == 5498 and near(lines[at + 2][2], 5), at)
local cl, cr = ns.Tooltip.LineText(lines[at + 1], true)
check("content line text", cl:find("in it:", 1, true) and cl:find("Clam Meat", 1, true) and cr:find("100%", 1, true), cl .. " | " .. cr)
check("container hint gone when expanded", not ns.Tooltip.LineText(lines[at], true):find("Shift", 1, true))
check("non-container has no contents", ns.Tooltip.Contents(755) == nil)

-- a new WoW Forever mob: name learned from the kill
local gF = guid(274300, 1)
Kill(gF, true, "Coldrasp")
Loot({ { guid = gF, item = 99999, name = "Frosted Fang", q = 2 } })
check("Forever mob name recorded", MoldyDropsDB.mobs[274300] and MoldyDropsDB.mobs[274300][1] == "Coldrasp")
check("known 1.12 mob name not duplicated", MoldyDropsDB.mobs[6] == nil)
MoldyDropsDB.own[274300] = { [0] = 4, [99999] = 1 }
rows, greys, note = ns.Tooltip.Choose(274300)
check("no base -> small own sample", note == "you, only 4 kills" and rows[1][2] == 25, note)

-- search
local res = ns.SearchMobs("kobold vermin")
check("search exact first", res[1] and res[1].id == 6 and res[1].rank == 0 and res[1].minL == 1, res[1] and res[1].name)
res = ns.SearchMobs("defias")
check("search substring finds many", #res > 5 and res[1].name:sub(1, 6) == "Defias", #res)
res = ns.SearchMobs("THUG")
local foundThug = false
for _, r in ipairs(res) do if r.id == 38 then foundThug = true end end
check("search case-insensitive", foundThug)
res = ns.SearchMobs("coldr")
check("search finds Forever mob from recordings", res[1] and res[1].id == 274300, res[1] and res[1].name)
check("search empty query", #ns.SearchMobs("   ") == 0)
check("search special chars are literal", #ns.SearchMobs("%") == 0 and (function()
  for _, r in ipairs(ns.SearchMobs("(")) do if not r.name:find("(", 1, true) then return false end end
  return true
end)())

-- base64 round trips (vs JS btoa)
for len = 0, 12 do
  local s = ("MoldyDrops!?"):rep(2):sub(1, len)
  local e = ns.Codec.Base64Encode(s)
  check("b64 len " .. len, e == js.global:btoa(s) and ns.Codec.Base64Decode(e) == s, e)
end
local bin = {}
for i = 0, 255 do bin[#bin + 1] = string.char(i) end
bin = table.concat(bin)
check("b64 all bytes", ns.Codec.Base64Decode(ns.Codec.Base64Encode(bin)) == bin)

-- export
local str, n = ns.Codec.Export(MoldyDropsDB, "0.1.0", 16001)
local text = ns.Codec.Base64Decode(str:sub(6))
log("export text:\n" .. text)
check("export prefix", str:sub(1, 5) == "!MD1!")
check("export header", text:match("^MD1 U " .. MoldyDropsDB.clientId .. " 1795400000 0.1.0 16001\n") ~= nil)
check("export N line with grey count", text:find("\nN 6 3 159:1 755:2 G:2 E:1 $:1:150:150:150\n", 1, true) ~= nil)
check("export M line", text:find("\nM 274300 Coldrasp", 1, true) ~= nil)
check("export S lines", text:find("\nS 6 1 1 2318:1\n", 1, true) ~= nil and text:find("\nS 274400 2 1 88888:1\n", 1, true) ~= nil)
check("export pick pocket as S kind 5", text:find("\nS 6 5 1 159:1\n", 1, true) ~= nil)
check("export gathered item names", text:find("\nI 88888 1 Skybloom", 1, true) ~= nil)
check("export I line", text:find("\nI 755 0 Melted Candle", 1, true) ~= nil)
check("export mob count", n == 2, n)
local ok, err = ns.Codec.ParseSnapshot(str)
check("upload string rejected by import", ok == nil and err:find("upload string") ~= nil, err)

-- snapshot import
local snapText = "MD1 S 1795400000 7\nN 6 120 755:36 159:8 4536:15 G:40 E:30 $:100:5000:10:90\nN 30 50 1476:25 5465:10\nN 274300 30 99999:9\nI 99999 3 Skyborne Trinket\nM 274300 Coldrasp\nM 274301 Gale Wisp\nS 113 1 25 2318:20 783:5\nS 38 5 25 5363:10\nS 5 9 10 1:1\nZ future record\n"
local snap = "!MD1!" .. js.global:btoa(snapText)
local comm, items, count, mobs = ns.Codec.ParseSnapshot("  " .. snap .. "\n")
check("snapshot parsed", comm and count == 3 and comm.contributors == 7, items)
check("snapshot item", items[99999] and items[99999][1] == "Skyborne Trinket" and items[99999][2] == 3)
check("snapshot mob names", mobs and mobs[274301] and mobs[274301][1] == "Gale Wisp")
check("snapshot grey count", comm.npcs[6][-1] == 40 and comm.npcs[6][0] == 120)
MoldyDropsDB.community = comm
rows, greys, note = ns.Tooltip.Choose(6)
check("community preferred when sample big", note == "community, 120 kills", note)
check("community grey row from G count", rows[1][1] == 0 and near(rows[1][2], 100 * 40 / 120), rows[1][1] .. " " .. rows[1][2])
check("community grey children", greys[1][1] == 755 and near(greys[1][2], 30))
rows, greys = ns.Tooltip.Choose(30)
local greyRow
for _, r in ipairs(rows) do if r[1] == 0 then greyRow = r end end
check("grey row estimated when no G count", greyRow and near(greyRow[2], 50), greyRow and greyRow[2])
rows, greys, note = ns.Tooltip.Choose(274300)
check("community for Forever mob", note == "community, 30 kills" and rows[1][2] == 30, note)
check("garbage rejected", ns.Codec.ParseSnapshot("hello") == nil)
check("damaged rejected", ns.Codec.ParseSnapshot("!MD1!@@@@") == nil)

-- reverse search (item -> mobs)
ns.BuildDropIndex()
local items = ns.SearchItems("melted candle")
check("item search finds item, exact first", items[1] and items[1].id == 755 and items[1].rank == 0 and items[1].mobCount > 1,
  items[1] and (items[1].id .. " " .. items[1].mobCount))
local mobs = ns.MobsDropping(755)
local sorted, vermin = true, nil
for i, m in ipairs(mobs) do
  if i > 1 and m.pct > mobs[i - 1].pct then sorted = false end
  if m.id == 6 then vermin = m end
end
check("item search mobs sorted by chance", sorted and #mobs > 1, #mobs)
check("item search uses tooltip numbers (community 30% for Kobold Vermin)", vermin and near(vermin.pct, 30) and vermin.name == "Kobold Vermin",
  vermin and vermin.pct)
check("item search never lists the grey pseudo item", #ns.MobsDropping(ns.GREY) == 0)
items = ns.SearchItems("FROSTED")
check("item search finds Forever item from recordings", items[1] and items[1].id == 99999, items[1] and items[1].name)
mobs = ns.MobsDropping(99999)
check("item search Forever item's mob", mobs[1] and mobs[1].id == 274300 and mobs[1].name == "Coldrasp" and near(mobs[1].pct, 30),
  mobs[1] and (mobs[1].name .. " " .. mobs[1].pct))
check("item search empty query", #ns.SearchItems("  ") == 0)
local base = ns.MobsDropping(5465) -- Small Spider Leg, base data only
check("item search base-only item", base[1] ~= nil and base[1].note:find("1.12 estimate", 1, true) ~= nil, base[1] and base[1].note)

-- gathering in snapshots and item search
check("snapshot S parsed, bad kind ignored", MoldyDropsDB.community.gather[113] and MoldyDropsDB.community.gather[113].kind == 1
  and MoldyDropsDB.community.gather[113][0] == 25 and MoldyDropsDB.community.gather[5] == nil)
gk, grows, gnote = ns.Tooltip.Gather(113)
check("community skinning preferred at 20+ corpses", gk == 1 and gnote == "community, 25 corpses" and grows[1][1] == 2318 and grows[1][2] == 80,
  tostring(gnote))

-- no items, gold and pick pocketing from the snapshot
local c6 = MoldyDropsDB.community.npcs[6]
check("snapshot E and $ parsed, not read as items", c6[-2] == 30 and c6[-3] == 100 and c6[-4] == 5000 and c6[-5] == 10
  and c6[-6] == 90 and c6[3] == nil and c6[30] == nil and c6[100] == nil)
noItems, gold = ns.Tooltip.Extras(6)
check("community no-items and gold", near(noItems, 25) and gold[1] == 10 and gold[2] == 90 and gold[3] == 50,
  tostring(noItems))
check("snapshot pick pocket (S kind 5)", MoldyDropsDB.community.pick[38] and MoldyDropsDB.community.pick[38][0] == 25
  and MoldyDropsDB.community.gather[38] == nil)
playerClass = "ROGUE"
local _, prow, pnote = ns.Tooltip.Pick(38)
check("community pick pocket preferred at 20+", pnote == "community, 25 mobs" and prow[1][1] == 5363 and prow[1][2] == 40, pnote)
ns.BuildDropIndex()
local fromPick
for _, m in ipairs(ns.MobsDropping(5363)) do if m.id == 38 and m.gather == ns.PICKPOCKET then fromPick = m end end
check("item search includes pick pocketing for rogues", fromPick and fromPick.pct == 40)
playerClass = "WARRIOR"
ns.BuildDropIndex()
local leather = ns.MobsDropping(2318)
local boar
for _, m in ipairs(leather) do if m.id == 113 and m.gather == 1 then boar = m end end
check("item search lists skinnable mobs with their profession", boar and boar.pct == 80, boar and boar.pct)
ns.BuildDropIndex()
local scraps = ns.SearchItems("ruined leather scraps")
local fromSkin = 0
for _, m in ipairs(ns.MobsDropping(scraps[1] and scraps[1].id or -1)) do if m.gather == 1 then fromSkin = fromSkin + 1 end end
check("item search: many mobs skinnable for Ruined Leather Scraps", fromSkin > 50, fromSkin)

-- container contents in item search: Murloc Coastrunner (126) drops Small Barnacled Clam (5523, 33.1%)
ns.BuildDropIndex()
local function viaClam(itemID)
  for _, m in ipairs(ns.MobsDropping(itemID)) do if m.id == 126 and m.via == 5523 then return m end end
end
local meat = viaClam(5503)
check("item search: Clam Meat via clam", meat and near(meat.pct, 33.1), meat and meat.pct)
local pearl = viaClam(5498)
check("item search: pearl chance = clam chance x pearl chance", pearl and near(pearl.pct, 33.1 * 0.05), pearl and pearl.pct)
local pearls = ns.SearchItems("small lustrous pearl")
check("item search finds container-only items", pearls[1] and pearls[1].id == 5498 and pearls[1].mobCount > 1, pearls[1] and pearls[1].mobCount)

-- Ctrl+click jumps; a plain click doesn't
ns.ShowItemSearch("small lustrous pearl", 5498)
local row
for _, f in ipairs(frames) do if f.data ~= nil and rawget(f, "OnClick") and type(f.data) == "table" and f.data.id then row = f break end end
local jumped
local realShowSearch = ns.ShowSearch
ns.ShowSearch = function(name, id) jumped = id end
if row then
  ctrl = false; row.OnClick(row)
  check("plain click on a mob row doesn't jump", jumped == nil)
  ctrl = true; row.OnClick(row)
  check("Ctrl+click on a mob row jumps to /drops search for it", jumped == row.data.id, jumped)
  ctrl = false
else
  check("found an item-window mob row to click", false)
end
ns.ShowSearch = realShowSearch

-- jumping between searches swaps windows in place instead of stacking them
ns.ShowSearch("azuregos")
local mobWin = FrameNamed("MoldyDropsSearchFrame")
mobWin.left, mobWin.top = 123, 456 -- the user dragged it here
ns.ShowItemSearch("sack of gems")
local itemWin = FrameNamed("MoldyDropsItemSearchFrame")
check("jump closes the old window", mobWin and not mobWin.shown and itemWin and itemWin.shown)
check("new window opens where the old one was", itemWin and itemWin.left == 123 and itemWin.top == 456,
  itemWin and (itemWin.left .. "," .. itemWin.top))
ns.ShowSearch("azuregos", 6109)
check("jumping back swaps again", mobWin.shown and not itemWin.shown and mobWin.left == 123)
mobWin:Hide()
check("closing the window clears Back history", ns.SearchHistoryDepth() == 0, ns.SearchHistoryDepth())

-- Back button: mob -> item -> mob, then back twice
ns.ShowSearch("azuregos", 6109)
check("fresh search has nothing to go back to", ns.SearchHistoryDepth() == 0, ns.SearchHistoryDepth())
ns.ShowItemSearch("Blue Sack of Gems")     -- Ctrl+click on a drop
local sackID = (ns.SearchItems("Blue Sack of Gems")[1] or {}).id
ns.ShowSearch("defias thug", 38)            -- Ctrl+click on a mob there
check("two jumps recorded", ns.SearchHistoryDepth() == 2, ns.SearchHistoryDepth())
itemWin.left, itemWin.top = 0, 0
mobWin.back.OnClick(mobWin.back)             -- Back
check("Back returns to the item search", itemWin.shown and not mobWin.shown and ns.SearchHistoryDepth() == 1)
check("Back reopens in the same place", itemWin.left == mobWin.left and itemWin.top == mobWin.top)
itemWin.back.OnClick(itemWin.back)           -- Back again
check("Back again returns to the first mob search", mobWin.shown and not itemWin.shown and ns.SearchHistoryDepth() == 0)
local mobs = ns.SearchMobs("azuregos")
check("first search's text and selection restored", mobs[1] and mobs[1].id == 6109)
mobWin.back.OnClick(mobWin.back)             -- nothing left: no-op
check("Back with empty history does nothing", mobWin.shown and ns.SearchHistoryDepth() == 0)
mobWin:Hide()

-- the tooltip hook: loot for mobs you can attack, nothing for friendly NPCs
local tipLines
GameTooltip.GetUnit = function() return "x", "mouseover" end
GameTooltip.AddLine = function() tipLines = tipLines + 1 end
GameTooltip.AddDoubleLine = function() tipLines = tipLines + 1 end
local function hover(npcID, friendly)
  units.mouseover = { guid = guid(npcID, 999), friendly = friendly }
  tipLines = 0
  GameTooltip.hook_OnTooltipSetUnit(GameTooltip)
  units.mouseover = nil
  return tipLines
end
check("tooltip adds loot for a hostile mob", hover(6, false) > 3)
check("tooltip adds nothing for a friendly guard (Orgrimmar Grunt)", hover(3296, true) == 0)
check("tooltip shows enemy-faction guards (attackable)", hover(3296, false) > 0)

-- /drops item opens the item search; the old name is gone
local iw = FrameNamed("MoldyDropsItemSearchFrame")
iw:Hide(); FrameNamed("MoldyDropsSearchFrame"):Hide()
SlashCmdList.MOLDYDROPS("rsearch candle")
check("old /drops rsearch no longer opens the item window", not iw.shown)
SlashCmdList.MOLDYDROPS("item candle")
check("/drops item opens the item window", iw.shown)
iw:Hide()
SlashCmdList.MOLDYDROPS("i candle")
check("/drops i is a short form", iw.shown)
iw:Hide()

-- /drop is registered as an alias, and "s" opens the mob search
check("/drop is registered", SLASH_MOLDYDROPS1 == "/drops" and SLASH_MOLDYDROPS3 == "/drop")
local mw = FrameNamed("MoldyDropsSearchFrame")
mw:Hide()
SlashCmdList.MOLDYDROPS("s vermin") -- what /drop s vermin runs
check("/drop s opens the mob search", mw.shown)
mw:Hide()

-- anything that isn't a subcommand is a mob search; bare /drops is help
local searched
local realShow = ns.ShowSearch
ns.ShowSearch = function(q) searched = q end
SlashCmdList.MOLDYDROPS("  Defias Thug  ")
check("/drops <mob name> searches for the whole text", searched == "Defias Thug", searched)
searched = nil
SlashCmdList.MOLDYDROPS("rsearch candle")
check("old rsearch is now just a mob search for that text", searched == "rsearch candle", searched)
searched = nil
SlashCmdList.MOLDYDROPS("")
SlashCmdList.MOLDYDROPS("help")
check("bare /drops and /drops help show help, not a search", searched == nil)
SlashCmdList.MOLDYDROPS("s kobold")
check("/drops s still searches just the rest", searched == "kobold", searched)
ns.ShowSearch = realShow

-- Shift while the search box has the cursor (the game doesn't see the key)
ns.ShowSearch("kobold vermin", 6)
local sbw = FrameNamed("MoldyDropsSearchFrame")
local function shownKinds()
  local kinds = {}
  for _, row in ipairs(sbw.detail.rows) do
    if row.shown ~= false and type(row.data) == "table" and row.data[3] then kinds[row.data[3]] = true end
  end
  return kinds
end
shift = false
check("search box: grey items collapsed before Shift", not shownKinds().grey)
sbw.box.OnKeyDown(sbw.box, "LSHIFT")
check("search box: Shift pressed in the box expands grey items", shownKinds().grey == true)
sbw.box.OnKeyUp(sbw.box, "LSHIFT")
check("search box: releasing Shift collapses them again", not shownKinds().grey)
sbw.box.OnKeyDown(sbw.box, "A")
check("search box: other keys don't expand", not shownKinds().grey)
check("Shift override is cleared afterwards", ns.shiftOverride == nil)
sbw:Hide()

-- scrollbars on the result list and the details
ns.ShowSearch("wolf")
local many = ns.SearchMobs("wolf")
check("list scrollbar shows when results overflow", #many > 18 and sbw.listBar.shown, #many)
local to = math.min(5, #many - 18)
sbw.listBar.OnValueChanged(sbw.listBar, to) -- drag it
check("dragging the list scrollbar scrolls the list", sbw.buttons[1].result and sbw.buttons[1].result.id == many[to + 1].id,
  #many .. " results, offset " .. to)
sbw.listBar.OnValueChanged(sbw.listBar, 999)
check("list can't scroll past the end", sbw.buttons[18].result and sbw.buttons[18].result.id == many[#many].id)
ns.ShowSearch("kobold vermin")
check("no list scrollbar when everything fits", not sbw.listBar.shown)
shift = true
ns.ShowSearch("azuregos", 6109)
check("detail scrollbar shows for long details (Azuregos, Shift)", sbw.detailBar.shown)
local third = sbw.detail.rows[3].data
sbw.detailBar.OnValueChanged(sbw.detailBar, 2)
check("dragging the detail scrollbar scrolls the details", sbw.detail.rows[1].data == third and third ~= nil)
shift = false
ns.ShowSearch("kobold vermin", 6)
check("no detail scrollbar when everything fits", not sbw.detailBar.shown)
sbw:Hide()

-- hover: item tooltip in the item list; 3D model for mobs
ns.ShowModelPreview(6) -- build the panel so its model can be watched
local preview = FrameNamed("MoldyDropsModelPreview")
local modelArgs
preview.model.SetCreature = function(_, id, display) modelArgs = { id, display } end
ns.HideModelPreview()
local lastLink
GameTooltip.SetHyperlink = function(_, link) lastLink = link end

ns.ShowItemSearch("golden pearl")
local iwin = FrameNamed("MoldyDropsItemSearchFrame")
iwin.buttons[1].OnEnter(iwin.buttons[1])
check("hovering an item in the item list shows its tooltip", lastLink == "item:" .. iwin.buttons[1].result.id, lastLink)
check("no model for items", not preview.shown)
iwin.buttons[1].OnLeave(iwin.buttons[1])
local mobRow
for _, r in ipairs(iwin.detail.rows) do if r.shown and type(r.data) == "table" and r.data.id then mobRow = r break end end
mobRow.OnEnter(mobRow)
check("hovering a mob row shows its 3D model", preview.shown and modelArgs and modelArgs[1] == mobRow.data.id,
  modelArgs and modelArgs[1])
check("model panel sits under the tooltip", preview.shown)
mobRow.OnLeave(mobRow)
check("leaving the row hides the model", not preview.shown)

ns.ShowSearch("azuregos")
local mwin = FrameNamed("MoldyDropsSearchFrame")
modelArgs = nil
mwin.buttons[1].OnEnter(mwin.buttons[1])
check("hovering a mob in the mob list shows its model, with the 1.12 model ID",
  preview.shown and modelArgs and modelArgs[1] == 6109 and modelArgs[2] == 11460, modelArgs and tostring(modelArgs[2]))
mwin.buttons[1].OnLeave(mwin.buttons[1])

-- hovering the big title of the selected entry
modelArgs = nil
mwin.detail.nameHover.OnEnter(mwin.detail.nameHover)
check("hovering the mob title shows its model", preview.shown and modelArgs and modelArgs[1] == 6109)
mwin.detail.nameHover.OnLeave(mwin.detail.nameHover)
check("leaving the title hides the model", not preview.shown)
ns.ShowItemSearch("Gray Sack of Gems")
lastLink = nil
iwin.detail.nameHover.OnEnter(iwin.detail.nameHover)
check("hovering the item title shows the item tooltip", lastLink == "item:17964", lastLink)
iwin.detail.nameHover.OnLeave(iwin.detail.nameHover)
ns.ShowSearch("azuregos")
mwin.buttons[1].OnEnter(mwin.buttons[1])
mwin:Hide()
check("closing the window hides the model", not preview.shown)

-- search window rows stay on one line (long text is cut off with "..." instead of wrapping)
local sw = tostring(SRC["SearchWindow.lua"])
check("list and detail rows don't wrap", sw:find("b.text:SetWordWrap(false)", 1, true) ~= nil
  and sw:find("row.name:SetWordWrap(false)", 1, true) ~= nil)

-- the windows build and fill without errors (stub frames)
local function ok(name, fn)
  local success, err = pcall(fn)
  check(name, success, err)
end
ok("search window opens", function() ns.ShowSearch("kobold") end)
ok("search window selects a given mob", function() ns.ShowSearch("kobold", 6) end)
shift = true
ok("search window redraws with Shift", function() ns.RefreshSearch() end)
shift = false
ok("item window opens", function() ns.ShowItemSearch("candle") end)
ok("item window selects a given item", function() ns.ShowItemSearch("melted candle", 755) end)
ok("export window opens", function() ns.ShowExport() end)
ok("import window opens", function() ns.ShowImport() end)
ok("slash commands", function()
  for _, cmd in ipairs({ "", "search vermin", "item candle", "i candle", "stats", "help" }) do SlashCmdList.MOLDYDROPS(cmd) end
end)

-- stacks: items that can come more than one at a time
local qmin, qmax = ns.Tooltip.Qty("drop", 660, 4338) -- Mageweave Cloth from NPC 660
check("1.12 drop count range", qmin == 1 and qmax == 2, tostring(qmin) .. "-" .. tostring(qmax))
local function lineFor(npcID, itemID)
  for _, l in ipairs(ns.Tooltip.Lines(npcID, 10, false) or {}) do if l[1] == itemID then return l end end
end
local mw = lineFor(660, 4338)
check("drop row shows x1-2", mw and ns.Tooltip.LineText(mw, false):find("x1-2", 1, true), mw and ns.Tooltip.LineText(mw, false))
local single = lineFor(6, 159) -- Refreshing Spring Water: one at a time
check("single items show no count", single == nil or not ns.Tooltip.LineText(single, false):find("x%d"))
qmin, qmax = ns.Tooltip.Qty("gather", 157, 2318)
check("1.12 skinning count range", qmin == 1 and qmax == 2)
qmin, qmax = ns.Tooltip.Qty("content", 5760, 7909)
check("1.12 container count range", qmin == 1 and qmax == 2)
check("count text formats", ns.QtyText(1, 2):find("x1-2", 1, true) and ns.QtyText(2, 2):find("x2", 1, true)
  and ns.QtyText(1, 1) == "" and ns.QtyText(nil, nil) == "")
ns.BuildDropIndex()
local mwMob
for _, m in ipairs(ns.MobsDropping(4338)) do if m.id == 660 then mwMob = m end end
check("item search carries the count", mwMob and mwMob.qty and mwMob.qty[2] == 2)

-- chance of each count, on Shift (1.12: every count in the range equally likely)
do
local cc = ns.Tooltip.CountChances("drop", 660, 4338, mw[2])
check("1.12 count chances split evenly: x1 and x2 each half",
  cc and #cc == 2 and cc[1][1] == 1 and cc[2][1] == 2 and math.abs(cc[1][2] - mw[2] / 2) < 1e-9 and cc[1][2] == cc[2][2])
check("single items have no count chances", ns.Tooltip.CountChances("drop", 6, 159, 5) == nil)
local function countLines(lines, itemID)
  local n, sum = 0, 0
  for _, l in ipairs(lines or {}) do if l[3] == "count" and l[1] == itemID then n, sum = n + 1, sum + l[2] end end
  return n, sum
end
local n0 = countLines(ns.Tooltip.Lines(660, 10, false), 4338)
local n1, sum1 = countLines(ns.Tooltip.Lines(660, 10, true), 4338)
check("no count lines without Shift; one per count with Shift, adding up to the item's chance",
  n0 == 0 and n1 == 2 and math.abs(sum1 - mw[2]) < 1e-9)
check("without Shift the stacked row hints (Shift)", ns.Tooltip.LineText(mw, false):find("(Shift)", 1, true))
local cl
for _, l in ipairs(ns.Tooltip.Lines(660, 10, true)) do if l[3] == "count" and l[5] == 2 then cl = l end end
local cleft = cl and ns.Tooltip.LineText(cl, true)
check("count line reads '    Mageweave Cloth x2'", cleft and cleft:find("^    ") and cleft:find("Mageweave Cloth", 1, true)
  and cleft:find("x2", 1, true), cleft)
local dsec = ns.Tooltip.DropSection(660, 10, true)
local afterNoItems = false
for i, r in ipairs(dsec) do
  if r[3] == nil and r[1]:find("No items") and dsec[i + 1] and dsec[i + 1][3] and dsec[i + 1][3][3] == "count" then afterNoItems = true end
end
check("No items never lands between a row and its count lines", not afterNoItems)
local sl = ns.Tooltip.SectionLines(1, { { 2318, 50 } }, 157, 10, true) -- Light Leather x1-2 from skinning
local sl0 = ns.Tooltip.SectionLines(1, { { 2318, 50 } }, 157, 10, false)
check("section lines: count breakdown on Shift, one line otherwise",
  #sl == 3 and sl[2][3][3] == "count" and sl[2][3][5] == 1 and math.abs(sl[2][3][2] - 25) < 1e-9 and #sl0 == 1
  and sl0[1][1]:find("x1-2", 1, true), #sl .. " " .. #sl0)

-- end to end: the real tooltip for a skinnable mob (NPC 157), Shift up and down
local captured
local oldDouble = GameTooltip.AddDoubleLine
GameTooltip.AddDoubleLine = function(_, l, r) captured[#captured + 1] = { l, r } end
local function tip(npcID, down)
  captured, shift = {}, down
  units.mouseover = { guid = guid(npcID, 998) }
  GameTooltip.hook_OnTooltipSetUnit(GameTooltip)
  units.mouseover, shift = nil, false
  return captured
end
local function skinLines(lines)
  local inSkin, out = false, {}
  for _, l in ipairs(lines) do
    if l[1] == "Skinning" then inSkin = true
    elseif inSkin and l[1]:find("Light Leather", 1, true) then out[#out + 1] = l end
  end
  return out
end
local _, gatherRows = ns.Tooltip.Gather(157)
local leatherPct
for _, r in ipairs(gatherRows) do if r[1] == 2318 then leatherPct = r[2] end end
local up, down = skinLines(tip(157, false)), skinLines(tip(157, true))
check("skinning tooltip without Shift: one Light Leather x1-2 line",
  #up == 1 and up[1][1]:find("x1-2", 1, true) and up[1][1]:find("(Shift)", 1, true), #up)
check("skinning tooltip with Shift: total line, then x1 and x2 at half each",
  #down == 3 and down[2][1]:find("x1", 1, true) and down[3][1]:find("x2", 1, true)
  and down[2][2] == ns.ColoredPct(leatherPct / 2, 1) and down[3][2] == ns.ColoredPct(leatherPct / 2, 1),
  #down .. " " .. tostring(leatherPct))
GameTooltip.AddDoubleLine = oldDouble
end

-- recorded stacks override the 1.12 range
local g660 = guid(660, 1)
Kill(g660, true, "Bloodscalp Witch Doctor")
Loot({ { guid = g660, item = 4338, name = "Mageweave Cloth", q = 1, qty = 3 } })
check("recorded stack size", MoldyDropsDB.own[660] and MoldyDropsDB.own[660].q and MoldyDropsDB.own[660].q[4338][2] == 3)
qmin, qmax = ns.Tooltip.Qty("drop", 660, 4338)
check("recorded count wins over 1.12", qmin == 3 and qmax == 3)
check("recorded count tally", MoldyDropsDB.own[660].c and MoldyDropsDB.own[660].c[4338][3] == 1)
for n = 2, 3 do
  local g = guid(660, n)
  Kill(g, true, "Bloodscalp Witch Doctor")
  Loot({ { guid = g, item = 4338, name = "Mageweave Cloth", q = 1, qty = 1 } })
end
do
  local rc = ns.Tooltip.CountChances("drop", 660, 4338, 60)
  check("recorded tally splits the chance: x1 2 of 3, x3 1 of 3 (none for x2)",
    rc and #rc == 2 and rc[1][1] == 1 and math.abs(rc[1][2] - 40) < 1e-9 and rc[2][1] == 3 and math.abs(rc[2][2] - 20) < 1e-9)
end
local stats, _ = pcall(SlashCmdList.MOLDYDROPS, "stats")
check("stats still works with counts recorded", stats)
local str2 = ns.Codec.Export(MoldyDropsDB, "0.1.0", 16001)
local text2 = ns.Codec.Base64Decode(str2:sub(6))
check("export Q token", text2:find("Q:4338:1:3", 1, true) ~= nil, text2:match("N 660[^\n]*"))
check("export C tokens", text2:find("C:4338:1:2 C:4338:3:1", 1, true) ~= nil, text2:match("N 660[^\n]*"))
local snap2 = "!MD1!" .. js.global:btoa("MD1 S 1795400000 2\nN 660 40 4338:20 Q:4338:1:4 C:4338:1:15 C:4338:4:5 $:40:800:5:30\nS 157 1 30 2318:30 Q:2318:1:3\n")
local comm2 = ns.Codec.ParseSnapshot(snap2)
local c660 = comm2.npcs[660]
check("snapshot Q parsed, no phantom items", c660.q and c660.q[4338][1] == 1 and c660.q[4338][2] == 4
  and c660[1] == nil and c660[4] == nil and c660[40] == nil and c660[4338] == 20 and c660[15] == nil and c660[5] == nil)
check("snapshot C tallies parsed", c660.c and c660.c[4338][1] == 15 and c660.c[4338][4] == 5)
check("snapshot Q on S records", comm2.gather[157].q and comm2.gather[157].q[2318][2] == 3 and comm2.gather[157][1] == nil)

-- luck tags on loot messages (Defias Thug, 1.12 data: Small Red Pouch 0.1%, Spring Water 6.4%)
local function link(id, name) return "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. name .. "]|h|r" end
local gThug = guid(38, 1)
Loot({ { guid = gThug, item = 805, name = "Small Red Pouch", q = 1 }, { guid = gThug, item = 159, name = "Refreshing Spring Water", q = 1 } })
check("loot context remembers the mob and action", ns.lootContext and ns.lootContext.section == "drop" and ns.lootContext.npcID == 38)
local filter = chatFilters.CHAT_MSG_LOOT
check("chat filter registered for loot messages", type(filter) == "function")
local _, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(805, "Small Red Pouch") .. ".")
check("0.1% drop: [chance] (Incredibly lucky!) in orange, right after the link",
  res == "You receive loot: " .. link(805, "Small Red Pouch") .. " |cffff8000[0.10%] (Incredibly lucky!)|r.", res)
_, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(159, "Refreshing Spring Water") .. "x2.")
check("6.4% drop: gold [6.4%] (Lucky!) (stack message too)",
  res and res:find("|cffffd100[6.4%] (Lucky!)|rx2.", 1, true), res)
check("chance colors: white 10%+, gold under 10%, gradient under 2%, grey items grey",
  ns.ChanceColor(45, 1) == "ffffff" and ns.ChanceColor(10, 1) == "ffffff" and ns.ChanceColor(5, 2) == "ffd100"
  and ns.ChanceColor(2, 1) == "ffd100" and ns.ChanceColor(0.1, 1) == "ff8000" and ns.ChanceColor(0.01, 1) == "ff8000"
  and ns.ChanceColor(0.5, 1) ~= "ffd100" and ns.ChanceColor(0.5, 1) ~= "ff8000" and ns.ChanceColor(1, 0) == "9d9d9d",
  ns.ChanceColor(0.5, 1))
local likely = ns.Tooltip.Choose(38)[1] -- the Thug's most likely drop
Loot({ { guid = guid(38, 2), item = likely[1], name = "Likely", q = 1 } })
local likelyMsg = "You receive loot: " .. link(likely[1], "Likely") .. "."
local same0, res0 = filter(nil, "CHAT_MSG_LOOT", likelyMsg)
check("likely item: unchanged by default", same0 == false and res0 == nil)
SlashCmdList.MOLDYDROPS("chance")
check("/drops chance turns on the always-show option", MoldyDropsDB.settings.chanceAlways == true)
_, res = filter(nil, "CHAT_MSG_LOOT", likelyMsg)
check("always-show: likely item gets a white [chance], no label",
  res == "You receive loot: " .. link(likely[1], "Likely") .. " |cffffffff[" .. ns.FormatPct(likely[2]) .. "]|r.", res)
MoldyDropsDB.settings.luck = false
Loot({ { guid = gThug, item = 805, name = "Small Red Pouch", q = 1 } })
_, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(805, "Small Red Pouch") .. ".")
check("always-show with luck tags off: colored chance, no label", res and res:find("|cffff8000[0.10%]|r.", 1, true), res)
MoldyDropsDB.settings.luck = true
SlashCmdList.MOLDYDROPS("chance")
check("/drops chance turns it back off", not MoldyDropsDB.settings.chanceAlways)
local same, unchanged = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(752, "Red Burlap Bandana") .. ".")
check("item not from this corpse: unchanged", same == false and unchanged == nil)
_, res = filter(nil, "CHAT_MSG_LOOT", "Bob receives loot: " .. link(805, "Small Red Pouch") .. ".")
check("other players' loot: unchanged", res == nil)
MoldyDropsDB.settings.luck = false
_, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(805, "Small Red Pouch") .. ".")
check("/drops luck off: unchanged", res == nil)
SlashCmdList.MOLDYDROPS("luck")
check("/drops luck toggles it back on", MoldyDropsDB.settings.luck == true)
now = now + 31
_, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(805, "Small Red Pouch") .. ".")
check("old loot context isn't used", res == nil)
now = now + 10
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 8613)
Loot({ { guid = guid(113, 5), item = 2318, name = "Light Leather", q = 1 } })
check("skinning sets a gathering context", ns.lootContext.section == "gather" and ns.lootContext.npcID == 113)
now = now + 10
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "x", 8613)
Loot({ { guid = guid(113, 6), item = 2318, name = "Light Leather", q = 1, qty = 2 } })
do
  local sk = MoldyDropsDB.ownGather[113]
  check("skinning a stack of 2 is tallied in the gathering record (not the drops)",
    sk and sk.c and sk.c[2318] and sk.c[2318][2] == 1 and sk.c[2318][1] == 1 and sk.q[2318][2] == 2
    and not (MoldyDropsDB.own[113] and MoldyDropsDB.own[113].c and MoldyDropsDB.own[113].c[2318]),
    sk and sk.c and sk.c[2318] and tostring(sk.c[2318][1]) .. "/" .. tostring(sk.c[2318][2]))
  local gc = ns.Tooltip.CountChances("gather", 113, 2318, 100)
  check("gathering count chances use the recorded tally", gc and #gc == 2 and gc[1][2] == 50 and gc[2][2] == 50)
end
_, res = filter(nil, "CHAT_MSG_LOOT", "You receive loot: " .. link(2318, "Light Leather") .. ".")
check("common gathering result (80%): no tag", res == nil)
now = now + 10

-- fast autoloot: the window is empty by the time the addon looks
local function chatLoot(id, name, count)
  Fire("CHAT_MSG_LOOT", "You receive loot: " .. link(id, name) .. (count and ("x" .. count) or "") .. ".")
end
now = now + 10
local gW1 = guid(299, 1) -- Diseased Young Wolf
units.target = { guid = gW1, dead = true }
loot = {}
Fire("LOOT_READY")
chatLoot(2672, "Stringy Wolf Meat")
Fire("LOOT_CLOSED")
units.target = nil
local w = MoldyDropsDB.own[299]
check("emptied window: kill credited to your dead target", w and w[0] == 1, w and w[0])
check("emptied window: item picked up from the loot chat line", w and w[2672] == 1)
check("emptied window: not counted as no items", w and (w[-2] or 0) == 0)

local gW2 = guid(299, 2)
loot = { { guid = gW2, item = 2672, name = "Stringy Wolf Meat", q = 1 }, { guid = gW2, item = 7073, name = "Broken Fang", q = 0 } }
Fire("LOOT_READY") -- read before autoloot takes it
loot = {}
Fire("LOOT_OPENED") -- window already empty
chatLoot(2672, "Stringy Wolf Meat")
chatLoot(7073, "Broken Fang")
Fire("LOOT_CLOSED")
check("LOOT_READY + LOOT_OPENED + chat: one kill, each item once", w[0] == 2 and w[2672] == 2 and w[7073] == 1, w[0] .. " " .. w[2672])
check("grey corpse counted once", (w[-1] or 0) == 1)

local gW3 = guid(299, 3)
units.target = { guid = gW3, dead = true }
loot = {}
Fire("LOOT_OPENED")
Fire("CHAT_MSG_LOOT", "Bob receives loot: " .. link(2672, "Stringy Wolf Meat") .. ".")
Fire("LOOT_CLOSED")
units.target = nil
check("other players' loot lines aren't credited", w[0] == 3 and w[2672] == 2 and w[-2] == 1, w[2672])
chatLoot(2672, "Stringy Wolf Meat") -- long after: no session
check("loot lines outside a loot window are ignored", w[2672] == 2)

SlashCmdList.MOLDYDROPS("debug")
local before = #out
Loot({ { guid = guid(299, 4), item = 2672, name = "Stringy Wolf Meat", q = 1 } })
local printed = false
for i = before + 1, #out do if out[i]:find("[debug]", 1, true) then printed = true end end
check("/drops debug prints each loot window", printed)
SlashCmdList.MOLDYDROPS("debug")

-- quest items are left out
local function has(list, id)
  for i = 1, #(list or {}) - 1, 2 do if list[i] == id then return true end end
  return false
end
check("1.12 data has no quest-only drops (Tough Wolf Meat)", not has(ns.base[299], 750))
check("quest-class items that drop for everyone stay (Captain Sander's Treasure Map)", has(ns.base[127], 1357))
local gQ = guid(299, 50)
local meatBefore = w[2672]
Loot({ { guid = gQ, item = 2672, name = "Stringy Wolf Meat", q = 1 },
       { guid = gQ, item = 55555, name = "Quest Thing", q = 1, quest = true } })
check("quest item (loot window flag) not recorded", w[55555] == nil and w[2672] == meatBefore + 1, w[2672])
local gQ2 = guid(299, 51)
units.target = { guid = gQ2, dead = true }
loot = {}
Fire("LOOT_READY")
chatLoot(884, "Ghoul Rib") -- quest item seen only in chat: item class decides
Fire("LOOT_CLOSED")
units.target = nil
check("quest item (from chat) not recorded", w[884] == nil)
check("corpse with only quest items counts as no items", w[-2] == 2, w[-2])
MoldyDropsDB.own[999001] = { [0] = 30, [884] = 10, [2589] = 6 } -- recorded before this change
local qrows = ns.Tooltip.Choose(999001)
local hasRib = false
for _, r in ipairs(qrows) do if r[1] == 884 then hasRib = true end end
check("quest items already recorded are hidden", not hasRib and qrows[1] and qrows[1][1] == 2589)
MoldyDropsDB.own[999001] = nil
-- Quest-class items that drop for everyone stay (Gorilla Fang, Mistvale Gorilla)
check("Gorilla Fang is in the 1.12 data", has(ns.base[1108], 2799))
check("Gorilla Fang isn't a quest item, even with the loot window's flag",
  not ns.IsQuestItem(2799) and not ns.IsQuestItem(2799, true))
itemClass[2799] = 12
local gG = guid(1108, 60)
local fangBefore = (MoldyDropsDB.own[1108] or {})[2799] or 0
Loot({ { guid = gG, item = 2799, name = "Gorilla Fang", q = 1, quest = true } })
check("Gorilla Fang is recorded", MoldyDropsDB.own[1108] and MoldyDropsDB.own[1108][2799] == fangBefore + 1)
local quest1 = next(ns.questOnly)
check("items that only drop on a quest are quest items", quest1 and ns.IsQuestItem(quest1))

-- quest drops: their own section, only while a quest needs the item
local function sectionKinds(npcID)
  local kinds = {}
  for _, s in ipairs(ns.Tooltip.Sections(npcID)) do kinds[#kinds + 1] = s[1] end
  return kinds
end
local function questRows(npcID)
  for _, s in ipairs(ns.Tooltip.Sections(npcID)) do if s[1] == ns.QUEST then return s[2] end end
end
check("1.12 quest drop: Young Wolf gives Tough Wolf Meat 80% (quest 33)",
  has(ns.questDrops[299], 750) and ns.questDrops[299][2] == 80 and ns.questFor[750][1] == 33)
check("no quest section when not on the quest", questRows(299) == nil, table.concat(sectionKinds(299), ","))
questLog[33] = { objectives = { { text = "Tough Wolf Meat: 3/8", type = "item", finished = false } } }
local qr = questRows(299)
check("quest section while the quest needs it", qr and qr[1][1] == 750 and qr[1][2] == 80)
check("quest drops stay out of the normal drops", not has(ns.base[299], 750))
local _, _, qnote = ns.Tooltip.Quest(299)
check("quest section says it's per kill while on the quest", qnote:find("quest"))
questLog[33].objectives[1].finished = true
check("no quest section once the objective is done", questRows(299) == nil)
questLog[33] = { objectives = {} } -- no matching objective: quest completeness decides
check("no matching objective: shown until the quest is complete", questRows(299) ~= nil)
questLog[33].complete = true
check("no matching objective: hidden once complete", questRows(299) == nil)
questLog[33] = { objectives = { { text = "Tough Wolf Meat: 0/8", type = "item", finished = false } } }
ns.BuildDropIndex()
local qm = ns.MobsDropping(750)
local wolf
for _, m in ipairs(qm) do if m.id == 299 then wolf = m end end
check("item search lists quest drops you need", wolf and wolf.gather == ns.QUEST and wolf.pct == 80)
ns.lootContext = { at = GetTime(), section = "drop", npcID = 299 }
check("no luck tag for a likely quest drop", ns.LuckTag(750) == nil)
questLog[33] = nil
ns.BuildDropIndex()
check("item search hides quest drops you don't need", #ns.MobsDropping(750) == 0)
local rareQ, rareNpc
for npc, list in pairs(ns.questDrops) do
  for i = 1, #list - 1, 2 do if list[i + 1] < 5 then rareNpc, rareQ = npc, list[i] break end end
  if rareQ then break end
end
ns.lootContext = { at = GetTime(), section = "drop", npcID = rareNpc }
check("luck tag uses the quest chance", rareQ and ns.LuckTag(rareQ) ~= nil, tostring(rareNpc) .. " " .. tostring(rareQ))
ns.lootContext = nil

-- options (AceConfig): registered in the game's settings, opened by /drops options
check("options table registered with AceConfig", type(aceRegistered.MoldyDrops) == "function")
check("options added to the game's AddOns settings", aceBlizAdded == "MoldyDrops")
SlashCmdList.MOLDYDROPS("options")
check("/drops options opens the game's options at MoldyDrops", openedCategory == 42, openedCategory)
local opts = aceRegistered.MoldyDrops()
local a = opts.args
check("options include every setting", a.enabled and a.instances and a.luck and a.debug and a.topN
  and a.topN.type == "range" and a.topN.min == 1 and a.topN.max == 10 and a.topN.step == 1)
local function dropItemRows(npcID)
  local n = 0
  for _, r in ipairs(ns.Tooltip.DropSection(npcID, ns.TopN(), false)) do
    if r[3] and r[3][3] == nil then n = n + 1 end
  end
  return n
end
check("default: 5 items in the tooltip", a.topN.get() == 5 and dropItemRows(7044) == 5)
a.topN.set(nil, 3)
check("range sets the tooltip item count", ns.TopN() == 3 and dropItemRows(7044) == 3 and a.topN.get() == 3)
a.topN.set(nil, 5)
a.luck.set(nil, false)
check("toggle changes the setting", MoldyDropsDB.settings.luck == false and a.luck.get() == false)
aceNotified = nil
SlashCmdList.MOLDYDROPS("luck")
check("slash command refreshes the options panel", MoldyDropsDB.settings.luck == true and aceNotified == "MoldyDrops")
a.instances.set(nil, true)
check("dungeons and raids option flips open-world-only", MoldyDropsDB.settings.openWorldOnly == false and a.instances.get() == true)
a.instances.set(nil, false)
a.enabled.set(nil, false)
check("tooltip toggle", MoldyDropsDB.settings.enabled == false)
a.enabled.set(nil, true)
local realOpen = Settings.OpenToCategory
Settings.OpenToCategory = function() error("not available") end
aceOpened = nil
ns.ShowOptions()
check("falls back to AceConfig's own window", aceOpened == "MoldyDrops")
Settings.OpenToCategory = realOpen
-- the tooltip setting doesn't limit the search window
MoldyDropsDB.settings.topN = 2
ns.ShowSearch("black drake", 7044)
local sw2 = FrameNamed("MoldyDropsSearchFrame")
local shownDrops = 0
for _, row in ipairs(sw2.detail.rows) do
  if row.shown and type(row.data) == "table" and row.data[3] == nil and type(row.data[1]) == "number" then
    shownDrops = shownDrops + 1
  end
end
local allDrops = #ns.Tooltip.Choose(7044)
check("search window shows every drop even with the tooltip set to 2", allDrops > 2 and shownDrops == allDrops,
  shownDrops .. " of " .. allDrops)
check("while the tooltip shows 2", dropItemRows(7044) == 2)
MoldyDropsDB.settings.topN = 5
sw2:Hide()

-- reset clears everything you recorded (last, since it wipes the test data)
SlashCmdList.MOLDYDROPS("reset")
check("reset without confirm keeps data", next(MoldyDropsDB.own) ~= nil)
SlashCmdList.MOLDYDROPS("reset confirm")
check("reset confirm clears drops, gathering and pick pocketing",
  next(MoldyDropsDB.own) == nil and next(MoldyDropsDB.ownGather) == nil and next(MoldyDropsDB.ownPick) == nil)

log(("%d failures"):format(fails))
return table.concat(out, "\n")