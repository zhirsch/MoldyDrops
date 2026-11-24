local _, ns = ...

-- Records what drops from the mobs you kill.
--
-- A drop rate is (corpses that had the item) / (kills), so empty corpses
-- matter as much as full ones. Rules that keep the numbers honest:
--   * Only record while solo. In a group, other people loot corpses you
--     never see, which would undercount drops.
--   * A kill counts when you loot the corpse, or when a mob you were fighting
--     (you or your pet on its threat table, not tagged by someone else) dies
--     and its corpse turns out to be empty. Corpses you walk past without
--     looting don't count. (If the client lacks CanLootUnit, every such
--     death counts instead.)
--   * Deaths are seen through unit tokens (target, mouseover, focus,
--     nameplates), because modern clients, WoW Forever included, don't let
--     addons read the combat log. Where the combat log is readable, its
--     PARTY_KILL events are used as well. Turn on enemy nameplates so mobs you
--     aren't targeting are seen too.
--   * Each corpse is recorded once (re-opening the loot window is ignored).
--   * Skinning, herbalism and mining a corpse are recorded separately
--     (ns.db.ownGather), once per corpse, solo or not. So is pick
--     pocketing (ns.db.ownPick), once per mob.
--   * For each counted kill it also notes whether the corpse had no items
--     ([-2]) and how much gold it had ([-3] count, [-4] sum, [-5] min, [-6] max).
local Recorder = {}
ns.Recorder = Recorder

local counted = {}    -- [guid] = true once its kill has been counted
local looted = {}     -- [guid] = true once its loot has been recorded
local tapDenied = {}  -- [guid] = true if we saw it tagged by someone else
local names = {}      -- [guid] = unit name, from the combat log or a unit token
local engaged = {}    -- [guid] = true if you or your pet were on its threat table
local died = {}       -- [guid] = true once its death has been handled
local gathered = {}   -- [guid] = true once its gathering loot has been recorded
local pickpocketed = {} -- [guid] = true once its pick pocket loot has been recorded
local lastGatherAt = 0
local lastGatherKind
-- spell name -> kind (1 skinning, 2 herbalism, 3 mining, 4 engineering, 5 pick pocket)
local gatherSpells = { Skinning = 1, ["Herb Gathering"] = 2, Herbalism = 2, Mining = 3, ["Pick Pocket"] = 5 }

local LOOT_SLOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or LOOT_SLOT_ITEM or 1

local function NpcIDFromGUID(guid)
  if not guid then return nil end
  local unitType, _, _, _, _, npcID = strsplit("-", guid)
  if unitType == "Creature" then return tonumber(npcID) end
end
ns.NpcIDFromGUID = NpcIDFromGUID

local function IsSolo()
  if IsInGroup then return not IsInGroup() end
  return GetNumPartyMembers() == 0 and GetNumRaidMembers() == 0
end

local function Entry(npcID)
  local own = ns.db.own
  local e = own[npcID]
  if not e then
    e = { [0] = 0 }
    own[npcID] = e
  end
  return e
end

-- Negative keys in a drop entry, next to [0] = kills and [-1] = grey corpses.
local NO_ITEMS, GOLD_N, GOLD_SUM, GOLD_MIN, GOLD_MAX = -2, -3, -4, -5, -6
ns.ENTRY_KEYS = { NO_ITEMS = NO_ITEMS, GOLD_N = GOLD_N, GOLD_SUM = GOLD_SUM, GOLD_MIN = GOLD_MIN, GOLD_MAX = GOLD_MAX }

-- Counts a kill once per corpse; returns true if it was counted just now.
local function CountKill(guid)
  if counted[guid] then return false end
  local npcID = NpcIDFromGUID(guid)
  if not npcID then return false end
  if ns.db.settings.openWorldOnly and IsInInstance() then return false end
  counted[guid] = true
  local e = Entry(npcID)
  e[0] = e[0] + 1
  -- Remember names of mobs the bundled data doesn't know (new in WoW Forever).
  local name = names[guid]
  if name and not ns.db.mobs[npcID] and not (ns.mobs and ns.mobs[npcID] and ns.mobs[npcID][1] == name) then
    ns.db.mobs[npcID] = { name }
  end
  return true
