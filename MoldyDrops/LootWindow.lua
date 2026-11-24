local _, ns = ...

-- Works out which mob each loot window belongs to, and whether it's the
-- corpse's loot, gathering (skinning, herbalism, mining) or pick pocketing.
-- The luck tags on loot messages use it (ns.lootContext), and other addons
-- can follow loot windows with MoldyDrops.RegisterLootListener (the built-in
-- recorder, Recorder.lua, does).
--
-- A listener is a table with any of these methods, each given the window's
-- context { guid, npcID, section = "drop"|"gather"|"pick", kind, at, open }:
--   listener:OnLootOpened(ctx, event)   a new loot window (LOOT_READY or LOOT_OPENED)
--   listener:OnLootUpdated(ctx, event)  the same window again (LOOT_OPENED after LOOT_READY)
--   listener:OnLootClosed(ctx)
--   listener:OnLootMessage(ctx, msg)    a CHAT_MSG_LOOT line while a context exists
local LootWindow = {}
ns.LootWindow = LootWindow

local listeners = {}
function LootWindow.AddListener(listener)
  if type(listener) ~= "table" then error("MoldyDrops.RegisterLootListener: expected a table", 2) end
  listeners[#listeners + 1] = listener
end

local function Notify(method, ...)
  for _, l in ipairs(listeners) do
    local fn = l[method]
    if type(fn) == "function" then
      local ok, err = pcall(fn, l, ...)
      if not ok then geterrorhandler()(err) end
    end
  end
end

-- Modern clients can hand addons "secret" values they aren't allowed to read.
local function Plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end
ns.Plain = Plain

local NpcIDFromGUID = ns.NpcIDFromGUID
local PICKPOCKET = 5
local lastGatherAt, lastGatherKind = 0, nil
-- spell name -> kind (1 skinning, 2 herbalism, 3 mining, 4 engineering, 5 pick pocket)
local gatherSpells = { Skinning = 1, ["Herb Gathering"] = 2, Herbalism = 2, Mining = 3, ["Pick Pocket"] = 5 }

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

local current -- the loot window's context

local function OnLootWindow(event)
  -- LOOT_READY then LOOT_OPENED for the same window.
  if current and current.open then
    Notify("OnLootUpdated", current, event)
    return
  end
  current = nil
  ns.lootContext = nil
  if IsFishingLoot and IsFishingLoot() then ns.Debug(event .. ": fishing, ignored") return end

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
  if not guid then ns.Debug(event .. ": couldn't tell which mob this loot is from") return end

  current = { guid = guid, npcID = NpcIDFromGUID(guid), section = section, kind = kind, at = GetTime(), open = true }
  ns.lootContext = current
  Notify("OnLootOpened", current, event)
end

-- "You receive loot: [item]" / "...x3" in the client's language.
local selfLootPrefixes
function ns.SelfLootPrefixes()
  if selfLootPrefixes then return selfLootPrefixes end
  selfLootPrefixes = {}
  for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE }) do
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%s")
    if prefix and prefix ~= "" then selfLootPrefixes[#selfLootPrefixes + 1] = prefix end
  end
  if #selfLootPrefixes == 0 then selfLootPrefixes[1] = "You receive loot: " end
  return selfLootPrefixes
end

function LootWindow:Init()
  if type(GetNumLootItems) ~= "function" or type(GetLootSourceInfo) ~= "function" then return end
  -- Localized names of the gathering spells (the English ones are built in).
  for id, kind in pairs({ [8613] = 1, [2366] = 2, [2575] = 3, [921] = 5 }) do
    local name = ns.SpellName(id)
    if name then gatherSpells[name] = kind end
  end
  local f = CreateFrame("Frame")
  for _, event in ipairs({ "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_LOOT", "UNIT_SPELLCAST_SUCCEEDED" }) do
    pcall(f.RegisterEvent, f, event) -- an event this client doesn't have is an error
  end
  f:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
      OnLootWindow(event)
    elseif event == "LOOT_CLOSED" then
      if current then
        current.open = false
        current.closedAt = GetTime()
        Notify("OnLootClosed", current)
      end
    elseif event == "CHAT_MSG_LOOT" then
      if current then Notify("OnLootMessage", current, (...)) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      local unit, _, spellID = ...
      if unit == "player" and spellID then
        local name = ns.SpellName(spellID)
        if name and gatherSpells[name] then
          lastGatherAt, lastGatherKind = GetTime(), gatherSpells[name]
        end
      end
    end
  end)
end
