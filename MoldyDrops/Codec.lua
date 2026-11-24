local _, ns = ...

-- Exchange format (see docs/exchange-format.md):
--   "!MD1!" .. base64(text), where text is newline-separated records:
--     MD1 U <clientId> <unixTime> <addonVersion> <build>   (upload, addon -> site)
--     MD1 S <generatedUnixTime> <contributors>             (snapshot, site -> addon)
--     N <npcID> <kills> <itemID>:<count> ... [G:<corpses with any grey item>]
--       [E:<corpses with no items>] [$:<corpses with gold>:<total copper>:<min>:<max>]
--       [Q:<itemID>:<min count>:<max count> ...]   (also on S records)
--     I <itemID> <quality> <item name>
--     M <npcID> <mob name>
--     S <npcID> <kind 1-5> <corpses gathered> <itemID>:<count> ...   (skinning/herb/mining/engineering/pick pocket)
local Codec = {}
ns.Codec = Codec

local MAGIC = "!MD1!"
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local floor = math.floor
local enc, dec = {}, {}
for i = 1, 64 do
  local c = ALPHABET:sub(i, i)
  enc[i - 1] = c
  dec[c:byte()] = i - 1
end

function Codec.Base64Encode(s)
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    n = n + 1
    out[n] = enc[floor(v / 262144) % 64] .. enc[floor(v / 4096) % 64]
      .. (b and enc[floor(v / 64) % 64] or "=") .. (c and enc[v % 64] or "=")
  end
  return table.concat(out)
end

