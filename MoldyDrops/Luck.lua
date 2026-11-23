local _, ns = ...

-- Adds a gold "(Lucky! 4.2%)" tag to your own loot messages when the item was
-- an unlikely drop (or gathering / pick pocket result) from the mob you looted:
--   You receive loot: [Thick Leather] (Lucky! 4.2%)
-- The chance is the one the tooltip shows for that mob.

local TIERS = { -- checked in order: first whose limit the chance is under
  { 0.5, "Incredibly lucky!" },
  { 2, "Very lucky!" },
  { 10, "Lucky!" },
}
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
    lists = { rows, greys }
  end
  for _, list in ipairs(lists) do
    for _, r in ipairs(list or {}) do
      if r[1] == itemID then return r[2] end
    end
  end
end

-- The luck label for an item you just looted, or nil.
function ns.LuckTag(itemID)
  local ctx = ns.lootContext
  if not ctx or GetTime() - ctx.at > CONTEXT_SECONDS then return nil end
  local npcID = ctx.items[itemID]
  if not npcID then return nil end
  local pct = ChanceOf(ctx.section, npcID, itemID)
  if not pct then return nil end
  for _, t in ipairs(TIERS) do
    if pct < t[1] then return t[2], pct end
  end
end

-- "You receive loot: " in the client's language (from "You receive loot: %s.").
local function SelfLootPrefixes()
  local out = {}
  for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE }) do
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%s")
    if prefix and prefix ~= "" then out[#out + 1] = prefix end
  end
  if #out == 0 then out[1] = "You receive loot: " end
  return out
end

-- Rewrites one loot message, or returns nil to leave it alone.
function ns.AddLuckToMessage(msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return nil end
  if not (ns.db and ns.db.settings.luck) then return nil end
  local mine = false
  for _, prefix in ipairs(SelfLootPrefixes()) do
    if msg:sub(1, #prefix) == prefix then mine = true break end
  end
  if not mine then return nil end
  local itemID = tonumber(msg:match("|Hitem:(%d+)"))
  local tag, pct
  if itemID then tag, pct = ns.LuckTag(itemID) end
  if not tag then return nil end
  -- right after the item link: (Lucky! 4.2%)
  local label = "|cffffd100(" .. tag .. " " .. ns.FormatPct(pct) .. ")|r"
  local out, n = msg:gsub("(|Hitem:.-|h.-|h|r)", function(l) return l .. " " .. label end, 1)
  return n > 0 and out or nil
end

if ChatFrame_AddMessageEventFilter then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_LOOT", function(_, _, msg, ...)
    local changed = ns.AddLuckToMessage(msg)
    if changed then return false, changed, ... end
    return false
  end)
end
