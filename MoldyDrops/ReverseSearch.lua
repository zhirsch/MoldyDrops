local _, ns = ...

-- /drops rsearch <item name>: matching items on the left, every mob known to
-- drop the selected item on the right, highest chance first.
--
-- The chances are the ones the tooltip would show for each mob (observed
-- rates once there are enough kills, otherwise the 1.12 estimate). The bundled
-- 1.12 data keeps only each mob's top 10 drops (and top 10 grey items), so
-- very rare drops, like world drops spread across hundreds of mobs, may be
-- missing from this list.

local index -- [itemID] = { { npcID, percent, note }, ... }

-- Builds the item -> mobs index from everything the tooltip can show.
function ns.BuildDropIndex()
  index = {}
  local function put(itemID, npcID, pct, note, gatherKind)
    if itemID == ns.GREY then return end
    index[itemID] = index[itemID] or {}
    table.insert(index[itemID], { npcID, pct, note, gatherKind })
  end
  local seen, seenGather = {}, {}
  local function add(npcID)
    if seen[npcID] then return end
    seen[npcID] = true
    local rows, greys, note = ns.Tooltip.Choose(npcID)
    if not rows then return end
    for _, list in ipairs({ rows, greys }) do
      for _, r in ipairs(list) do put(r[1], npcID, r[2], note) end
    end
  end
  local function addGather(npcID)
    if seenGather[npcID] then return end
    seenGather[npcID] = true
    local kind, rows, note = ns.Tooltip.Gather(npcID)
    if not kind then return end
    for _, r in ipairs(rows) do put(r[1], npcID, r[2], note, kind) end
  end
  for id in pairs(ns.base or {}) do add(id) end
  for id in pairs(ns.db.own) do add(id) end
  for id in pairs(ns.db.community.npcs or {}) do add(id) end
  for id in pairs(ns.gather or {}) do addGather(id) end
  for id in pairs(ns.db.ownGather) do addGather(id) end
  for id in pairs(ns.db.community.gather or {}) do addGather(id) end
  return index
end

-- Items whose names contain the query and that some mob drops.
function ns.SearchItems(query)
  query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return {} end
  if not index then ns.BuildDropIndex() end
  local results = {}
  for itemID, mobs in pairs(index) do
    local name, quality = ns.ItemInfo(itemID)
    local lower = name:lower()
    local pos = lower:find(query, 1, true)
    if pos then
      results[#results + 1] = {
        id = itemID, name = name, quality = quality, mobCount = #mobs,
        rank = (lower == query and 0) or (pos == 1 and 1) or 2,
      }
    end
  end
  table.sort(results, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  while #results > ns.SEARCH_MAX_RESULTS do results[#results] = nil end
  return results
end

-- Mobs that give an item: { { id, name, minL, maxL, pct, note, gather }, ... },
-- highest chance first. gather is the gathering kind (1-4) when the item
-- comes from skinning/herbalism/mining/engineering the corpse, else nil.
function ns.MobsDropping(itemID)
  if not index then ns.BuildDropIndex() end
  local out = {}
  for _, e in ipairs(index[itemID] or {}) do
    local name, minL, maxL = ns.MobInfo(e[1])
    out[#out + 1] = { id = e[1], name = name or ("NPC " .. e[1]), minL = minL, maxL = maxL, pct = e[2], note = e[3], gather = e[4] }
  end
  table.sort(out, function(a, b)
    if a.pct ~= b.pct then return a.pct > b.pct end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return out
end

local window = ns.CreateSearchWindow({
  name = "MoldyDropsItemSearchFrame",
  title = "MoldyDrops: Search items",
  noun = "item",
  onOpen = function() ns.BuildDropIndex() end, -- pick up new recordings and imports
  search = ns.SearchItems,
  listText = function(r)
    return ns.QualityHex(r.quality or 1) .. r.name .. "|r", tostring(r.mobCount)
  end,
  detail = function(r)
    local mobs = ns.MobsDropping(r.id)
    local header = {
      name = ns.QualityHex(r.quality or 1) .. r.name .. "|r",
      sub = "Item " .. r.id,
      source = (#mobs == 1 and "1 mob" or (#mobs .. " mobs")) .. "; chance per kill, or per corpse gathered.",
    }
    local lines = {}
    for i, m in ipairs(mobs) do
      local level = ns.LevelRange(m.minL, m.maxL)
      local how = m.gather and ("  |cffffd100" .. (ns.GATHER_NAMES[m.gather] or "Gathering") .. "|r") or ""
      lines[i] = {
        m.name .. (level ~= "" and ("  |cff808080" .. level .. "|r") or "") .. how,
        ns.FormatPct(m.pct),
        m,
      }
    end
    return header, lines
  end,
  onRowEnter = function(_, m)
    GameTooltip:SetText(m.name)
    if m.gather then
      GameTooltip:AddLine((ns.GATHER_NAMES[m.gather] or "Gathering") .. " the corpse: chance per corpse gathered.", 1, 1, 1, true)
    end
    GameTooltip:AddLine("Source: " .. (m.note or "?"), 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Click to see all its drops.", 0.6, 0.6, 0.6)
  end,
  onRowClick = function(m) ns.ShowSearch(m.name, m.id) end,
})

-- query: text to search for; itemID: optionally, which match to select.
function ns.ShowItemSearch(query, itemID) window:Open(query, itemID) end
