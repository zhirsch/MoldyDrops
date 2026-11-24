local _, ns = ...

-- Adds the item's chance to your own loot messages, right after the link:
--   You receive loot: [Thick Leather] [4.2%] (Lucky!)
-- The chance is the one the tooltip shows for that mob (drop, gathering, pick
-- pocket or quest drop). Its color says how unlikely it was: white for 10% and
-- up, gold under 10%, shading to orange toward 0.1%; grey items stay grey.
-- Settings: luck = the (Lucky!) label on unlikely items (with their chance);
-- chanceAlways = the chance on every loot message.

local TIERS = { -- checked in order: first whose limit the chance is under
  { 0.5, "Incredibly lucky!" },
  { 2, "Very lucky!" },
  { 10, "Lucky!" },
}
local LUCKY_UNDER = 10
local CONTEXT_SECONDS = 30 -- loot messages can arrive a little after the window opens

-- Chance (percent) of itemID from npcID in a section, or nil if unknown.
local function ChanceOf(section, npcID, itemID)
  local lists
  if section == "gather" then
    local _, rows = ns.Tooltip.Gather(npcID)
    lists = { rows }
  elseif section == "pick" then
    local _, rows = ns.Tooltip.Pick(npcID)
    lists = { rows }
  else
    local rows, greys = ns.Tooltip.Choose(npcID)
    -- Quest drops too, whether or not the quest still needs more (the loot
    -- message can arrive after the quest log already counts the last one).
    local _, quest = ns.Tooltip.Quest(npcID, true)
    lists = { rows, greys, quest }
  end
  for _, list in ipairs(lists) do
    for _, r in ipairs(list or {}) do
      if r[1] == itemID then return r[2] end
    end
  end
end

-- The luck label for a chance, or nil if it wasn't unlikely.
function ns.LuckLabel(pct)
  for _, t in ipairs(TIERS) do
    if pct < t[1] then return t[2] end
  end
end

-- Color (hex "rrggbb") for a chance: grey for grey items, white from 10% up,
-- gold under 10%, then a gradient from gold at 2% to orange at 0.1%.
local GOLD, ORANGE = { 0xff, 0xd1, 0x00 }, { 0xff, 0x80, 0x00 }
function ns.ChanceColor(pct, quality)
  if quality == 0 then return "9d9d9d" end
  if pct >= LUCKY_UNDER then return "ffffff" end
  if pct >= 2 then return "ffd100" end
  -- 0 at 2%, 1 at 0.1% and below, on a log scale
  local t = math.min(1, math.max(0, (math.log(2) - math.log(math.max(pct, 0.1))) / (math.log(2) - math.log(0.1))))
  local c = {}
  for i = 1, 3 do c[i] = math.floor(GOLD[i] + (ORANGE[i] - GOLD[i]) * t + 0.5) end
  return ("%02x%02x%02x"):format(c[1], c[2], c[3])
end

-- The chance of an item you just looted (from the mob you looted), or nil.
function ns.LootChance(itemID)
  local ctx = ns.lootContext
  if not ctx or GetTime() - ctx.at > CONTEXT_SECONDS then return nil end
  local npcID = ctx.npcID -- one loot window = one mob
  if not npcID then return nil end
  return ChanceOf(ctx.section, npcID, itemID)
end

-- The luck label for an item you just looted and its chance, or nil.
function ns.LuckTag(itemID)
  local pct = ns.LootChance(itemID)
  if not pct then return nil end
  local label = ns.LuckLabel(pct)
  if label then return label, pct end
end

-- "You receive loot: " in the client's language (shared with the recorder).
local function SelfLootPrefixes() return ns.SelfLootPrefixes() end

-- Rewrites one loot message, or returns nil to leave it alone.
function ns.AddLuckToMessage(msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return nil end
  local s = ns.db and ns.db.settings
  if not (s and (s.luck or s.chanceAlways)) then return nil end
  local mine = false
  for _, prefix in ipairs(SelfLootPrefixes()) do
    if msg:sub(1, #prefix) == prefix then mine = true break end
  end
  if not mine then return nil end
  local itemID = tonumber(msg:match("|Hitem:(%d+)"))
  local pct = itemID and ns.LootChance(itemID)
  if not pct then return nil end
  local label = s.luck and ns.LuckLabel(pct)
  if not label and not s.chanceAlways then return nil end
  local _, quality = ns.ItemInfo(itemID)
  local color = "|cff" .. ns.ChanceColor(pct, quality)
  -- right after the item link: [4.2%] (Lucky!)
  local tag = color .. "[" .. ns.FormatPct(pct) .. "]" .. (label and (" (" .. label .. ")") or "") .. "|r"
  local out, n = msg:gsub("(|Hitem:.-|h.-|h|r)", function(l) return l .. " " .. tag end, 1)
  return n > 0 and out or nil
end

if ChatFrame_AddMessageEventFilter then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_LOOT", function(_, _, msg, ...)
    local changed = ns.AddLuckToMessage(msg)
    if changed then return false, changed, ... end
    return false
  end)
end