function Codec.Base64Decode(s)
  s = s:gsub("[^%w%+/]", "") -- drops whitespace and padding
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local c1, c2, c3, c4 = s:byte(i, i + 3)
    local v1, v2, v3, v4 = dec[c1], c2 and dec[c2], c3 and dec[c3], c4 and dec[c4]
    if not (v1 and v2) then break end
    local v = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
    n = n + 1
    if v4 then
      out[n] = string.char(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
    elseif v3 then
      out[n] = string.char(floor(v / 65536) % 256, floor(v / 256) % 256)
    else
      out[n] = string.char(floor(v / 65536) % 256)
    end
  end
  return table.concat(out)
end

local function SortedKeys(t, itemsOnly)
  local keys = {}
  for k in pairs(t) do
    -- itemsOnly: just positive item IDs (skips [0] kills, [-1] grey count, .kind)
    if type(k) == "number" and (not itemsOnly or k > 0) then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

-- "Q:<itemID>:<min>:<max>" tokens for items that came more than one at a time.
local function QtyTokens(parts, e)
  if not e.q then return end
  local ids = {}
  for itemID, q in pairs(e.q) do if q[2] > 1 then ids[#ids + 1] = itemID end end
  table.sort(ids)
  for _, itemID in ipairs(ids) do
    parts[#parts + 1] = ("Q:%d:%d:%d"):format(itemID, e.q[itemID][1], e.q[itemID][2])
    -- "C:<itemID>:<count>:<corpses>": how often exactly that many came
    local h = e.c and e.c[itemID]
    if h then
      local counts = {}
      for count in pairs(h) do counts[#counts + 1] = count end
      table.sort(counts)
      for _, count in ipairs(counts) do
        parts[#parts + 1] = ("C:%d:%d:%d"):format(itemID, count, h[count])
      end
    end
  end
end

-- Removes tokens whose numbers would look like item pairs ($ gold, Q and C
-- counts), and reads the Q ranges into e.q and the C tallies into e.c.
local function StripTokens(rest, e)
  for itemID, qmin, qmax in rest:gmatch("Q:(%d+):(%d+):(%d+)") do
    e.q = e.q or {}
    e.q[tonumber(itemID)] = { tonumber(qmin), tonumber(qmax) }
  end
  for itemID, count, n in rest:gmatch("C:(%d+):(%d+):(%d+)") do
    itemID = tonumber(itemID)
    e.c = e.c or {}
    e.c[itemID] = e.c[itemID] or {}
    e.c[itemID][tonumber(count)] = tonumber(n)
  end
  return (rest:gsub("%$:[%d:]+", ""):gsub("Q:[%d:]+", ""):gsub("C:[%d:]+", ""))
end

-- Turns a counted record into a data source entry (see docs/data-sources.md).
-- A counted record is what the recorder keeps and what a snapshot's N and S
-- records parse into: [0] = kills (or corpses gathered, mobs pick pocketed),
-- [itemID] = how many of those gave the item, [-1] = corpses with any grey
-- item, [-2] = corpses with no items, [-3] / [-4] / [-5] / [-6] = corpses
-- with gold / total / min / max copper, .kind (gathering 1-5), .q[itemID] =
-- { min, max } count, .c[itemID][count] = how often exactly that many came.
function Codec.Rates(e)
  local n = type(e) == "table" and tonumber(e[0]) or 0
  if not n or n <= 0 then return nil end
  local out = { samples = n, items = {}, kind = e.kind, qty = e.q, counts = e.c }
  for id, c in pairs(e) do
    if type(id) == "number" and id > 0 then out.items[id] = 100 * c / n end
  end
  if e[-1] then out.grey = 100 * e[-1] / n end
  if not e.kind then
    out.noItems = 100 * (e[-2] or 0) / n
    local gn = e[-3]
    if gn and gn > 0 then out.gold = { e[-5], e[-6], e[-4] / gn } end
  end
  return out
end

-- Builds the upload string from this install's own recorded loot: db has
-- clientId, own, ownGather, ownPick (counted records by NPC ID), and the
-- names in mobs[npcID] = { name } and items[itemID] = { name, quality }.
function Codec.Export(db, addonVersion, build)
  local lines = {
    ("MD1 U %s %d %s %s"):format(db.clientId, time and time() or 0, addonVersion or "0", build or "0"),
  }
  local itemsUsed, mobCount = {}, 0
  for _, npcID in ipairs(SortedKeys(db.own)) do
    local e = db.own[npcID]
    local kills = e[0] or 0
    if kills > 0 then
      local parts = { "N", npcID, kills }
      for _, itemID in ipairs(SortedKeys(e, true)) do
        parts[#parts + 1] = itemID .. ":" .. e[itemID]
        itemsUsed[itemID] = true
      end
      if e[-1] then parts[#parts + 1] = "G:" .. e[-1] end
      if e[-2] then parts[#parts + 1] = "E:" .. e[-2] end
      if e[-3] then parts[#parts + 1] = ("$:%d:%d:%d:%d"):format(e[-3], e[-4], e[-5], e[-6]) end
      QtyTokens(parts, e)
      lines[#lines + 1] = table.concat(parts, " ")
      mobCount = mobCount + 1
    end
  end
  local named = {}
  for _, tbl in ipairs({ db.ownGather or {}, db.ownPick or {} }) do
    for _, npcID in ipairs(SortedKeys(tbl)) do
      local e = tbl[npcID]
      if (e[0] or 0) > 0 and e.kind then
        local parts = { "S", npcID, e.kind, e[0] }
        for _, itemID in ipairs(SortedKeys(e, true)) do
          parts[#parts + 1] = itemID .. ":" .. e[itemID]
          itemsUsed[itemID] = true
        end
        QtyTokens(parts, e)
        lines[#lines + 1] = table.concat(parts, " ")
        named[npcID] = true
      end
    end
  end
  for _, npcID in ipairs(SortedKeys(db.own)) do
    if (db.own[npcID][0] or 0) > 0 then named[npcID] = true end
  end
  for _, npcID in ipairs(SortedKeys(named)) do
    local m = db.mobs and db.mobs[npcID]
    if m and m[1] then
      lines[#lines + 1] = ("M %d %s"):format(npcID, (m[1]:gsub("[\r\n]", " ")))
    end
  end
  for _, itemID in ipairs(SortedKeys(itemsUsed)) do
    local info = db.items and db.items[itemID]
    if info and info[1] then
      lines[#lines + 1] = ("I %d %d %s"):format(itemID, info[2] or 1, (info[1]:gsub("[\r\n]", " ")))
    end
  end
  return MAGIC .. Codec.Base64Encode(table.concat(lines, "\n")), mobCount
end

-- Parses a snapshot string from the website.
-- Returns community table, items table, or nil and an error message.
function Codec.ParseSnapshot(str)
  str = (str or ""):gsub("^%s+", "")
  if str:sub(1, #MAGIC) ~= MAGIC then
    return nil, "that doesn't look like a MoldyDrops string (it should start with " .. MAGIC .. ")"
  end
  local text = Codec.Base64Decode(str:sub(#MAGIC + 1))
  local header = text:match("^[^\n]*")
  local kind = header:match("^MD1 (%a) ")
  local generated, contributors = header:match("^MD1 S (%d+) (%d+)")
  if kind == "U" then
    return nil, "that's an upload string from the addon. Paste it on the website; import the string the website gives you."
  elseif kind ~= "S" or not generated then
    return nil, "the string is damaged or from an incompatible version"
  end

  local npcs, items, mobs, gather, pick, count = {}, {}, {}, {}, {}, 0
  for line in text:gmatch("[^\n]+") do
    local tag = line:sub(1, 2)
    if tag == "N " then
      local npcID, kills, rest = line:match("^N (%d+) (%d+)(.*)$")
      npcID, kills = tonumber(npcID), tonumber(kills)
      if npcID and kills and kills > 0 then
        local e = { [0] = kills }
        -- Item pairs; $ and Q tokens are removed first so their numbers aren't read as items.
        for itemID, c in StripTokens(rest, e):gmatch("(%d+):(%d+)") do
          itemID = tonumber(itemID)
          if itemID > 0 then e[itemID] = math.min(tonumber(c), kills) end
        end
        local grey = rest:match("G:(%d+)")
        if grey then e[-1] = math.min(tonumber(grey), kills) end
        local empty = rest:match("E:(%d+)")
        if empty then e[-2] = math.min(tonumber(empty), kills) end
        local gn, gsum, gmin, gmax = rest:match("%$:(%d+):(%d+):(%d+):(%d+)")
        gn = tonumber(gn)
        if gn and gn > 0 then
          e[-3], e[-4], e[-5], e[-6] = math.min(gn, kills), tonumber(gsum), tonumber(gmin), tonumber(gmax)
        end
        npcs[npcID] = e
        count = count + 1
      end
    elseif tag == "I " then
      local itemID, quality, name = line:match("^I (%d+) (%d+) (.+)$")
      if itemID then items[tonumber(itemID)] = { name, tonumber(quality) } end
    elseif tag == "M " then
      local npcID, name = line:match("^M (%d+) (.+)$")
      if npcID then mobs[tonumber(npcID)] = { name } end
    elseif tag == "S " then
      local npcID, gkind, corpses, rest = line:match("^S (%d+) (%d) (%d+)(.*)$")
      npcID, gkind, corpses = tonumber(npcID), tonumber(gkind), tonumber(corpses)
      if npcID and gkind and gkind >= 1 and gkind <= 5 and corpses and corpses > 0 then
        local e = { kind = gkind, [0] = corpses }
        for itemID, c in StripTokens(rest, e):gmatch("(%d+):(%d+)") do
          itemID = tonumber(itemID)
          if itemID > 0 then e[itemID] = math.min(tonumber(c), corpses) end
        end
        if gkind == 5 then pick[npcID] = e else gather[npcID] = e end
      end
    end
  end
  return {
    npcs = npcs,
    gather = gather,
    pick = pick,
    generated = date and date("%Y-%m-%d", tonumber(generated)) or generated,
    generatedAt = tonumber(generated), -- unix time, to tell which of two snapshots is newer
    contributors = tonumber(contributors),
  }, items, count, mobs
end
