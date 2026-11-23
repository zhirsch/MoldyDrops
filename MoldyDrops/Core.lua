local ADDON, ns = ...

ns.PREFIX = "|cffffd100MoldyDrops:|r "
ns.MIN_SAMPLE = 20   -- kills needed before observed rates replace the 1.12 estimate
ns.TOP_N = 5         -- rows in the tooltip
ns.WINDOW_N = 10     -- rows in the /drops search window

function ns.Print(msg) print(ns.PREFIX .. msg) end

-- SavedVariables layout
--   MoldyDropsDB.clientId          random ID that identifies this install's uploads
--   MoldyDropsDB.settings          { enabled, openWorldOnly }
--   MoldyDropsDB.own[npcID]        { [0] = kills, [-1] = corpses with any grey item,
--                                    [itemID] = corpses that dropped it }
--   MoldyDropsDB.community         { npcs = same shape as own, contributors, generated }
--   MoldyDropsDB.items[itemID]     { name, quality } for items seen in loot or imported
--   MoldyDropsDB.mobs[npcID]       { name } for mobs seen in game or imported
local function NewClientId()
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local t = {}
  for i = 1, 16 do
    local n = math.random(1, #chars)
    t[i] = chars:sub(n, n)
  end
  return table.concat(t)
end

local function InitDB()
  MoldyDropsDB = MoldyDropsDB or {}
  local db = MoldyDropsDB
  db.settings = db.settings or {}
  if db.settings.enabled == nil then db.settings.enabled = true end
  if db.settings.openWorldOnly == nil then db.settings.openWorldOnly = true end
  db.own = db.own or {}
  db.community = db.community or { npcs = {} }
  db.items = db.items or {}
  db.mobs = db.mobs or {}
  if not db.clientId then
    -- No math.randomseed: WoW removes it and seeds math.random itself.
    db.clientId = NewClientId()
  end
  ns.db = db
end

-- Item name/quality: what we've seen in game first, then the bundled table.
ns.GREY = 0  -- pseudo item ID for "any grey (poor quality) item"

function ns.ItemInfo(itemID)
  if itemID == ns.GREY then return "Grey items", 0 end
  local seen = ns.db and ns.db.items[itemID]
  if seen then return seen[1], seen[2] end
  local base = ns.items and ns.items[itemID]
  if base then return base[1], base[2] end
  if GetItemInfo then
    local name, _, quality = GetItemInfo(itemID)
    if name then return name, quality end
  end
  return "item:" .. itemID, 1
end

-- Mob name and level range (levels only known for bundled 1.12 mobs).
function ns.MobInfo(npcID)
  local base = ns.mobs and ns.mobs[npcID]
  local seen = ns.db and ns.db.mobs[npcID]
  local name = (seen and seen[1]) or (base and base[1])
  return name, base and base[2], base and base[3]
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  InitDB()
  if ns.Recorder then ns.Recorder:Init() end
  if ns.Tooltip then ns.Tooltip:Init() end
  self:UnregisterEvent("ADDON_LOADED")
end)

-- Returns mobs, total kills, mobs with at least MIN_SAMPLE kills, distinct items.
local function CountNpcs(t)
  local n, kills, solid, items = 0, 0, 0, {}
  for _, e in pairs(t or {}) do
    n = n + 1
    local k = e[0] or 0
    kills = kills + k
    if k >= ns.MIN_SAMPLE then solid = solid + 1 end
    for id in pairs(e) do if id > 0 then items[id] = true end end
  end
  local ni = 0
  for _ in pairs(items) do ni = ni + 1 end
  return n, kills, solid, ni
end

local function Count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function PrintStats()
  local db = ns.db
  local W = "|cffffffff"
  ns.Print("database status")
  print(("  1.12 estimates (bundled): %s%d|r mobs, %s%d|r items"):format(W, Count(ns.base), W, Count(ns.items)))

  local n, k, solid, items = CountNpcs(db.own)
  print(("  Your recordings: %s%d|r kills of %s%d|r mobs, %s%d|r different items; %s%d|r mobs have %d+ kills"):format(
    W, k, W, n, W, items, W, solid, ns.MIN_SAMPLE))
  print(("    last export: %s"):format(db.lastExport and date("%Y-%m-%d %H:%M", db.lastExport) or "never"))

  local c = db.community
  if c and c.generated then
    local cn, ck, csolid, citems = CountNpcs(c.npcs)
    print(("  Community data: %s%d|r kills of %s%d|r mobs, %s%d|r different items; %s%d|r mobs have %d+ kills"):format(
      W, ck, W, cn, W, citems, W, csolid, ns.MIN_SAMPLE))
    print(("    from %s%d|r contributors, generated %s"):format(W, c.contributors or 0, c.generated))
  else
    print("  Community data: none yet. Get it from the website and use /drops import.")
  end

  print(("  Names known in game: %s%d|r mobs, %s%d|r items"):format(W, Count(db.mobs), W, Count(db.items)))
  print(("  Tooltip: %s, %s; recording only while solo"):format(
    db.settings.enabled and "on" or "off", db.settings.openWorldOnly and "open world only" or "everywhere"))
end

local HELP = {
  "|cffffffff/drops search <mob name>|r - find a mob and show its drops",
  "|cffffffff/drops export|r - copy your recorded loot to upload to the website",
  "|cffffffff/drops import|r - paste community data from the website",
  "|cffffffff/drops stats|r - show the state of the database",
  "|cffffffff/drops tooltip|r - turn the tooltip on or off",
  "|cffffffff/drops instances|r - also show the tooltip inside dungeons and raids",
  "|cffffffff/drops reset|r - delete the loot you've recorded",
}

SLASH_MOLDYDROPS1 = "/drops"
SLASH_MOLDYDROPS2 = "/moldydrops"
SlashCmdList.MOLDYDROPS = function(msg)
  local db = ns.db
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "search" or cmd == "s" then
    ns.ShowSearch(rest)
  elseif cmd == "export" then
    ns.ShowExport()
  elseif cmd == "import" then
    ns.ShowImport()
  elseif cmd == "tooltip" then
    db.settings.enabled = not db.settings.enabled
    ns.Print(db.settings.enabled and "tooltip enabled" or "tooltip disabled")
  elseif cmd == "instances" then
    db.settings.openWorldOnly = not db.settings.openWorldOnly
    ns.Print(db.settings.openWorldOnly and "open world only" or "showing in instances too")
  elseif cmd == "stats" then
    PrintStats()
  elseif cmd == "reset" then
    if rest == "confirm" then
      db.own = {}
      ns.Print("your recorded loot was deleted.")
    else
      ns.Print("this deletes all loot you've recorded. Type |cffffffff/drops reset confirm|r to do it.")
    end
  else
    ns.Print("commands:")
    for _, line in ipairs(HELP) do print("  " .. line) end
  end
end