end

-- A counted corpse had no items (it may still have had gold).
local function NoteNoItems(guid)
  local e = Entry(NpcIDFromGUID(guid))
  e[NO_ITEMS] = (e[NO_ITEMS] or 0) + 1
end

-- A counted corpse had this much copper.
local function NoteGold(guid, copper)
  local e = Entry(NpcIDFromGUID(guid))
  e[GOLD_N] = (e[GOLD_N] or 0) + 1
  e[GOLD_SUM] = (e[GOLD_SUM] or 0) + copper
  e[GOLD_MIN] = math.min(e[GOLD_MIN] or copper, copper)
  e[GOLD_MAX] = math.max(e[GOLD_MAX] or copper, copper)
end

-- Modern clients can hand addons "secret" values they aren't allowed to read.
local function Plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

local function OnThreatTable(unit)
  if not UnitThreatSituation then return false end
  for _, who in ipairs({ "player", "pet" }) do
    if UnitExists(who) and Plain(UnitThreatSituation(who, unit)) ~= nil then return true end
  end
  return false
end

-- Is this mob fighting you? Threat first; if that's unavailable, whether
-- it's in combat and targeting you or your pet.
local function IsEngaged(unit)
  if OnThreatTable(unit) then return true end
  if UnitAffectingCombat and Plain(UnitAffectingCombat(unit)) and UnitIsUnit then
    local t = unit .. "target"
    return UnitExists(t) and (UnitIsUnit(t, "player") or UnitIsUnit(t, "pet")) or false
  end
  return false
end

-- A mob you were fighting died.
local function OnDeath(guid)
  if died[guid] or counted[guid] then return end
  if not IsSolo() or tapDenied[guid] or not engaged[guid] or not NpcIDFromGUID(guid) then return end
  died[guid] = true
  if CanLootUnit and C_Timer then
    -- Count the kill now only if the corpse is empty. A corpse with loot
    -- counts when you loot it, so corpses you skip don't drag rates down.
    C_Timer.After(1.5, function()
      local hasLoot = Plain(CanLootUnit(guid))
      if hasLoot == false and not looted[guid] and CountKill(guid) then NoteNoItems(guid) end
    end)
  else
    -- No way to tell empty corpses from skipped ones: assume you loot everything.
    CountKill(guid)
  end
end

local function NoteUnit(unit)
  if not unit or not UnitExists(unit) then return end
  local guid = Plain(UnitGUID(unit))
  if not guid or not NpcIDFromGUID(guid) then return end
  names[guid] = Plain(UnitName(unit)) or names[guid]
  if UnitIsDead(unit) then
    OnDeath(guid)
    return
  end
  if UnitIsTapDenied and Plain(UnitIsTapDenied(unit)) then
    tapDenied[guid] = true
  elseif IsEngaged(unit) then
    engaged[guid] = true
  end
end

local GetCombatLogInfo = CombatLogGetCurrentEventInfo or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)

local function OnCombatLog()
  local ok, _, subevent, _, sourceGUID, _, _, _, destGUID, destName = pcall(GetCombatLogInfo)
  if not ok or Plain(subevent) ~= "PARTY_KILL" then return end
  sourceGUID, destGUID, destName = Plain(sourceGUID), Plain(destGUID), Plain(destName)
  if not destGUID or not NpcIDFromGUID(destGUID) then return end
  if destName then names[destGUID] = destName end
  if sourceGUID ~= UnitGUID("player") and sourceGUID ~= UnitGUID("pet") then return end
  engaged[destGUID] = true -- your killing blow
  OnDeath(destGUID)
