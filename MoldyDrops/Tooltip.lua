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
  if p >= 10 then return ("%.0f%%"):format(p) end
  if p >= 1 then return ("%.1f%%"):format(p) end
  if p >= 0.1 then return ("%.2f%%"):format(p) end
  return "<0.1%"
end
ns.QualityHex, ns.FormatPct = QualityHex, FormatPct

local MAX_GREY_LINES = 8

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
    return rows, greys, ("%s, %d kills"):format(obsLabel, obs[0])
  elseif base then
    local note = "1.12 estimate"
    if obs then note = note .. (" (%s: %d kills)"):format(obsLabel, obs[0]) end
    return Pairs(base), Pairs(ns.baseGrey and ns.baseGrey[npcID]), note
  elseif obs then
    local rows, greys = ObservedRows(obs)
    return rows, greys, ("%s, only %d kills"):format(obsLabel, obs[0])
  end
end

-- The lines to display: up to maxRows rows. With expandGrey (Shift held),
-- the grey items are listed under the grey row; they don't count toward maxRows.
-- Each line is { itemID, percent, isGreyChild }. Also returns the note.
function Tooltip.Lines(npcID, maxRows, expandGrey)
  local rows, greys, note = Tooltip.Choose(npcID)
  if not rows then return nil end
  local lines = {}
  for i = 1, math.min(maxRows, #rows) do
    local r = rows[i]
    lines[#lines + 1] = { r[1], r[2], false }
    if r[1] == ns.GREY and expandGrey then
      for j = 1, math.min(MAX_GREY_LINES, #greys) do
        lines[#lines + 1] = { greys[j][1], greys[j][2], true }
      end
    end
  end
  return lines, note, #greys > 0
end

-- Text for one line: colored item name (indented if a grey child) and percent.
function Tooltip.LineText(line, expandGrey, hasGreys)
  local itemID, pct, child = line[1], line[2], line[3]
  local name, quality = ns.ItemInfo(itemID)
  local text = QualityHex(quality or 1) .. name .. "|r"
  if child then
    text = "    " .. text
  elseif itemID == ns.GREY and hasGreys and not expandGrey then
    text = text .. " |cff808080(Shift)|r"
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
  local lines, source, hasGreys = Tooltip.Lines(npcID, ns.TOP_N, expand)
  if not lines or #lines == 0 then return end

  tooltip:AddLine(" ")
  tooltip:AddDoubleLine("Drops", source, GOLD[1], GOLD[2], GOLD[3], GREY[1], GREY[2], GREY[3])
  for _, line in ipairs(lines) do
    local left, right = Tooltip.LineText(line, expand, hasGreys)
    tooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
  end
  tooltip:Show()
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
