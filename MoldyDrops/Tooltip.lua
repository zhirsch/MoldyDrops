local _, ns = ...

-- Picks which numbers to show for a mob:
--   1. Observed rates (community snapshot or your own, whichever has more
--      kills) once they cover at least MIN_SAMPLE kills.
--   2. Otherwise the 1.12 estimate from BaseData.lua, if there is one.
--   3. Otherwise whatever observed data exists, flagged as a small sample.
-- Community and own data are never added together: your uploads are already
-- part of the community numbers, so summing would count them twice.
local Tooltip = {}
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

-- How many of an item come at once: min, max (nil if unknown).
-- section is "drop", "gather", "pick" (key = npcID) or "content" (key =
-- container item ID). Recorded counts (community first, then yours) win
-- over the 1.12 data.
-- The recorded entries for a section: community, own (either may be nil).
local function Recorded(section, key)
  local db = ns.db
  if section == "drop" then
    return db.community.npcs and db.community.npcs[key], db.own[key]
  elseif section == "gather" then
    return db.community.gather and db.community.gather[key], db.ownGather[key]
  elseif section == "pick" then
    return db.community.pick and db.community.pick[key], db.ownPick[key]
  end -- "quest", "content": only the 1.12 counts
end

function Tooltip.Qty(section, key, itemID)
  local comm, own = Recorded(section, key)
  for _, e in ipairs({ comm or false, own or false }) do
    local q = e and e.q and e.q[itemID]
    if q then return q[1], q[2] end
  end
  local b = ns.qty and ns.qty[section] and ns.qty[section][key]
  if b then
    for i = 1, #b - 2, 3 do
      if b[i] == itemID then return b[i + 1], b[i + 2] end
    end
  end
end

