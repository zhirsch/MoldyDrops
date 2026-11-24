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

-- One toggle per data source, plus whatever options the source adds
-- (source.options: AceConfig args, shown under its toggle).
local SOURCES_ORDER = 30
local function AddSources(args)
  args.sourcesHeader = { type = "header", name = "Data sources", order = SOURCES_ORDER }
  local all = ns.Sources.All()
  args.sourcesIntro = {
    type = "description", order = SOURCES_ORDER + 0.1,
    name = #all == 0 and "No data sources are installed. Enable MoldyDrops_112 or MoldyDrops_Community"
        .. " in the AddOns list.\n"
      or "Where drop chances come from. For each mob the tooltip uses one source, never a mix:"
        .. " recorded data (community or yours) with the most kills once it has " .. ns.MIN_SAMPLE
        .. ", otherwise an estimate such as the 1.12 data.\n",
  }
  for i, src in ipairs(all) do
    local order = SOURCES_ORDER + i
    local group = {
      type = "group", inline = true, order = order, name = "",
      args = {
        enabled = {
          type = "toggle", order = 0, width = "full",
          name = src.name,
          desc = (type(src.description) == "string" and src.description or src.name)
            .. (src.observed and "\n\nRecorded data: used once it has " .. ns.MIN_SAMPLE .. " kills of a mob."
              or "\n\nEstimates: used while there isn't enough recorded data."),
          get = function() return ns.Sources.IsEnabled(src) end,
          set = function(_, v) ns.Sources.SetEnabled(src.id, v) end,
        },
      },
    }
    if type(src.options) == "table" then
      for k, v in pairs(src.options) do
        if type(v) == "table" then
          if v.order == nil then v.order = 1 end
          group.args["src_" .. k] = v
        end
      end
    end
    args["source_" .. src.id:gsub("[^%w]", "_")] = group
  end
end

-- The AceConfig options table. Exposed for tests.
function Options.Table()
  local t = {
    type = "group",
    name = ns.BRAND,
    args = {
      intro = {
        type = "description", order = 0, fontSize = "medium",
        name = "Drop chances in mob tooltips, from the data sources below.\n",
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
      requireModifier = {
        type = "toggle", order = 14, width = "full",
        name = "Only while a key is held",
        desc = "Shows the drops, gold and gathering sections only while the key below is held. "
          .. "Press it while hovering a mob to show them.",
        get = function() return Saved().requireModifier end,
        set = function(_, v) Saved().requireModifier = v end,
      },
      modifierKey = {
        type = "select", order = 15,
        name = "Key",
        desc = "The key to hold to see the drops in the tooltip.",
        values = { CTRL = "Ctrl", ALT = "Alt" },
        disabled = function() return not Saved().requireModifier end,
        get = function() return ns.MODIFIER_KEYS[Saved().modifierKey] and Saved().modifierKey or "CTRL" end,
        set = function(_, v) Saved().modifierKey = v end,
      },
      lootHeader = { type = "header", name = "Loot", order = 60 },
      record = {
        type = "toggle", order = 60.5, width = "full",
        name = "Record my loot",
        desc = "Records what you loot while solo, and everything you skin, gather and pick pocket, "
          .. "to share with /drops export. Turning it off keeps what's recorded so far. "
          .. "Whether the tooltip uses your recordings is the Your loot data source, above.",
        get = function() return Saved().record end,
        set = function(_, v) Saved().record = v end,
      },
      luck = {
        type = "toggle", order = 61, width = "full",
        name = "Luck tags on loot messages",
        desc = "Adds the chance and (Lucky!) to your loot messages when an item was unlikely (under 10%), "
          .. "like [4.2%] (Lucky!). The chance is gold, shading to orange the rarer it was.",
        get = function() return Saved().luck end,
        set = function(_, v) Saved().luck = v end,
      },
      chanceAlways = {
        type = "toggle", order = 61.5, width = "full",
        name = "Always show the drop chance on loot messages",
        desc = "Adds the chance to every loot message, like [45%], not just unlikely ones. "
          .. "White for likely items, grey for grey items.",
        get = function() return Saved().chanceAlways end,
        set = function(_, v) Saved().chanceAlways = v end,
      },
      debug = {
        type = "toggle", order = 62, width = "full",
        name = "Debug: print what each loot window recorded",
        desc = "Prints a chat line per loot window, to check that recording works.",
        get = function() return Saved().debug end,
        set = function(_, v) Saved().debug = v end,
      },
    },
  }
  AddSources(t.args)
  return t
end

function Options:Init()
  AceConfig:RegisterOptionsTable(APP, Options.Table)
  local _, id = AceConfigDialog:AddToBlizOptions(APP, ns.BRAND)
  categoryID = id
end

-- Re-reads the settings into the panel (e.g. after a slash command changed one).
function Options.Refresh()
  if categoryID or ns.db then AceConfigRegistry:NotifyChange(APP) end
end

-- Opens the game's options at MoldyDrops; falls back to AceConfig's own window.
function ns.ShowOptions()
  if categoryID and Settings and Settings.OpenToCategory then
    if pcall(Settings.OpenToCategory, categoryID) then return end
  end
  AceConfigDialog:Open(APP)
end
