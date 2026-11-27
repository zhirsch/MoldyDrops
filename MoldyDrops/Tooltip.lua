local _, ns = ...

-- Picks which data source's numbers to show for a mob (and separately for its
-- gathering and pick pocketing), among the sources that are turned on:
--   1. The observed source (one that counts kills, like the community data or
--      your own) with the most kills, once it has at least MIN_SAMPLE.
--   2. Otherwise the first estimate source (like the 1.12 data) that has the mob.
--   3. Otherwise whatever observed data exists, flagged as a small sample.
-- Sources are never added together: your uploads are already part of the
-- community numbers, so summing would count them twice.
local Tooltip = {}
local Sources = ns.Sources
ns.Tooltip = Tooltip

local GOLD = { 1, 0.82, 0 }
local GREY = { 0.6, 0.6, 0.6 }
local QUALITY_FALLBACK = {
  [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd",
  [4] = "ffa335ee", [5] = "ffff8000", [6] = "ffe6cc80", [7] = "ff00ccff",
}

local function QualityHex(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex end
  return "|c" .. (QUALITY_FALLBACK[q] or "ffffffff")
end

local function FormatPct(p)
  if p <= 0 then return "0%" end
  if p >= 10 then return ("%.0f%%"):format(p) end
  if p >= 1 then return ("%.1f%%"):format(p) end
  if p >= 0.1 then return ("%.2f%%"):format(p) end
  return "<0.1%"
end
-- A chance colored like the item's rarity (grey for poor items and "No items").
local function ColoredPct(p, quality)
  return QualityHex(quality or 1) .. FormatPct(p) .. "|r"
end
ns.QualityHex, ns.FormatPct, ns.ColoredPct = QualityHex, FormatPct, ColoredPct

local MAX_GREY_LINES = 8

-- "1 kill", "20 kills"
local function Count(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function ByRate(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end

-- The source method for each section: key is an NPC ID, or for "content" a
-- container's item ID.
local METHOD = { drop = "Drops", gather = "Gather", pick = "Pick", quest = "Quest", content = "Contents" }

-- The entries the sources that are turned on have for a section: recorded
-- ones first, most samples first, then estimates in source order. Stack
-- counts come from the first that knows, so real counts beat 1.12 ranges.
local function Ranked(method, key)
  local obs, est = {}, {}
  for _, src in ipairs(Sources.Enabled()) do
    local e = Sources.Get(src, method, key)
    if e then
      if src.observed then obs[#obs + 1] = e else est[#est + 1] = e end
    end
  end
  if #obs > 1 then
    local pos = {}
    for i, e in ipairs(obs) do pos[e] = i end
    table.sort(obs, function(a, b)
      local na, nb = tonumber(a.samples) or 0, tonumber(b.samples) or 0
      if na ~= nb then return na > nb end
      return pos[a] < pos[b]
    end)
  end
  for _, e in ipairs(est) do obs[#obs + 1] = e end
  return obs
end

-- How many of an item come at once: min, max (nil if unknown). section is
-- "drop", "gather", "pick", "quest" (key = npcID) or "content" (key =
-- container item ID).
function Tooltip.Qty(section, key, itemID)
  local method = METHOD[section]
  if not method then return nil end
  for _, e in ipairs(Ranked(method, key)) do
    local q = type(e.qty) == "table" and e.qty[itemID]
    if type(q) == "table" and tonumber(q[2]) then return tonumber(q[1]) or 1, tonumber(q[2]) end
  end
end

-- For an item that can come more than one at a time, the chance of each
-- count: { { count, percent }, ... } (lowest count first), splitting pct (the
-- item's overall chance) between them. Uses the first recorded tally of
-- counts a source has; otherwise the range, where every count in min..max is
-- equally likely (as in CMaNGOS). nil for single items.
function Tooltip.CountChances(section, key, itemID, pct)
  local min, max = Tooltip.Qty(section, key, itemID)
  if not max or max <= 1 then return nil end
  for _, e in ipairs(Ranked(METHOD[section], key)) do
    local h = type(e.counts) == "table" and e.counts[itemID]
    if type(h) == "table" then
      local total, out = 0, {}
      for count, n in pairs(h) do
        if type(count) == "number" and type(n) == "number" and n > 0 then
          total = total + n
          out[#out + 1] = { count, n }
        end
      end
      if total > 0 then
        table.sort(out, function(a, b) return a[1] < b[1] end)
        for _, r in ipairs(out) do r[2] = pct * r[2] / total end
        return out
      end
    end
  end
  local out = {}
  min = math.max(1, min or 1)
  for count = min, max do out[#out + 1] = { count, pct / (max - min + 1) } end
  return out
end

-- " x1-2" (grey) when more than one can come at once, else "".
function ns.QtyText(min, max)
  if not max or max <= 1 then return "" end
  return " |cff9d9d9dx" .. (min == max and tostring(max) or (min .. "-" .. max)) .. "|r"
end

local UNIT = { Drops = "kill", Gather = "corpse", Pick = "mob" }

-- Chooses one source's entry for a mob: method is "Drops", "Gather" or
-- "Pick". Returns the entry, a note saying where it comes from
-- ("community, 120 kills", "1.12 estimate (you: 3 kills)"), and the source.
function Tooltip.Select(method, npcID)
  local unit = UNIT[method] or "kill"
  local obs, obsSrc, est, estSrc
  for _, src in ipairs(Sources.Enabled()) do
    local e = Sources.Get(src, method, npcID)
    if e then
      if src.observed then
        local n = tonumber(e.samples) or 0
        -- Most samples wins; on a tie, the earlier source.
        if n > 0 and (not obs or n > obs.samples) then obs, obsSrc = e, src end
      elseif not est then
        est, estSrc = e, src
      end
    end
  end
  if obs and obs.samples >= ns.MIN_SAMPLE then
    return obs, ("%s, %s"):format(obsSrc.label, Count(obs.samples, unit)), obsSrc
  elseif est then
    local note = estSrc.label
    if obs then note = note .. (" (%s: %s)"):format(obsSrc.label, Count(obs.samples, unit)) end
    return est, note, estSrc
  elseif obs then
    return obs, ("%s, only %s"):format(obsSrc.label, Count(obs.samples, unit)), obsSrc
  end
end

-- An entry's items as rows { itemID, percent }, best first, with quest items
-- left out. Valid item IDs only: a source can't break the tooltip with junk.
local function ItemRows(map, keepQuestItems)
  local out = {}
  if type(map) ~= "table" then return out end
  for itemID, pct in pairs(map) do
    if type(itemID) == "number" and itemID > 0 and type(pct) == "number"
        and (keepQuestItems or not ns.IsQuestItem(itemID)) then
      out[#out + 1] = { itemID, pct }
    end
  end
  return out
end

-- From a drops entry, returns rows { itemID, percent } with all grey items
-- folded into one row (itemID ns.GREY = kills with any grey item), plus the
-- individual grey rows. Grey items are the entry's .greys and any of its
-- .items the game calls poor quality. Without a .grey chance in the entry,
-- the combined chance is estimated assuming independent drops.
local function DropRows(e)
  local rows, greys = {}, ItemRows(e.greys)
  local forced = type(e.greys) == "table" and e.greys or {}
  for _, r in ipairs(ItemRows(e.items)) do
    if not forced[r[1]] then
      local _, quality = ns.ItemInfo(r[1])
      if quality == 0 then greys[#greys + 1] = r else rows[#rows + 1] = r end
    end
  end
  if type(e.grey) == "number" then
    rows[#rows + 1] = { ns.GREY, e.grey }
  elseif #greys > 0 then
    local noGrey = 1
    for _, g in ipairs(greys) do noGrey = noGrey * (1 - math.min(100, g[2]) / 100) end
    rows[#rows + 1] = { ns.GREY, 100 * (1 - noGrey) }
  end
  table.sort(rows, ByRate)
  table.sort(greys, ByRate)
  return rows, greys
end

-- Returns rows, grey rows, and a note saying where the numbers come from.
function Tooltip.Choose(npcID)
  local e, note = Tooltip.Select("Drops", npcID)
  if not e then return nil end
  local rows, greys = DropRows(e)
  return rows, greys, note
end

local function SectionRows(e)
  local rows = ItemRows(e.items)
  table.sort(rows, ByRate)
  return rows
end

-- Skinning, herbalism, mining or engineering the corpse (kind 1-4). Returns
-- kind, rows { { itemID, percent per corpse gathered }, ... } and a note;
-- nil if nothing is known. Same source rules as Choose.
function Tooltip.Gather(npcID)
  local e, note = Tooltip.Select("Gather", npcID)
  if not e then return nil end
  local kind = tonumber(e.kind)
  if not kind or kind < 1 or kind > 4 then kind = 1 end
  return kind, SectionRows(e), note
end

-- Pick pocketing the mob (kind 5): chance per mob pick pocketed.
function Tooltip.Pick(npcID)
  local e, note = Tooltip.Select("Pick", npcID)
  if not e then return nil end
  return ns.PICKPOCKET, SectionRows(e), note
end

-- Quest drops (kind 6): { { itemID, percent per kill }, ... } from the first
-- source that has them. With all = false (the default), only items one of
-- your quests still needs, since they don't drop otherwise. Kept apart from
-- the normal drops.
function Tooltip.Quest(npcID, all)
  for _, src in ipairs(Sources.Enabled()) do
    local e = Sources.Get(src, "Quest", npcID)
    if e then
      local rows = {}
      for _, r in ipairs(ItemRows(e.items, true)) do
        if all or ns.NeedsQuestItem(r[1]) then rows[#rows + 1] = r end
      end
      table.sort(rows, ByRate)
      return ns.QUEST, rows, src.label .. ", while on the quest"
    end
  end
end

-- The extra sections to show for a mob: { { kind, rows, note }, ... }.
-- Quest drops come first and only while you need them; pick pocketing is
-- only shown to rogues.
function Tooltip.Sections(npcID)
  local out = {}
  local kind, rows, note = Tooltip.Quest(npcID)
  if kind and #rows > 0 then out[#out + 1] = { kind, rows, note } end
  kind, rows, note = Tooltip.Gather(npcID)
  if kind and #rows > 0 then out[#out + 1] = { kind, rows, note } end
  if ns.IsRogue() then
    kind, rows, note = Tooltip.Pick(npcID)
    if kind and #rows > 0 then out[#out + 1] = { kind, rows, note } end
  end
  return out
end

-- Chance of a corpse with no items (percent), and gold { min, max, avg } in
-- copper (nil if the mob doesn't drop gold), from the source Choose uses.
function Tooltip.Extras(npcID)
  local e = Tooltip.Select("Drops", npcID)
  if not e then return nil end
  local gold = e.gold
  if type(gold) ~= "table" or not (tonumber(gold[1]) and tonumber(gold[2])) then gold = nil end
  if gold and not tonumber(gold[3]) then gold = { gold[1], gold[2], (gold[1] + gold[2]) / 2 } end
  return tonumber(e.noItems), gold
end

-- "1g 2s 3c", colored like coins.
function ns.FormatMoney(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = "|cffffd700" .. g .. "g|r" end
  if s > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = "|cffeda55f" .. c .. "c|r" end
  return table.concat(parts, " ")
end

-- The "No items" and "Gold" lines, as { left, right } pairs.
function Tooltip.ExtraLines(npcID)
  local noItems, gold = Tooltip.Extras(npcID)
  local out = {}
  if noItems then out[#out + 1] = { QualityHex(0) .. "No items|r", ColoredPct(noItems, 0) } end
  if gold then
    local range = gold[1] == gold[2] and ns.FormatMoney(gold[1])
      or (ns.FormatMoney(gold[1]) .. " - " .. ns.FormatMoney(gold[2]))
    out[#out + 1] = { "Gold  " .. range, "avg " .. ns.FormatMoney(gold[3]) }
  end
  return out
end

local MAX_CONTENT_LINES = 5

-- What's inside a container item (clam, lockbox...): { { itemID, percent per
-- container opened }, ... } from the first source that knows, or nil if it
-- isn't a known container.
function Tooltip.Contents(itemID)
  for _, src in ipairs(Sources.Enabled()) do
    local e = Sources.Get(src, "Contents", itemID)
    if e then
      local rows = ItemRows(e.items)
      table.sort(rows, ByRate)
      return rows
    end
  end
end

-- With expand, adds a line per count under an item that can come more than
-- one at a time: { itemID, percent, "count", nil, count }. Returns whether
-- the item has such a breakdown.
local function AddCountLines(lines, section, key, itemID, pct, expand, deep)
  local counts = itemID ~= ns.GREY and Tooltip.CountChances(section, key, itemID, pct)
  if not counts then return false end
  if expand then
    for _, c in ipairs(counts) do lines[#lines + 1] = { itemID, c[2], "count", nil, c[1], deep } end
  end
  return true
end

-- The lines to display: up to maxRows rows. With expand (Shift held), grey
-- items are listed under the grey row, container contents under each
-- container, and the chance of each count under items that can come more than
-- one at a time; those extra lines don't count toward maxRows.
-- Each line is { itemID, percent, kind, qty, count }, kind nil, "grey",
-- "content" or "count".
-- Also returns the source note and whether anything can be expanded.
function Tooltip.Lines(npcID, maxRows, expand)
  local rows, greys, note = Tooltip.Choose(npcID)
  if not rows then return nil end
  local lines, expandable = {}, false
  local function add(itemID, pct, kind)
    lines[#lines + 1] = { itemID, pct, kind, itemID ~= ns.GREY and { Tooltip.Qty("drop", npcID, itemID) } or nil }
    if AddCountLines(lines, "drop", npcID, itemID, pct, expand, kind == "grey") then expandable = true end
    local inside = itemID ~= ns.GREY and Tooltip.Contents(itemID)
    if inside then
      expandable = true
      if expand then
        for j = 1, math.min(MAX_CONTENT_LINES, #inside) do
          lines[#lines + 1] = { inside[j][1], inside[j][2], "content", { Tooltip.Qty("content", itemID, inside[j][1]) } }
        end
      end
    end
  end
  for i = 1, math.min(maxRows, #rows) do
    local r = rows[i]
    add(r[1], r[2], nil)
    if r[1] == ns.GREY and #greys > 0 then
      expandable = true
      if expand then
        for j = 1, math.min(MAX_GREY_LINES, #greys) do add(greys[j][1], greys[j][2], "grey") end
      end
    end
  end
  return lines, note, expandable
end

-- Text for one line: colored item name and percent. Grey items are indented
-- under the grey row; container contents are indented further, with their
-- chance per container opened shown in grey.
function Tooltip.LineText(line, expand)
  local itemID, pct, kind, qty = line[1], line[2], line[3], line[4]
  local name, quality = ns.ItemInfo(itemID)
  if kind == "count" then
    -- exactly this many: "    Runecloth x2"
    local indent = line[6] and "        " or "    "
    return indent .. QualityHex(quality or 1) .. name .. "|r |cff9d9d9dx" .. line[5] .. "|r", ColoredPct(pct, quality)
  end
  local text = QualityHex(quality or 1) .. name .. "|r" .. (qty and ns.QtyText(qty[1], qty[2]) or "")
  if kind == "content" then
    return "      |cff808080in it:|r " .. text, ColoredPct(pct, quality)
  elseif kind == "grey" then
    text = "    " .. text
  end
  if not expand then
    local hasChildren = (itemID == ns.GREY) or Tooltip.Contents(itemID) or (qty and qty[2] and qty[2] > 1)
    if hasChildren then text = text .. " |cff808080(Shift)|r" end
  end
  return text, ColoredPct(pct, quality)
end

-- A separate section's display rows { left, right, line } (gathering, pick
-- pocketing, quest drops): up to maxRows items, each with its per-count
-- chances under it when expand is set. Also returns whether Shift would show more.
function Tooltip.SectionLines(kind, rows, npcID, maxRows, expand)
  local section = ns.SectionOf(kind)
  local lines, expandable = {}, false
  for i = 1, math.min(maxRows, #rows) do
    local itemID, pct = rows[i][1], rows[i][2]
    lines[#lines + 1] = { itemID, pct, section, { Tooltip.Qty(section, npcID, itemID) } }
    if AddCountLines(lines, section, npcID, itemID, pct, expand) then expandable = true end
  end
  local out = {}
  for _, line in ipairs(lines) do
    local left, right
    if line[3] == "count" then
      left, right = Tooltip.LineText(line, expand)
    else
      local name, quality = ns.ItemInfo(line[1])
      local qty = line[4]
      left = QualityHex(quality or 1) .. name .. "|r" .. ns.QtyText(qty[1], qty[2])
        .. ((not expand and qty[2] and qty[2] > 1) and " |cff808080(Shift)|r" or "")
      right = ColoredPct(line[2], quality)
    end
    out[#out + 1] = { left, right, line }
  end
  return out, expandable
end

-- The whole Drops section as display rows { left, right, line }: the top
-- maxRows drops, with "No items" placed among them by its chance (it doesn't
-- use up a row, and never splits a row from the grey items or container
-- contents listed under it), then the gold line last. line is the drop line
-- from Lines, or nil for the No items and Gold rows.
-- Also returns the source note and whether Shift would show more.
function Tooltip.DropSection(npcID, maxRows, expand)
  local lines, source, expandable = Tooltip.Lines(npcID, maxRows, expand)
  local noItems, gold = Tooltip.Extras(npcID)
  local out = {}
  local placed = noItems == nil
  local function addNoItems()
    out[#out + 1] = { QualityHex(0) .. "No items|r", ColoredPct(noItems, 0), nil }
    placed = true
  end
  for _, line in ipairs(lines or {}) do
    -- Only before a top-level drop, never between a row and its children.
    if not placed and line[3] == nil and noItems > line[2] then addNoItems() end
    local left, right = Tooltip.LineText(line, expand)
    out[#out + 1] = { left, right, line }
  end
  if not placed then addNoItems() end
  if gold then
    local range = gold[1] == gold[2] and ns.FormatMoney(gold[1])
      or (ns.FormatMoney(gold[1]) .. " - " .. ns.FormatMoney(gold[2]))
    out[#out + 1] = { "Gold  " .. range, "avg " .. ns.FormatMoney(gold[3]), nil }
  end
  return out, source, expandable
end

-- Is this unit tooltip still for something you're pointing at? A world unit's
-- tooltip (owned by UIParent / WorldFrame) fades out once the mouse leaves
-- the mob or its corpse despawns; showing or refreshing it then cancels the
-- fade and leaves it stuck on screen. Tooltips from unit frames (target,
-- party) hide themselves when the mouse leaves the frame.
function Tooltip.StillLive(tooltip, unit)
  if not unit then return false end
  local ok, live = pcall(function()
    if not UnitExists(unit) then return false end
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if owner == nil or owner == UIParent or owner == WorldFrame then
      return UnitExists("mouseover") and UnitIsUnit(unit, "mouseover")
    end
    return true
  end)
  if not ok then return false end
  if issecretvalue and issecretvalue(live) then return false end
  return live and true or false
end

-- WoW Forever hides some values from addons (in instances, and for some
-- tooltips in combat): a "secret" unit token, GUID or result can't be
-- compared, split or passed to most Unit* functions, which raise an error.
local function Secret(v) return issecretvalue and issecretvalue(v) or false end

local function AddLoot(tooltip, unit)
  local db = ns.db
  if not db or not db.settings.enabled then return end
  if db.settings.openWorldOnly and IsInInstance() then return end
  if not unit or Secret(unit) then return end
  local isPlayer = UnitIsPlayer(unit)
  if Secret(isPlayer) or isPlayer then return end
  -- Don't touch a tooltip that's on its way out (see StillLive).
  if not Tooltip.StillLive(tooltip, unit) then return end
  -- Guards, vendors and other NPCs you can't attack: nothing to loot.
  if UnitCanAttack then
    local canAttack = UnitCanAttack("player", unit)
    if not Secret(canAttack) and not canAttack then return end
  end
  if not ns.TooltipModifierOk() then return end

  local guid = UnitGUID(unit)
  if Secret(guid) then return end
  local npcID = ns.NpcIDFromGUID(guid)
  if not npcID then return end
  local expand = ns.ShiftHeld()
  local added = false
  local rows, source = Tooltip.DropSection(npcID, ns.TopN(), expand)
  if #rows > 0 then
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Drops", source or "1.12 estimate", GOLD[1], GOLD[2], GOLD[3], GREY[1], GREY[2], GREY[3])
    for _, r in ipairs(rows) do tooltip:AddDoubleLine(r[1], r[2], 1, 1, 1, 1, 1, 1) end
    added = true
  end

  -- Separate sections: quest drops you need, skinning / herbalism / mining /
  -- engineering the corpse, and pick pocketing (rogues only).
  for _, s in ipairs(Tooltip.Sections(npcID)) do
    local kind, rows, note = s[1], s[2], s[3]
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(ns.GATHER_NAMES[kind] or "Gathering", note, GOLD[1], GOLD[2], GOLD[3], GREY[1], GREY[2], GREY[3])
    for _, r in ipairs((Tooltip.SectionLines(kind, rows, npcID, ns.TopN(), expand))) do
      tooltip:AddDoubleLine(r[1], r[2], 1, 1, 1, 1, 1, 1)
    end
    added = true
  end
  -- Older clients (OnTooltipSetUnit) need Show() to resize after adding
  -- lines. With TooltipDataProcessor the game shows the tooltip itself after
  -- the post-calls; calling Show() from inside its build fires every addon's
  -- OnShow mid-rebuild, which unit frames trigger every 0.2s while hovered.
  if added and not Tooltip.nativeBuild then tooltip:Show() end
end

local function OnTooltipSetUnit(tooltip)
  if tooltip ~= GameTooltip then return end
  local _, unit = tooltip:GetUnit()
  -- A secret token is no use; the mouseover unit may still be readable.
  if Secret(unit) then unit = nil end
  if not unit then
    local exists = UnitExists("mouseover")
    if exists and not Secret(exists) then unit = "mouseover" end
  end
  AddLoot(tooltip, unit)
end

-- Pressing or releasing Shift redraws a unit tooltip so the grey list
-- opens or closes while you hover. So does the "only while a key is held"
-- key, to add or remove the drops.
local function OnModifierChanged(key)
  local shift = key == "LSHIFT" or key == "RSHIFT"
  local held = false
  if ns.db and ns.db.settings.requireModifier then
    local m = ns.ModifierKey()
    held = key == m.left or key == m.right
  end
  if not shift and not held then return end
  if GameTooltip:IsShown() then
    local _, unit = GameTooltip:GetUnit()
    if Secret(unit) then unit = nil end
    -- Only while you're still pointing at it: SetUnit on a fading tooltip
    -- (mouse moved away, corpse despawned) would make it stick.
    if Tooltip.StillLive(GameTooltip, unit) then GameTooltip:SetUnit(unit) end
  end
  if shift and ns.RefreshSearch then ns.RefreshSearch() end
end

function Tooltip:Init()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)
    Tooltip.nativeBuild = true
  else
    GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipSetUnit)
  end
  local f = CreateFrame("Frame")
  f:RegisterEvent("MODIFIER_STATE_CHANGED")
  pcall(f.RegisterEvent, f, "QUEST_LOG_UPDATE")
  f:SetScript("OnEvent", function(_, event, key)
    if event == "QUEST_LOG_UPDATE" then
      -- Quest drops come and go with your quests.
      if ns.RefreshSearch then ns.RefreshSearch() end
    else
      OnModifierChanged(key)
    end
  end)
end