end

local LOOT_SLOT_MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2

-- Widens the recorded min/max count of each item in an entry (e.q[itemID] = { min, max }).
local function NoteCounts(e, n)
  if not n then return end
  e.q = e.q or {}
  for itemID, count in pairs(n) do
    local q = e.q[itemID]
    if q then
      q[1], q[2] = math.min(q[1], count), math.max(q[2], count)
    else
      e.q[itemID] = { count, count }
    end
  end
end

local PICKPOCKET = 5
local SESSION_GRACE = 2 -- seconds after the loot window closes to still accept loot chat lines

local function Debug(msg)
  if ns.db and ns.db.settings.debug then ns.Print("|cff808080[debug]|r " .. msg) end
end
ns.Debug = Debug

-- One loot window = one mob (WoW Forever has no area looting). A session
-- tracks that mob while its loot window is open and briefly after, and
-- collects what came out of it from three places, whichever sees it first:
--   * the loot slots on LOOT_READY (before autoloot takes anything),
--   * the loot slots on LOOT_OPENED,
--   * your "You receive loot:" chat lines (which still arrive when fast
--     autoloot empties the window before the addon can read it).
local session

local function MobName(guid)
  local npcID = NpcIDFromGUID(guid)
  return (names[guid] or (npcID and ns.MobInfo(npcID)) or ("NPC " .. tostring(npcID)))
end

-- The one mob this loot window belongs to.
local function CorpseGUID()
  for slot = 1, GetNumLootItems() do
    local guid = Plain(GetLootSourceInfo(slot))
    if NpcIDFromGUID(guid) then return guid end
  end
  -- Nothing readable (e.g. autoloot already emptied it): the dead mob you're
  -- targeting or pointing at.
  for _, unit in ipairs({ "target", "mouseover" }) do
    local guid = Plain(UnitGUID(unit))
    if guid and NpcIDFromGUID(guid) and UnitIsDead(unit) then return guid end
  end
end

-- The table an item gets counted into for this session (nil if not recording).
local function SessionEntry(s)
  if s.skip then return nil end
  if s.section == "drop" then return Entry(s.npcID) end
  local tbl = s.kind == PICKPOCKET and ns.db.ownPick or ns.db.ownGather
  local e = tbl[s.npcID]
  if not e or e.kind ~= s.kind then
    e = { kind = s.kind, [0] = 0 }
    tbl[s.npcID] = e
  end
  return e
end

-- An item came out of the session's mob (counted once per item per mob).
local function AddItem(s, itemID, count, name, quality)
  count = math.max(1, tonumber(count) or 1)
  if name and not ns.db.items[itemID] then ns.db.items[itemID] = { name, quality or 1 } end
  s.counts[itemID] = math.max(s.counts[itemID] or 0, count)
  if s.seen[itemID] then return end
  s.seen[itemID] = true
  s.anyItem = true
  local e = SessionEntry(s)
  if not e then return end
  e[itemID] = (e[itemID] or 0) + 1
  if s.section == "drop" then
    local _, q = ns.ItemInfo(itemID)
    if (quality or q) == 0 and not s.grey then
      s.grey = true
      e[-1] = (e[-1] or 0) + 1 -- corpses with at least one grey item
    end
  end
  Debug(("  %s: %s x%d"):format(MobName(s.guid), name or ns.ItemInfo(itemID), count))
end

-- Reads whatever is still in the loot window into the session.
local function ReadSlots(s)
  for slot = 1, GetNumLootItems() do
    local slotType = GetLootSlotType(slot)
    local _, qty = GetLootSourceInfo(slot)
    qty = tonumber(Plain(qty))
    if slotType == LOOT_SLOT_MONEY then
      -- For coins, the source quantity is the amount in copper.
      if qty and qty > 0 then s.copper = math.max(s.copper or 0, qty) end
    elseif slotType == LOOT_SLOT_ITEM then
      local link = GetLootSlotLink(slot)
      local itemID = link and tonumber(link:match("item:(%d+)"))
      if itemID then
        local _, name, slotQty, _, quality = GetLootSlotInfo(slot)
        AddItem(s, itemID, qty or slotQty, name, quality)
      end
    end
  end
