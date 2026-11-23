local _, ns = ...

-- /drops item <item name>: matching items on the left, every mob known to
-- give the selected item on the right (drops, gathering, pick pocketing for
-- rogues, and inside containers they drop), highest chance first.
--
-- The chances are the ones the tooltip would show for each mob (observed
-- rates once there are enough kills, otherwise the 1.12 estimate). The bundled
-- 1.12 data keeps only each mob's top 10 drops (and top 10 grey items), so
-- very rare drops, like world drops spread across hundreds of mobs, may be
-- missing from this list.

local index -- [itemID] = { { npcID, percent, note, gatherKind, viaContainerID }, ... }

-- Builds the item -> mobs index from everything the tooltip can show:
-- drops, gathering, pick pocketing (rogues), and the contents of containers
-- from any of those (chance = container chance x chance inside it).
function ns.BuildDropIndex()
  index = {}
  local function put(itemID, npcID, pct, note, gatherKind, via)
    if itemID == ns.GREY then return end
    index[itemID] = index[itemID] or {}
    -- how many come at once, from the matching section
    local section = via and "content" or (gatherKind == ns.PICKPOCKET and "pick") or (gatherKind and "gather") or "drop"
    local qmin, qmax = ns.Tooltip.Qty(section, via or npcID, itemID)
    table.insert(index[itemID], { npcID, pct, note, gatherKind, via, qmax and { qmin, qmax } or nil })
    local inside = not via and ns.Tooltip.Contents(itemID)
    for _, c in ipairs(inside or {}) do
      put(c[1], npcID, pct * c[2] / 100, note, gatherKind, itemID)
    end
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
  -- Pick pocketing, for rogues.
  if ns.IsRogue() then
    local seenPick = {}
    local function addPick(npcID)
      if seenPick[npcID] then return end
      seenPick[npcID] = true
      local kind, rows, note = ns.Tooltip.Pick(npcID)
      if not kind then return end
      for _, r in ipairs(rows) do put(r[1], npcID, r[2], note, kind) end
    end
    for id in pairs(ns.pick or {}) do addPick(id) end
    for id in pairs(ns.db.ownPick) do addPick(id) end
    for id in pairs(ns.db.community.pick or {}) do addPick(id) end
  end
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

-- Mobs that give an item: { { id, name, minL, maxL, pct, note, gather, via }, ... },
-- highest chance first. gather is the kind (1-4 gathering, 5 pick pocket)
-- when it doesn't come from the corpse's loot; via is the container item it
-- comes inside, if any. pct is always per kill / corpse / mob, overall.
function ns.MobsDropping(itemID)
  if not index then ns.BuildDropIndex() end
  local out = {}
  for _, e in ipairs(index[itemID] or {}) do
    local name, minL, maxL = ns.MobInfo(e[1])
    out[#out + 1] = { id = e[1], name = name or ("NPC " .. e[1]), minL = minL, maxL = maxL, pct = e[2], note = e[3],
      gather = e[4], via = e[5], qty = e[6] }
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
      local via = m.via and ("  |cff808080in " .. ns.ItemInfo(m.via) .. "|r") or ""
      lines[i] = {
        m.name .. (level ~= "" and ("  |cff808080" .. level .. "|r") or "")
          .. (m.qty and ns.QtyText(m.qty[1], m.qty[2]) or "") .. how .. via,
        ns.ColoredPct(m.pct, r.quality),
        m,
      }
    end
    return header, lines
  end,
  onRowEnter = function(_, m)
    GameTooltip:SetText(m.name)
    if m.gather == ns.PICKPOCKET then
      GameTooltip:AddLine("Pick Pocket: chance per mob pick pocketed.", 1, 1, 1, true)
    elseif m.gather then
      GameTooltip:AddLine((ns.GATHER_NAMES[m.gather] or "Gathering") .. " the corpse: chance per corpse gathered.", 1, 1, 1, true)
    end
    if m.via then
      GameTooltip:AddLine("Comes inside " .. ns.ItemInfo(m.via) .. ". The chance includes getting the container"
        .. " (container chance from the source below, contents from 1.12 data).", 1, 1, 1, true)
    end
    GameTooltip:AddLine("Source: " .. (m.note or "?"), 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Ctrl+click to see all its drops.", 0.6, 0.6, 0.6)
  end,
  onRowClick = function(m) ns.ShowSearch(m.name, m.id) end,
  rowModel = function(m) return m.id end, -- mob rows: show the mob's 3D model
  -- Item list: the game's item tooltip.
  onListEnter = function(_, r)
    GameTooltip:SetHyperlink("item:" .. r.id)
  end,
})

-- query: text to search for; itemID: optionally, which match to select.
function ns.ShowItemSearch(query, itemID) window:Open(query, itemID) end
