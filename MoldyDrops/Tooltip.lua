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
ns.QualityHex, ns.FormatPct = QualityHex, FormatPct

local MAX_GREY_LINES = 8

-- "1 kill", "20 kills"
local function Count(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function ByRate(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end

-- From an observed entry, returns rows { itemID, percent } with all grey
-- items folded into one row (itemID ns.GREY = corpses with any grey item /
-- kills), plus the individual grey rows. Without a grey count in the data,
-- the combined rate is estimated assuming independent drops.
local function ObservedRows(e)
  local kills = e[0]
  local rows, greys = {}, {}
  local noGrey = 1
  for itemID, c in pairs(e) do
    if itemID > 0 then
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
      if type(itemID) == "number" and itemID > 0 then rows[#rows + 1] = { itemID, 100 * c / obs[0] } end
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

-- The extra sections to show for a mob: { { kind, rows, note }, ... }.
-- Pick pocketing is only shown to rogues.
function Tooltip.Sections(npcID)
  local out = {}
  local kind, rows, note = Tooltip.Gather(npcID)
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
  if noItems then out[#out + 1] = { "|cff9d9d9dNo items|r", "|cff9d9d9d" .. FormatPct(noItems) .. "|r" } end
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

-- The lines to display: up to maxRows rows. With expand (Shift held), grey
-- items are listed under the grey row and container contents under each
-- container; those extra lines don't count toward maxRows.
-- Each line is { itemID, percent, kind }, kind nil, "grey" or "content".
-- Also returns the source note and whether anything can be expanded.
function Tooltip.Lines(npcID, maxRows, expand)
  local rows, greys, note = Tooltip.Choose(npcID)
  if not rows then return nil end
  local lines, expandable = {}, false
  local function add(itemID, pct, kind)
    lines[#lines + 1] = { itemID, pct, kind }
    local inside = itemID ~= ns.GREY and Tooltip.Contents(itemID)
    if inside then
      expandable = true
      if expand then
        for j = 1, math.min(MAX_CONTENT_LINES, #inside) do
          lines[#lines + 1] = { inside[j][1], inside[j][2], "content" }
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
  local itemID, pct, kind = line[1], line[2], line[3]
  local name, quality = ns.ItemInfo(itemID)
  local text = QualityHex(quality or 1) .. name .. "|r"
  if kind == "content" then
    return "      |cff808080in it:|r " .. text, "|cff9d9d9d" .. FormatPct(pct) .. "|r"
  elseif kind == "grey" then
    text = "    " .. text
  end
  if not expand and kind ~= "content" then
    local hasChildren = (itemID == ns.GREY) or Tooltip.Contents(itemID)
    if hasChildren then text = text .. " |cff808080(Shift)|r" end
  end
  return text, FormatPct(pct)
end

local function AddLoot(tooltip, unit)
  local db = ns.db
  if not db or not db.settings.enabled then return end
  if not unit or UnitIsPlayer(unit) then return end
  if db.settings.openWorldOnly and IsInInstance() then return end

  local npcID = ns.NpcIDFromGUID(UnitGUID(unit))
  if not npcID then return end
  local expand = IsShiftKeyDown()
  local added = false
  local lines, source = Tooltip.Lines(npcID, ns.TOP_N, expand)
  local extras = Tooltip.ExtraLines(npcID)
  if (lines and #lines > 0) or #extras > 0 then
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Drops", source or "1.12 estimate", GOLD[1], GOLD[2], GOLD[3], GREY[1], GREY[2], GREY[3])
    for _, line in ipairs(lines or {}) do
      local left, right = Tooltip.LineText(line, expand)
      tooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    for _, x in ipairs(extras) do tooltip:AddDoubleLine(x[1], x[2], 1, 1, 1, 1, 1, 1) end
    added = true
  end

  -- Separate sections: skinning / herbalism / mining / engineering the corpse,
  -- and pick pocketing (rogues only).
  for _, s in ipairs(Tooltip.Sections(npcID)) do
    local kind, rows, note = s[1], s[2], s[3]
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(ns.GATHER_NAMES[kind] or "Gathering", note, GOLD[1], GOLD[2], GOLD[3], GREY[1], GREY[2], GREY[3])
    for i = 1, math.min(ns.TOP_N, #rows) do
      local name, quality = ns.ItemInfo(rows[i][1])
      tooltip:AddDoubleLine(QualityHex(quality or 1) .. name .. "|r", FormatPct(rows[i][2]), 1, 1, 1, 1, 1, 1)
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
    if unit and UnitExists(unit) then GameTooltip:SetUnit(unit) end
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
  f:SetScript("OnEvent", function(_, _, key) OnModifierChanged(key) end)
end
