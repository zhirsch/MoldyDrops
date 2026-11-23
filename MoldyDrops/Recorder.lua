local _, ns = ...

-- Records what drops from the mobs you kill.
--
-- A drop rate is (corpses that had the item) / (kills), so empty corpses
-- matter as much as full ones. Rules that keep the numbers honest:
--   * Only record while solo. In a group, other people loot corpses you
--     never see, which would undercount drops.
--   * A kill counts when you loot the corpse, or when you or your pet land
--     the killing blow (PARTY_KILL) on an untapped mob whose corpse turns
--     out to be empty. Corpses you walk past without looting don't count.
--     (If the client lacks CanLootUnit, every killing blow counts instead.)
--   * Each corpse is recorded once (re-opening the loot window, skinning
--     and the like are ignored). Pick pocketing and gathering are ignored.
local Recorder = {}
ns.Recorder = Recorder

local counted = {}    -- [guid] = true once its kill has been counted
local looted = {}     -- [guid] = true once its loot has been recorded
local tapDenied = {}  -- [guid] = true if we saw it tagged by someone else
local names = {}      -- [guid] = unit name, from the combat log or a unit token
local lastGatherAt = 0
local gatherSpells = {}

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

local function NoteUnit(unit)
  local guid = UnitGUID(unit)
  if not guid or not NpcIDFromGUID(guid) then return end
  names[guid] = UnitName(unit)
  if UnitIsTapDenied and UnitIsTapDenied(unit) and not UnitIsDead(unit) then
    tapDenied[guid] = true
  end
end

local function OnCombatLog()
  local _, subevent, _, sourceGUID, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
  if subevent ~= "PARTY_KILL" then return end
  if destName and NpcIDFromGUID(destGUID) then names[destGUID] = destName end
  if sourceGUID ~= UnitGUID("player") and sourceGUID ~= UnitGUID("pet") then return end
  if not IsSolo() or tapDenied[destGUID] or not NpcIDFromGUID(destGUID) then return end
  if CanLootUnit and C_Timer then
    -- Count the kill now only if the corpse is empty. A corpse with loot
    -- counts when you loot it, so corpses you skip don't drag rates down.
    C_Timer.After(1.5, function()
      local hasLoot = CanLootUnit(destGUID)
      if not hasLoot and not looted[destGUID] then CountKill(destGUID) end
    end)
  else
    -- No way to tell empty corpses from skipped ones: assume you loot everything.
    CountKill(destGUID)
  end
end

local function OnLootOpened()
  if not IsSolo() then return end
  if GetTime() - lastGatherAt < 3 then return end
  if IsFishingLoot and IsFishingLoot() then return end
  if ns.db.settings.openWorldOnly and IsInInstance() then return end

  -- corpse guid -> { [itemID] = true, [-1] = true if any grey item }
  local byCorpse = {}
  local any = false
  for slot = 1, GetNumLootItems() do
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local guid = sources[i]
      if NpcIDFromGUID(guid) and not looted[guid] then
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
  if not any then return end

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
  "CombatLogGetCurrentEventInfo", "GetNumLootItems", "GetLootSourceInfo",
  "GetLootSlotType", "GetLootSlotLink", "GetLootSlotInfo",
}

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

  for _, id in ipairs({ 8613, 2575, 2366, 921 }) do -- Skinning, Mining, Herb Gathering, Pick Pocket
    local name = ns.SpellName(id)
    if name then gatherSpells[name] = true end
  end

  local f = CreateFrame("Frame")
  f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  f:RegisterEvent("LOOT_OPENED")
  f:RegisterEvent("PLAYER_TARGET_CHANGED")
  f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
  f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
  f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
      OnCombatLog()
    elseif event == "LOOT_OPENED" then
      OnLootOpened()
    elseif event == "PLAYER_TARGET_CHANGED" then
      NoteUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
      NoteUnit("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
      NoteUnit((...))
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local unit, _, spellID = ...
      if unit == "player" and spellID then
        local name = ns.SpellName(spellID)
        if name and gatherSpells[name] then lastGatherAt = GetTime() end
      end
    elseif event == "PLAYER_REGEN_ENABLED" then
      -- Out of combat: forget tap state, and keep the dedupe tables small.
      wipe(tapDenied)
      local n = 0
      for _ in pairs(looted) do n = n + 1 end
      if n > 2000 then wipe(looted); wipe(counted); wipe(names) end
    end
  end)
end
