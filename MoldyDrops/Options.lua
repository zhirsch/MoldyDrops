local _, ns = ...

-- Options, built with AceConfig-3.0 so they show up in the game's own
-- Options > AddOns > MoldyDrops panel. /drops options opens it.

-- Libraries come from LibStub (bundled in embeds.xml; LibStub hands back the
-- newest copy any loaded addon provides).
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

local Options = {}
ns.Options = Options

local APP = "MoldyDrops"
local categoryID

local function Saved() return ns.db.settings end

-- The AceConfig options table. Exposed for tests.
function Options.Table()
  return {
    type = "group",
    name = "MoldyDrops",
    args = {
      intro = {
        type = "description", order = 0, fontSize = "medium",
        name = "Drop chances in mob tooltips, from the 1.12 data and from what you and the community record.\n",
      },
      tooltipHeader = { type = "header", name = "Tooltip", order = 10 },
      enabled = {
        type = "toggle", order = 11, width = "full",
        name = "Show drops in tooltips",
        desc = "Adds the drops, gold and gathering sections to mob tooltips.",
        get = function() return Saved().enabled end,
        set = function(_, v) Saved().enabled = v end,
      },
      topN = {
        type = "range", order = 12, width = "double",
        name = "Items shown in the tooltip",
        desc = "How many drops the tooltip lists. The search windows always show every drop. "
          .. "The bundled 1.12 data keeps each mob's top " .. ns.TOP_N_MAX .. ".",
        min = 1, max = ns.TOP_N_MAX, step = 1,
        get = function() return ns.TopN() end,
        set = function(_, v) Saved().topN = v end,
      },
      instances = {
        type = "toggle", order = 13, width = "full",
        name = "Also in dungeons and raids",
        desc = "Shows the tooltip and records loot inside instances too. Off by default: the data is for the open world.",
        get = function() return not Saved().openWorldOnly end,
        set = function(_, v) Saved().openWorldOnly = not v end,
      },
      lootHeader = { type = "header", name = "Loot", order = 20 },
      luck = {
        type = "toggle", order = 21, width = "full",
        name = "Luck tags on loot messages",
        desc = "Adds (Lucky! 4.2%) to your loot messages when an item was unlikely.",
        get = function() return Saved().luck end,
        set = function(_, v) Saved().luck = v end,
      },
      debug = {
        type = "toggle", order = 22, width = "full",
        name = "Debug: print what each loot window recorded",
        desc = "Prints a chat line per loot window, to check that recording works.",
        get = function() return Saved().debug end,
        set = function(_, v) Saved().debug = v end,
      },
    },
  }
end

function Options:Init()
  AceConfig:RegisterOptionsTable(APP, Options.Table)
  local _, id = AceConfigDialog:AddToBlizOptions(APP, "MoldyDrops")
  categoryID = id
end

-- Re-reads the settings into the panel (e.g. after a slash command changed one).
function Options.Refresh()
  AceConfigRegistry:NotifyChange(APP)
end

-- Opens the game's options at MoldyDrops; falls back to AceConfig's own window.
function ns.ShowOptions()
  if categoryID and Settings and Settings.OpenToCategory then
    if pcall(Settings.OpenToCategory, categoryID) then return end
  end
  AceConfigDialog:Open(APP)
end