end

-- Wraps up a session: no-items, gold and stack counts for drops; stack
-- counts for gathering and pick pocketing.
local function FinishSession(s)
  if not s or s.finished then return end
  s.finished = true
  local e = SessionEntry(s)
  if not e then return end
  if s.section == "drop" then
    if not s.anyItem then NoteNoItems(s.guid) end
    if s.copper then NoteGold(s.guid, s.copper) end
  end
  NoteCounts(e, s.counts)
  Debug(("finished %s (%s)%s"):format(MobName(s.guid), s.section, s.anyItem and "" or ", no items"))
end

local function StartSession(event)
  -- LOOT_READY then LOOT_OPENED for the same window: just read again.
  if session and session.open then
    ReadSlots(session)
    return
  end
  FinishSession(session)
  session = nil
  ns.lootContext = nil
  if IsFishingLoot and IsFishingLoot() then Debug(event .. ": fishing, ignored") return end

  local section, kind = "drop", nil
  if GetTime() - lastGatherAt < 3 and lastGatherKind then
    kind = lastGatherKind
    section = kind == PICKPOCKET and "pick" or "gather"
  end
  local guid = CorpseGUID()
  local targetGUID = Plain(UnitGUID("target"))
  local targetAlive = targetGUID and NpcIDFromGUID(targetGUID) and not UnitIsDead("target")
  if section == "pick" and not guid and targetAlive then
    guid = targetGUID -- pick pocket window already emptied: it was your target
  elseif section == "drop" and targetAlive and guid == targetGUID then
    section, kind = "pick", PICKPOCKET -- the loot says it came from your living target
  end
  if not guid then Debug(event .. ": couldn't tell which mob this loot is from") return end

  local s = {
    guid = guid, npcID = NpcIDFromGUID(guid), section = section, kind = kind,
    seen = {}, counts = {}, open = true,
  }
  session = s
  ns.lootContext = { at = GetTime(), section = section, npcID = s.npcID }

  local done = section == "pick" and pickpocketed or section == "gather" and gathered or looted
  if ns.db.settings.openWorldOnly and IsInInstance() then
    s.skip = "in an instance"
  elseif done[guid] then
    s.skip = "already recorded"
  elseif section == "drop" and not IsSolo() then
    s.skip = "in a group"
  end
  if not s.skip then
    done[guid] = true
    if section == "drop" then
      CountKill(guid)
      if not counted[guid] then s.skip = "kill not counted" end
    else
      local e = SessionEntry(s)
      e[0] = e[0] + 1
    end
  end
  Debug(("%s: %s (%s)%s"):format(event, MobName(guid), section, s.skip and (", not recorded: " .. s.skip) or ""))
  ReadSlots(s)
end

local function OnLootClosed()
  local s = session
  if not s then return end
  s.open = false
  s.closedAt = GetTime()
  C_Timer.After(SESSION_GRACE, function() FinishSession(s) end)
end

