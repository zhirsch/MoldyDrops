local _, ns = ...

-- /drops search <mob name>: matching mobs on the left, the selected mob's
-- drops on the right. Hold Shift to list the grey items.

-- Case-insensitive substring search over every mob we have a name for.
-- Exact matches first, then names that start with the query, then the rest.
function ns.SearchMobs(query)
  query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return {} end
  local seen, results = {}, {}
  local function consider(npcID)
    if seen[npcID] then return end
    seen[npcID] = true
    local name, minL, maxL = ns.MobInfo(npcID)
    if not name then return end
    local lower = name:lower()
    local pos = lower:find(query, 1, true)
    if not pos then return end
    local rank = (lower == query and 0) or (pos == 1 and 1) or 2
    results[#results + 1] = { id = npcID, name = name, minL = minL, maxL = maxL, rank = rank }
  end
  for id in pairs(ns.mobs or {}) do consider(id) end
  for id in pairs(ns.db.mobs) do consider(id) end
  for id in pairs(ns.db.own) do consider(id) end
  for id in pairs(ns.db.community.npcs or {}) do consider(id) end
  table.sort(results, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  while #results > ns.SEARCH_MAX_RESULTS do results[#results] = nil end
  return results
end

function ns.LevelRange(minL, maxL)
  if not minL then return "" end
  if minL == maxL then return tostring(minL) end
  return minL .. "-" .. maxL
end

local window = ns.CreateSearchWindow({
  name = "MoldyDropsSearchFrame",
  title = "MoldyDrops: Search mobs",
  noun = "mob",
  search = ns.SearchMobs,
  listText = function(r) return r.name, ns.LevelRange(r.minL, r.maxL) end,
  -- Mob list: name and level, with the mob's 3D model underneath.
  onListEnter = function(_, r)
    GameTooltip:SetText(r.name)
    local level = ns.LevelRange(r.minL, r.maxL)
    if level ~= "" then GameTooltip:AddLine("Level " .. level, 1, 1, 1) end
  end,
  listModel = function(r) return r.id end,
  detail = function(r)
    local level = ns.LevelRange(r.minL, r.maxL)
    local header = {
      name = r.name,
      sub = (level ~= "" and ("Level " .. level .. "  ·  ") or "") .. "NPC " .. r.id,
    }
    local expand = ns.ShiftHeld()
    local out = {}
    local rows, source, expandable = ns.Tooltip.DropSection(r.id, ns.ALL_ROWS, expand)
    for _, row in ipairs(rows) do out[#out + 1] = row end

    -- Quest drops you need, gathering and pick pocketing (rogues), each under its own heading.
    for _, s in ipairs(ns.Tooltip.Sections(r.id)) do
      local kind, srows, note = s[1], s[2], s[3]
      out[#out + 1] = { " ", nil, nil }
      out[#out + 1] = { "|cffffd100" .. (ns.GATHER_NAMES[kind] or "Gathering") .. "|r  |cff999999" .. note .. "|r", nil, nil }
      local lines, more = ns.Tooltip.SectionLines(kind, srows, r.id, ns.ALL_ROWS, expand)
      if more then expandable = true end
      for _, row in ipairs(lines) do out[#out + 1] = row end
    end

    local hint = (expandable and not expand) and "  ·  hold Shift for more" or ""
    if source then
      header.source = "Source: " .. source .. hint
    else
      header.source = (#rows > 0 and "Source: 1.12 estimate" or "No drop data for this mob yet.") .. hint
    end
    return header, out
  end,
  onRowEnter = function(_, line)
    local itemID, kind = line[1], line[3]
    if itemID == ns.GREY then
      GameTooltip:SetText("Grey items")
      GameTooltip:AddLine("Chance of at least one poor-quality (grey) item per kill.", 1, 1, 1, true)
    else
      GameTooltip:SetHyperlink("item:" .. itemID)
      if kind == "count" then
        GameTooltip:AddLine(("Chance of exactly %d."):format(line[5])
          .. " Ctrl+click to see every mob that gives it.", 0.6, 0.6, 0.6, true)
      elseif kind == "content" then
        GameTooltip:AddLine("Chance per container opened, from 1.12 data. Ctrl+click to see every mob that gives it.", 0.6, 0.6, 0.6)
      elseif kind == "gather" then
        GameTooltip:AddLine("Chance per corpse gathered. Ctrl+click to see every mob that gives it.", 0.6, 0.6, 0.6)
      elseif kind == "pick" then
        GameTooltip:AddLine("Chance per mob pick pocketed. Ctrl+click to see every mob that gives it.", 0.6, 0.6, 0.6)
      elseif kind == "quest" then
        GameTooltip:AddLine("Only drops while one of your quests needs it. Chance per kill."
          .. " Ctrl+click to see every mob that drops it.", 0.6, 0.6, 0.6, true)
      else
        GameTooltip:AddLine("Ctrl+click to see every mob that drops it.", 0.6, 0.6, 0.6)
      end
    end
  end,
  onRowClick = function(line)
    local itemID = line[1]
    if itemID ~= ns.GREY then
      local name = ns.ItemInfo(itemID)
      ns.ShowItemSearch(name, itemID)
    end
  end,
})

-- query: text to search for; npcID: optionally, which match to select.
function ns.ShowSearch(query, npcID) window:Open(query, npcID) end

-- Called when Shift is pressed or released.
function ns.RefreshSearch() window:Reselect() end
