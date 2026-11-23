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
  detail = function(r)
    local level = ns.LevelRange(r.minL, r.maxL)
    local header = {
      name = r.name,
      sub = (level ~= "" and ("Level " .. level .. "  ·  ") or "") .. "NPC " .. r.id,
    }
    local expand = IsShiftKeyDown()
    local lines, source, expandable = ns.Tooltip.Lines(r.id, ns.WINDOW_N, expand)
    if not lines or #lines == 0 then
      header.source = "No drop data for this mob yet."
      return header, {}
    end
    header.source = "Source: " .. source .. ((expandable and not expand) and "  ·  hold Shift for more" or "")
    local out = {}
    for i, line in ipairs(lines) do
      local left, right = ns.Tooltip.LineText(line, expand)
      out[i] = { left, right, line }
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
      if kind == "content" then
        GameTooltip:AddLine("Chance per container opened, from 1.12 data.", 0.6, 0.6, 0.6)
      else
        GameTooltip:AddLine("Click to see every mob that drops it.", 0.6, 0.6, 0.6)
      end
    end
  end,
  onRowClick = function(line)
    local itemID = line[1]
    if line[3] == "content" then return end
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