-- "You receive loot: [item]" / "...x3" in the client's language.
local selfLootPrefixes
local function SelfLootPrefixes()
  if selfLootPrefixes then return selfLootPrefixes end
  selfLootPrefixes = {}
  for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE }) do
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%s")
    if prefix and prefix ~= "" then selfLootPrefixes[#selfLootPrefixes + 1] = prefix end
  end
  if #selfLootPrefixes == 0 then selfLootPrefixes[1] = "You receive loot: " end
  return selfLootPrefixes
end
ns.SelfLootPrefixes = SelfLootPrefixes

-- Your own loot chat line: credit the item to the mob being looted.
local function OnLootMessage(msg)
  local s = session
  if not s or s.finished or type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return end
  if not s.open and GetTime() - (s.closedAt or 0) > SESSION_GRACE then return end
  local mine = false
  for _, prefix in ipairs(SelfLootPrefixes()) do
    if msg:sub(1, #prefix) == prefix then mine = true break end
  end
  if not mine then return end
  local itemID = tonumber(msg:match("|Hitem:(%d+)"))
  if not itemID then return end
  local count = tonumber(msg:match("|h|r%s*x(%d+)")) or 1
  local name = msg:match("|h%[(.-)%]|h")
  AddItem(s, itemID, count, name)
end

-- Game functions recording can't work without.
local REQUIRED = {
  "GetNumLootItems", "GetLootSourceInfo", "GetLootSlotType", "GetLootSlotLink", "GetLootSlotInfo",
}

local function IsMobToken(unit)
  return unit == "target" or unit == "focus" or unit == "mouseover"
    or (type(unit) == "string" and unit:find("^nameplate%d+$") ~= nil)
end

function Recorder:Init()
  local missing = {}
  for _, fn in ipairs(REQUIRED) do
    if type(_G[fn]) ~= "function" then missing[#missing + 1] = fn end
  end
  if #missing > 0 then
    ns.recordingDisabled = table.concat(missing, ", ")
    ns.Print("loot recording is off: this game client has no " .. ns.recordingDisabled ..
      ". The tooltip and search still work.")
    return
  end

  -- Localized names of the gathering spells (the English ones are built in).
  for id, kind in pairs({ [8613] = 1, [2366] = 2, [2575] = 3, [921] = 5 }) do
    local name = ns.SpellName(id)
    if name then gatherSpells[name] = kind end
  end

  local f = CreateFrame("Frame")
  -- Register one at a time: an event this client doesn't have is an error.
  local function Register(event) return pcall(f.RegisterEvent, f, event) end
  for _, event in ipairs({
    "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_FOCUS_CHANGED",
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "UNIT_FLAGS",
    "UNIT_THREAT_LIST_UPDATE", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_ENABLED",
  }) do Register(event) end
  ns.killMethod = "threat tracking"
  if GetCombatLogInfo and Register("COMBAT_LOG_EVENT_UNFILTERED") then
    ns.killMethod = "threat tracking + combat log"
  end

  f:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      OnCombatLog()
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
      StartSession(event)
    elseif event == "LOOT_CLOSED" then
      OnLootClosed()
    elseif event == "CHAT_MSG_LOOT" then
      OnLootMessage((...))
    elseif event == "PLAYER_TARGET_CHANGED" then
      NoteUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
      NoteUnit("mouseover")
    elseif event == "PLAYER_FOCUS_CHANGED" then
      NoteUnit("focus")
    elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED"
        or event == "UNIT_HEALTH" or event == "UNIT_FLAGS" or event == "UNIT_THREAT_LIST_UPDATE" then
      local unit = ...
      if IsMobToken(unit) then NoteUnit(unit) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local unit, _, spellID = ...
      if unit == "player" and spellID then
        local name = ns.SpellName(spellID)
        if name and gatherSpells[name] then
          lastGatherAt, lastGatherKind = GetTime(), gatherSpells[name]
        end
      end
    elseif event == "PLAYER_REGEN_ENABLED" then
      -- Out of combat: keep the tracking tables small. Tap and engagement
      -- state is kept until then because corpses are often checked after.
      local n = 0
      for _ in pairs(looted) do n = n + 1 end
      if n > 2000 then wipe(looted); wipe(counted); wipe(names); wipe(died); wipe(gathered); wipe(pickpocketed) end
      C_Timer.After(5, function()
        if not (UnitAffectingCombat and UnitAffectingCombat("player")) then
          wipe(tapDenied); wipe(engaged)
        end
      end)
    end
  end)
end
