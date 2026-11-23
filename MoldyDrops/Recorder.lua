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
--     Pick pocketing is ignored.
--   * Skinning, herbalism and mining a corpse are recorded separately
--     (ns.db.ownGather), once per corpse, solo or not.
local Recorder = {}
ns.Recorder = Recorder

local counted = {}    -- [guid] = true once its kill has been counted
local looted = {}     -- [guid] = true once its loot has been recorded
local tapDenied = {}  -- [guid] = true if we saw it tagged by someone else
local names = {}      -- [guid] = unit name, from the combat log or a unit token
local engaged = {}    -- [guid] = true if you or your pet were on its threat table
local died = {}       -- [guid] = true once its death has been handled
local gathered = {}   -- [guid] = true once its gathering loot has been recorded
local lastGatherAt = 0
local lastGatherKind
-- spell name -> gathering kind (1 skinning, 2 herbalism, 3 mining, 4 engineering;
-- 0 = pick pocketing, which is ignored)
local gatherSpells = { Skinning = 1, ["Herb Gathering"] = 2, Herbalism = 2, Mining = 3 }

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

local function CountKill(guid)
  if counted[guid] then return end
  local npcID = NpcIDFromGUID(guid)
  if not npcID then return end
  if ns.db.settings.openWorldOnly and IsInInstance() then return end
  counted[guid] = true
  local e = Entry(npcID)
  e[0] = e[0] + 1
  -- Remember names of mobs the bundled data doesn't know (new in WoW Forever).
  local name = names[guid]
  if name and not ns.db.mobs[npcID] and not (ns.mobs and ns.mobs[npcID] and ns.mobs[npcID][1] == name) then
    ns.db.mobs[npcID] = { name }
  end
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
      if hasLoot == false and not looted[guid] then CountKill(guid) end
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

-- Reads the open loot window: corpse guid -> { [itemID] = true, [-1] = true
-- if any grey item }, skipping corpses already in `done`.
local function ReadLoot(done)
  local byCorpse = {}
  local any = false
  for slot = 1, GetNumLootItems() do
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local guid = sources[i]
      if NpcIDFromGUID(guid) and not done[guid] then
        byCorpse[guid] = byCorpse[guid] or {}
        any = true
        if GetLootSlotType(slot) == LOOT_SLOT_ITEM then
          local link = GetLootSlotLink(slot)
          local itemID = link and tonumber(link:match("item:(%d+)"))
          if itemID then
            byCorpse[guid][itemID] = true
            local _, name, _, _, quality = GetLootSlotInfo(slot)
            if name and not ns.db.items[itemID] then ns.db.items[itemID] = { name, quality or 1 } end
            -- [-1] counts corpses with at least one grey item, which the
            -- per-item counts can't tell you.
            if quality == 0 then byCorpse[guid][-1] = true end
          end
        end
      end
    end
  end
  return any and byCorpse or nil
end

-- Skinning, herbalism, mining or engineering on a corpse. Recorded even in a
-- group, since what you gather is yours alone.
local function RecordGathering(kind)
  local byCorpse = ReadLoot(gathered)
  if not byCorpse then return end
  for guid, items in pairs(byCorpse) do
    gathered[guid] = true
    local npcID = NpcIDFromGUID(guid)
    local e = ns.db.ownGather[npcID]
    if not e or e.kind ~= kind then
      e = { kind = kind, [0] = 0 }
      ns.db.ownGather[npcID] = e
    end
    e[0] = e[0] + 1
    for itemID in pairs(items) do
      if itemID > 0 then e[itemID] = (e[itemID] or 0) + 1 end
    end
  end
end

local function OnLootOpened()
  if IsFishingLoot and IsFishingLoot() then return end
  if ns.db.settings.openWorldOnly and IsInInstance() then return end
  if GetTime() - lastGatherAt < 3 then
    if lastGatherKind and lastGatherKind > 0 then RecordGathering(lastGatherKind) end
    return
  end
  if not IsSolo() then return end

  local byCorpse = ReadLoot(looted)
  if not byCorpse then return end

  -- Looting a living mob means pick pocketing.
  local targetGUID = UnitGUID("target")
  for guid, items in pairs(byCorpse) do
    local pickpocket = guid == targetGUID and not UnitIsDead("target")
    if not pickpocket then
      looted[guid] = true
      CountKill(guid)
      if counted[guid] then
        local e = Entry(NpcIDFromGUID(guid))
        for itemID in pairs(items) do e[itemID] = (e[itemID] or 0) + 1 end
      end
    end
  end
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
  for id, kind in pairs({ [8613] = 1, [2366] = 2, [2575] = 3, [921] = 0 }) do
    local name = ns.SpellName(id)
    if name then gatherSpells[name] = kind end
  end

  local f = CreateFrame("Frame")
  -- Register one at a time: an event this client doesn't have is an error.
  local function Register(event) return pcall(f.RegisterEvent, f, event) end
  for _, event in ipairs({
    "LOOT_OPENED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_FOCUS_CHANGED",
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
    elseif event == "LOOT_OPENED" then
      OnLootOpened()
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
      if n > 2000 then wipe(looted); wipe(counted); wipe(names); wipe(died); wipe(gathered) end
      C_Timer.After(5, function()
        if not (UnitAffectingCombat and UnitAffectingCombat("player")) then
          wipe(tapDenied); wipe(engaged)
        end
      end)
    end
  end)
end
