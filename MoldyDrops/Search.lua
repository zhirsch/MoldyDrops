local _, ns = ...

-- /drops search <mob name>: a window with matching mobs on the left and the
-- selected mob's drops on the right.

local MAX_RESULTS = 200
local VISIBLE = 18

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
  while #results > MAX_RESULTS do results[#results] = nil end
  return results
end

local function LevelText(r)
  if not r.minL then return "" end
  if r.minL == r.maxL then return "Level " .. r.minL end
  return ("Level %d-%d"):format(r.minL, r.maxL)
end

local frame

local function ShowMob(r)
  local d = frame.detail
  frame.selected = r and r.id
  for _, b in ipairs(frame.buttons) do b:UpdateHighlight() end
  for _, row in ipairs(d.rows) do row:Hide() end
  if not r then
    d.name:SetText("")
    d.sub:SetText("")
    d.source:SetText("")
    return
  end
  d.name:SetText(r.name)
  local level = LevelText(r)
  d.sub:SetText((level ~= "" and (level .. "  ·  ") or "") .. "NPC " .. r.id)
  local expand = IsShiftKeyDown()
  local lines, source, hasGreys = ns.Tooltip.Lines(r.id, ns.WINDOW_N, expand)
  if not lines or #lines == 0 then
    d.source:SetText("No drop data for this mob yet.")
    return
  end
  d.source:SetText("Source: " .. source)
  for i = 1, math.min(#d.rows, #lines) do
    local row = d.rows[i]
    local left, right = ns.Tooltip.LineText(lines[i], expand, hasGreys)
    row.itemID = lines[i][1]
    row.name:SetText(left)
    row.pct:SetText(right)
    row:Show()
  end
end

-- Called when Shift is pressed or released.
function ns.RefreshSearch()
  if frame and frame:IsShown() and frame.selected then
    for _, r in ipairs(frame.results) do
      if r.id == frame.selected then ShowMob(r) return end
    end
  end
end

local function Refresh()
  local results = frame.results
  local offset = frame.offset
  for i, b in ipairs(frame.buttons) do
    local r = results[offset + i]
    b.result = r
    if r then
      b.text:SetText(r.name)
      b.level:SetText(r.minL and (r.minL == r.maxL and tostring(r.minL) or (r.minL .. "-" .. r.maxL)) or "")
      b:Show()
    else
      b:Hide()
    end
    b:UpdateHighlight()
  end
  local n = #results
  if frame.query == "" then
    frame.count:SetText("Type part of a mob's name.")
  elseif n == 0 then
    frame.count:SetText("No mobs match.")
  else
    frame.count:SetText(n >= MAX_RESULTS and ("First " .. n .. " matches") or (n == 1 and "1 match" or (n .. " matches")))
  end
end

local function RunSearch(query)
  frame.query = query or ""
  frame.results = ns.SearchMobs(frame.query)
  frame.offset = 0
  Refresh()
  ShowMob(frame.results[1])
end

local function Build()
  local ok, f = pcall(CreateFrame, "Frame", "MoldyDropsSearchFrame", UIParent, "BasicFrameTemplateWithInset")
  if not ok then
    f = CreateFrame("Frame", "MoldyDropsSearchFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
  f:SetSize(580, 480)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  tinsert(UISpecialFrames, "MoldyDropsSearchFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText("MoldyDrops: Search")

  local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  box:SetSize(220, 20)
  box:SetPoint("TOPLEFT", 22, -34)
  box:SetAutoFocus(false)
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput then RunSearch(self:GetText()) end
  end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  f.box = box

  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.count:SetPoint("BOTTOMLEFT", 18, 14)

  -- Results list
  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", 16, -62)
  list:SetSize(232, VISIBLE * 21)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    local maxOffset = math.max(0, #f.results - VISIBLE)
    f.offset = math.min(maxOffset, math.max(0, f.offset - delta * 3))
    Refresh()
  end)

  f.buttons = {}
  for i = 1, VISIBLE do
    local b = CreateFrame("Button", nil, list)
    b:SetSize(232, 20)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * 21)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.18)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -44, 0)
    b.text:SetJustifyH("LEFT")
    b.level = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.level:SetPoint("RIGHT", -6, 0)
    b.UpdateHighlight = function(self)
      self.sel:SetShown(self.result ~= nil and self.result.id == f.selected)
    end
    b:SetScript("OnClick", function(self) ShowMob(self.result) end)
    f.buttons[i] = b
  end

  -- Detail pane
  local d = CreateFrame("Frame", nil, f)
  d:SetPoint("TOPLEFT", list, "TOPRIGHT", 16, 26)
  d:SetPoint("BOTTOMRIGHT", -18, 34)
  f.detail = d
  d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  d.name:SetPoint("TOPLEFT")
  d.name:SetPoint("RIGHT")
  d.name:SetJustifyH("LEFT")
  d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.sub:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -4)
  d.source = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  d.source:SetPoint("TOPLEFT", d.sub, "BOTTOMLEFT", 0, -6)
  d.source:SetPoint("RIGHT")
  d.source:SetJustifyH("LEFT")

  d.rows = {}
  for i = 1, ns.WINDOW_N + 8 do -- room for the grey list when Shift is held
    local row = CreateFrame("Button", nil, d)
    row:SetHeight(17)
    row:SetPoint("TOPLEFT", d.source, "BOTTOMLEFT", 0, -10 - (i - 1) * 18)
    row:SetPoint("RIGHT", d, "RIGHT")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetPoint("RIGHT", -56, 0)
    row.name:SetJustifyH("LEFT")
    row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.pct:SetPoint("RIGHT", -4, 0)
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if self.itemID == ns.GREY then
        GameTooltip:SetText("Grey items")
        GameTooltip:AddLine("Chance of at least one poor-quality (grey) item per kill.", 1, 1, 1, true)
      else
        GameTooltip:SetHyperlink("item:" .. self.itemID)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    d.rows[i] = row
  end

  f.results, f.offset, f.query = {}, 0, ""
  return f
end

function ns.ShowSearch(query)
  frame = frame or Build()
  frame:Show()
  frame.box:SetText(query or "")
  frame.box:SetFocus()
  frame.box:HighlightText()
  RunSearch(query)
end
