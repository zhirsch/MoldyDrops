local _, ns = ...

-- Exchange format (see docs/exchange-format.md):
--   "!MD1!" .. base64(text), where text is newline-separated records:
--     MD1 U <clientId> <unixTime> <addonVersion> <build>   (upload, addon -> site)
--     MD1 S <generatedUnixTime> <contributors>             (snapshot, site -> addon)
--     N <npcID> <kills> <itemID>:<count> ... [G:<corpses with any grey item>]
--     I <itemID> <quality> <item name>
--     M <npcID> <mob name>
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
    if not itemsOnly or k > 0 then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

-- Builds the upload string from this install's own recorded loot.
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
      lines[#lines + 1] = table.concat(parts, " ")
      mobCount = mobCount + 1
    end
  end
  for _, npcID in ipairs(SortedKeys(db.own)) do
    local m = db.mobs[npcID]
    if m and m[1] and (db.own[npcID][0] or 0) > 0 then
      lines[#lines + 1] = ("M %d %s"):format(npcID, (m[1]:gsub("[\r\n]", " ")))
    end
  end
  for _, itemID in ipairs(SortedKeys(itemsUsed)) do
    local info = db.items[itemID]
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

  local npcs, items, mobs, count = {}, {}, {}, 0
  for line in text:gmatch("[^\n]+") do
    local tag = line:sub(1, 2)
    if tag == "N " then
      local npcID, kills, rest = line:match("^N (%d+) (%d+)(.*)$")
      npcID, kills = tonumber(npcID), tonumber(kills)
      if npcID and kills and kills > 0 then
        local e = { [0] = kills }
        for itemID, c in rest:gmatch("(%d+):(%d+)") do
          itemID = tonumber(itemID)
          if itemID > 0 then e[itemID] = math.min(tonumber(c), kills) end
        end
        local grey = rest:match("G:(%d+)")
        if grey then e[-1] = math.min(tonumber(grey), kills) end
        npcs[npcID] = e
        count = count + 1
      end
    elseif tag == "I " then
      local itemID, quality, name = line:match("^I (%d+) (%d+) (.+)$")
      if itemID then items[tonumber(itemID)] = { name, tonumber(quality) } end
    elseif tag == "M " then
      local npcID, name = line:match("^M (%d+) (.+)$")
      if npcID then mobs[tonumber(npcID)] = { name } end
    end
  end
  return {
    npcs = npcs,
    generated = date and date("%Y-%m-%d", tonumber(generated)) or generated,
    contributors = tonumber(contributors),
  }, items, count, mobs
end
