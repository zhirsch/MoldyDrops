local _, ns = ...

-- One window with a big text box, a status line and a button. The data
-- source addons use it (MoldyDrops.OpenTextWindow) to copy the export string
-- and to paste an import.
local frame

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

-- Opens the window, empty, with a title ("Export" becomes "MoldyDrops: Export")
-- and help text. Returns the frame: .edit (EditBox), .button, .status, .title, .help.
function ns.OpenTextWindow(title, help)
  frame = frame or Build()
  frame.title:SetText(ns.BRAND .. ": " .. tostring(title))
  frame.help:SetText(help or "")
  frame.status:SetText("")
  frame.edit:SetText("")
  frame.edit:SetScript("OnTextChanged", nil)
  frame.button:SetScript("OnClick", function() frame:Hide() end)
  frame.button:SetText("Close")
  frame:Show()
  return frame
end