-- For an item that can come more than one at a time, the chance of each
-- count: { { count, percent }, ... } (lowest count first), splitting pct (the
-- item's overall chance) between them. Uses the recorded tally of counts
-- (community first, then yours); otherwise the 1.12 range, where every count
-- in min..max is equally likely (as in CMaNGOS). nil for single items.
function Tooltip.CountChances(section, key, itemID, pct)
  local min, max = Tooltip.Qty(section, key, itemID)
  if not max or max <= 1 then return nil end
  local comm, own = Recorded(section, key)
  for _, e in ipairs({ comm or false, own or false }) do
    local h = e and e.c and e.c[itemID]
    if h then
      local total, out = 0, {}
      for count, n in pairs(h) do
        if type(count) == "number" and n > 0 then
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

-- From an observed entry, returns rows { itemID, percent } with all grey
-- items folded into one row (itemID ns.GREY = corpses with any grey item /
-- kills), plus the individual grey rows. Without a grey count in the data,
-- the combined rate is estimated assuming independent drops.
local function ObservedRows(e)
  local kills = e[0]
  local rows, greys = {}, {}
  local noGrey = 1
  for itemID, c in pairs(e) do
    if type(itemID) == "number" and itemID > 0 and not ns.IsQuestItem(itemID) then -- skips [0], negatives, e.q, quest items
      local _, quality = ns.ItemInfo(itemID)
      if quality == 0 then
        greys[#greys + 1] = { itemID, 100 * c / kills }
        noGrey = noGrey * (1 - c / kills)
      else
        rows[#rows + 1] = { itemID, 100 * c / kills }
      end
    end
  end
  if e[-1] then
    rows[#rows + 1] = { ns.GREY, 100 * e[-1] / kills }
  elseif #greys > 0 then
    rows[#rows + 1] = { ns.GREY, 100 * (1 - noGrey) }
  end
  table.sort(rows, ByRate)
  table.sort(greys, ByRate)
  return rows, greys
end

local function Pairs(b)
  local rows = {}
  for i = 1, #(b or {}) - 1, 2 do rows[#rows + 1] = { b[i], b[i + 1] } end
  return rows
end

-- Returns rows, grey rows, and a note saying where the numbers come from.
function Tooltip.Choose(npcID)
  local db = ns.db
  local own = db.own[npcID]
  local comm = db.community.npcs and db.community.npcs[npcID]
  local base = ns.base and ns.base[npcID]

  local obs, obsLabel = nil, nil
  if comm and (not own or comm[0] >= own[0]) then
    obs, obsLabel = comm, "community"
  elseif own and own[0] > 0 then
    obs, obsLabel = own, "you"
  end

  if obs and obs[0] >= ns.MIN_SAMPLE then
    local rows, greys = ObservedRows(obs)
    return rows, greys, ("%s, %s"):format(obsLabel, Count(obs[0], "kill"))
  elseif base then
    local note = "1.12 estimate"
    if obs then note = note .. (" (%s: %s)"):format(obsLabel, Count(obs[0], "kill")) end
    return Pairs(base), Pairs(ns.baseGrey and ns.baseGrey[npcID]), note
  elseif obs then
    local rows, greys = ObservedRows(obs)
    return rows, greys, ("%s, only %s"):format(obsLabel, Count(obs[0], "kill"))
  end
end

-- A separate section (gathering, pick pocketing). Returns kind, rows
-- { { itemID, percent per corpse gathered / mob pick pocketed }, ... } and a
-- note; nil if nothing is known. Same source rules as Choose.
local function Section(own, comm, base, unit)
  local db = ns.db
  local obs, obsLabel
  if comm and (not own or comm[0] >= own[0]) then
    obs, obsLabel = comm, "community"
  elseif own and own[0] > 0 then
    obs, obsLabel = own, "you"
  end
  local function observed()
    local rows = {}
    for itemID, c in pairs(obs) do
      if type(itemID) == "number" and itemID > 0 and not ns.IsQuestItem(itemID) then
        rows[#rows + 1] = { itemID, 100 * c / obs[0] }
      end
    end
    table.sort(rows, ByRate)
    return rows
  end

  if obs and obs[0] >= ns.MIN_SAMPLE then
    return obs.kind, observed(), ("%s, %s"):format(obsLabel, Count(obs[0], unit))
  elseif base then
    local rows = {}
    for i = 2, #base - 1, 2 do rows[#rows + 1] = { base[i], base[i + 1] } end
    local note = "1.12 estimate"
    if obs then note = note .. (" (%s: %s)"):format(obsLabel, Count(obs[0], unit)) end
    return base[1], rows, note
  elseif obs then
    return obs.kind, observed(), ("%s, only %s"):format(obsLabel, Count(obs[0], unit))
  end
end

-- Skinning, herbalism, mining or engineering the corpse (kind 1-4).
function Tooltip.Gather(npcID)
  local db = ns.db
  return Section(db.ownGather[npcID], db.community.gather and db.community.gather[npcID],
    ns.gather and ns.gather[npcID], "corpse")
end

-- Pick pocketing the mob (kind 5).
function Tooltip.Pick(npcID)
  local db = ns.db
  return Section(db.ownPick[npcID], db.community.pick and db.community.pick[npcID],
    ns.pick and ns.pick[npcID], "mob")
end

-- Quest drops (kind 6): { { itemID, percent per kill }, ... } from the 1.12
-- data. With all = false (the default), only items one of your quests still
-- needs, since they don't drop otherwise. Kept apart from the normal drops.
function Tooltip.Quest(npcID, all)
  local q = ns.questDrops and ns.questDrops[npcID]
  if not q then return nil end
  local rows = {}
  for i = 1, #q - 1, 2 do
    if all or ns.NeedsQuestItem(q[i]) then rows[#rows + 1] = { q[i], q[i + 1] } end
  end
  return ns.QUEST, rows, "1.12 estimate, while on the quest"
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

local K = ns.ENTRY_KEYS or { NO_ITEMS = -2, GOLD_N = -3, GOLD_SUM = -4, GOLD_MIN = -5, GOLD_MAX = -6 }

-- Chance of a corpse with no items (percent), and gold { min, max, avg } in
-- copper (nil if the mob doesn't drop gold). Uses observed data when Choose
-- would, otherwise the 1.12 values.
function Tooltip.Extras(npcID)
  local db = ns.db
  local own = db.own[npcID]
  local comm = db.community.npcs and db.community.npcs[npcID]
  local obs
  if comm and (not own or comm[0] >= own[0]) then obs = comm elseif own and own[0] > 0 then obs = own end
  local base = ns.extra and ns.extra[npcID]

  if obs and obs[0] >= ns.MIN_SAMPLE then
    local gold
    local n = obs[K.GOLD_N]
    if n and n > 0 then gold = { obs[K.GOLD_MIN], obs[K.GOLD_MAX], obs[K.GOLD_SUM] / n } end
    return 100 * (obs[K.NO_ITEMS] or 0) / obs[0], gold
  elseif base then
    local gold
    if base[3] and base[3] > 0 then gold = { base[2], base[3], (base[2] + base[3]) / 2 } end
    return base[1], gold
  elseif obs then
    local gold
    local n = obs[K.GOLD_N]
    if n and n > 0 then gold = { obs[K.GOLD_MIN], obs[K.GOLD_MAX], obs[K.GOLD_SUM] / n } end
    return 100 * (obs[K.NO_ITEMS] or 0) / obs[0], gold
  end
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
-- container opened }, ... }, or nil if it isn't a known container.
function Tooltip.Contents(itemID)
  local c = ns.contents and ns.contents[itemID]
  if not c then return nil end
  local out = {}
  for i = 1, #c - 1, 2 do out[#out + 1] = { c[i], c[i + 1] } end
  return out
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

local function AddLoot(tooltip, unit)
  local db = ns.db
  if not db or not db.settings.enabled then return end
  if not unit or UnitIsPlayer(unit) then return end
  -- Don't touch a tooltip that's on its way out (see StillLive).
  if not Tooltip.StillLive(tooltip, unit) then return end
  -- Guards, vendors and other NPCs you can't attack: nothing to loot.
  if UnitCanAttack then
    local canAttack = UnitCanAttack("player", unit)
    if not (issecretvalue and issecretvalue(canAttack)) and not canAttack then return end
  end
  if db.settings.openWorldOnly and IsInInstance() then return end

  local npcID = ns.NpcIDFromGUID(UnitGUID(unit))
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
  if added then tooltip:Show() end
end

local function OnTooltipSetUnit(tooltip)
  if tooltip ~= GameTooltip then return end
  local _, unit = tooltip:GetUnit()
  if not unit and UnitExists("mouseover") then unit = "mouseover" end
  AddLoot(tooltip, unit)
end

-- Pressing or releasing Shift redraws a unit tooltip so the grey list
-- opens or closes while you hover.
local function OnModifierChanged(key)
  if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
  if GameTooltip:IsShown() then
    local _, unit = GameTooltip:GetUnit()
    -- Only while you're still pointing at it: SetUnit on a fading tooltip
    -- (mouse moved away, corpse despawned) would make it stick.
    if Tooltip.StillLive(GameTooltip, unit) then GameTooltip:SetUnit(unit) end
  end
  if ns.RefreshSearch then ns.RefreshSearch() end
end

function Tooltip:Init()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)
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
