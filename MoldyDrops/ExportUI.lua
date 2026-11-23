local ADDON, ns = ...

-- One window, used both to copy the export string and to paste an import.
local frame

local function GetAddOnVersion()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return get and get(ADDON, "Version") or "0"
end

local function Build()
  local ok, f = pcall(CreateFrame, "Frame", "MoldyDropsExportFrame", UIParent, "BasicFrameTemplateWithInset")
  if not ok then
    f = CreateFrame("Frame", "MoldyDropsExportFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
      f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
      })
    end
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
  end
  f:SetSize(520, 340)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  tinsert(UISpecialFrames, "MoldyDropsExportFrame") -- Escape closes it

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", 0, -6)

  f.help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.help:SetPoint("TOPLEFT", 16, -32)
  f.help:SetPoint("TOPRIGHT", -16, -32)
  f.help:SetJustifyH("LEFT")

  local scroll = CreateFrame("ScrollFrame", "MoldyDropsExportScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -64)
  scroll:SetPoint("BOTTOMRIGHT", -34, 44)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetMaxLetters(0)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(460)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(edit)
  f.edit = edit

  f.button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.button:SetSize(120, 24)
  f.button:SetPoint("BOTTOMRIGHT", -16, 12)

  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.status:SetPoint("BOTTOMLEFT", 18, 18)
  f.status:SetPoint("RIGHT", f.button, "LEFT", -8, 0)
  f.status:SetJustifyH("LEFT")

  return f
end

local function Open(title, help)
  frame = frame or Build()
  frame.title:SetText(title)
  frame.help:SetText(help)
  frame.status:SetText("")
  frame.edit:SetText("")
  frame.edit:SetScript("OnTextChanged", nil)
  frame:Show()
  return frame
end

function ns.ShowExport()
  local str, npcCount = ns.Codec.Export(ns.db, GetAddOnVersion(), select(4, GetBuildInfo()))
  ns.db.lastExport = time()
  local f = Open("MoldyDrops: Export",
    "Press Ctrl+C to copy, then paste it on the MoldyDrops website. It contains only the loot you recorded, under a random ID.")
  f.edit:SetText(str)
  f.edit:HighlightText()
  f.edit:SetFocus()
  f.status:SetText(("%d mobs, %d characters"):format(npcCount, #str))
  f.button:SetText("Close")
  f.button:SetScript("OnClick", function() f:Hide() end)
  -- Keep the text from being edited by accident.
  f.edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput then self:SetText(str); self:HighlightText() end
  end)
end

function ns.ShowImport()
  local f = Open("MoldyDrops: Import",
    "Paste the string from the MoldyDrops website (Ctrl+V), then click Import. It replaces the community data; your own recordings are kept.")
  f.edit:SetFocus()
  f.button:SetText("Import")
  f.button:SetScript("OnClick", function()
    local community, items, count, mobs = ns.Codec.ParseSnapshot(f.edit:GetText())
    if not community then
      f.status:SetText("|cffff4040" .. items .. "|r")
      return
    end
    ns.db.community = community
    for id, info in pairs(items) do
      if not ns.db.items[id] then ns.db.items[id] = info end
    end
    for id, info in pairs(mobs) do
      if not ns.db.mobs[id] then ns.db.mobs[id] = info end
    end
    ns.Print(("imported community data for %d mobs from %d contributors (generated %s)."):format(
      count, community.contributors or 0, community.generated or "?"))
    f:Hide()
  end)
end
