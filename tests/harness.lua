local js = require "js"
local SRC = js.global.SRC
local out = {}
local fails = 0
local function log(s) out[#out + 1] = tostring(s) end
local function check(name, cond, extra)
  if cond then log("PASS " .. name) else fails = fails + 1; log("FAIL " .. name .. (extra and (" :: " .. tostring(extra)) or "")) end
end

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
function CreateFrame()
  local f = Stub()
  f.events = {}
  f.RegisterEvent = function(self, e) self.events[e] = true end
  f.UnregisterEvent = function(self, e) self.events[e] = nil end
  f.SetScript = function(self, k, fn) self[k] = fn end
  f.HookScript = function(self, k, fn) self["hook_" .. k] = fn end
  frames[#frames + 1] = f
  return f
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
C_Item = { GetItemInfo = function() return nil end }
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
function GetLootSourceInfo(slot) return loot[slot].guid, 1 end
function GetLootSlotType(slot) return loot[slot].money and 2 or 1 end
function GetLootSlotLink(slot) return loot[slot].item and ("|cffffffff|Hitem:" .. loot[slot].item .. "::::::::|h[x]|h|r") end
function GetLootSlotInfo(slot) return nil, loot[slot].name, 1, nil, loot[slot].q end
function IsFishingLoot() return false end
local shift = false
function IsShiftKeyDown() return shift end
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
end

-- 1: killed and looted (candle + money)
local g1 = guid(6, 1)
Kill(g1, true)
Loot({ { guid = g1, item = 755, name = "Melted Candle", q = 0 }, { guid = g1, money = true } })
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

local function near(a, b) return math.abs(a - b) < 0.01 end

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
check("search special chars are literal", #ns.SearchMobs("%") == 0 and #ns.SearchMobs("(") == 0)

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
check("export N line with grey count", text:find("\nN 6 3 159:1 755:2 G:2\n", 1, true) ~= nil)
check("export M line", text:find("\nM 274300 Coldrasp", 1, true) ~= nil)
check("export I line", text:find("\nI 755 0 Melted Candle", 1, true) ~= nil)
check("export mob count", n == 2, n)
local ok, err = ns.Codec.ParseSnapshot(str)
check("upload string rejected by import", ok == nil and err:find("upload string") ~= nil, err)

-- snapshot import
local snapText = "MD1 S 1795400000 7\nN 6 120 755:36 159:8 4536:15 G:40\nN 30 50 1476:25 5465:10\nN 274300 30 99999:9\nI 99999 3 Skyborne Trinket\nM 274300 Coldrasp\nM 274301 Gale Wisp\nZ future record\n"
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
check("rsearch finds item, exact first", items[1] and items[1].id == 755 and items[1].rank == 0 and items[1].mobCount > 1,
  items[1] and (items[1].id .. " " .. items[1].mobCount))
local mobs = ns.MobsDropping(755)
local sorted, vermin = true, nil
for i, m in ipairs(mobs) do
  if i > 1 and m.pct > mobs[i - 1].pct then sorted = false end
  if m.id == 6 then vermin = m end
end
check("rsearch mobs sorted by chance", sorted and #mobs > 1, #mobs)
check("rsearch uses tooltip numbers (community 30% for Kobold Vermin)", vermin and near(vermin.pct, 30) and vermin.name == "Kobold Vermin",
  vermin and vermin.pct)
check("rsearch never lists the grey pseudo item", #ns.MobsDropping(ns.GREY) == 0)
items = ns.SearchItems("FROSTED")
check("rsearch finds Forever item from recordings", items[1] and items[1].id == 99999, items[1] and items[1].name)
mobs = ns.MobsDropping(99999)
check("rsearch Forever item's mob", mobs[1] and mobs[1].id == 274300 and mobs[1].name == "Coldrasp" and near(mobs[1].pct, 30),
  mobs[1] and (mobs[1].name .. " " .. mobs[1].pct))
check("rsearch empty query", #ns.SearchItems("  ") == 0)
local base = ns.MobsDropping(5465) -- Small Spider Leg, base data only
check("rsearch base-only item", base[1] ~= nil and base[1].note:find("1.12 estimate", 1, true) ~= nil, base[1] and base[1].note)

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
  for _, cmd in ipairs({ "", "search vermin", "rsearch candle", "stats", "help" }) do SlashCmdList.MOLDYDROPS(cmd) end
end)

log(("%d failures"):format(fails))
return table.concat(out, "\n")