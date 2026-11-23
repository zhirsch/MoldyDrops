local _, ns = ...

-- A search window with a search box, a list of matches on the left, and
-- details for the selected match on the right. Used by /drops search (mobs)
-- and /drops item (items).
--
-- spec fields:
--   name, title          global frame name and window title
--   search(query)        -> list of results, each with a unique .id
--   listText(r)          -> left text, right text for a result's list entry
--   detail(r)            -> header { name, sub, source }, lines { { left, right, data }, ... }
--   onRowEnter(row, data)  optional, fills GameTooltip for a detail line
--   onRowClick(data)       optional, called on Ctrl+click of a detail line
--   noun                 "mob" or "item", for the status text

local openFrames = {}     -- every search window's frame, to keep only one open
local windows = {}        -- every search window object
-- Back history, shared by both windows: { { win, query, selectedID }, ... }.
-- Cleared when the search window is closed.
local history = {}
local swapping = false    -- true while one window replaces another
local MAX_HISTORY = 50

function ns.SearchHistoryDepth() return #history end

local function UpdateBackButtons()
  for _, f in ipairs(openFrames) do
    if f.back then
      if #history > 0 then f.back:Enable() else f.back:Disable() end
    end
  end
end

local VISIBLE = 18        -- list entries shown
local DETAIL_ROWS = 18    -- detail lines shown
local MAX_RESULTS = 200
ns.SEARCH_MAX_RESULTS = MAX_RESULTS

local function CreateBaseFrame(name)
  local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "BasicFrameTemplateWithInset")
  if not ok then
    f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
  f:SetSize(680, 480)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  tinsert(UISpecialFrames, name)
  return f
end

function ns.CreateSearchWindow(spec)
  local win = { results = {}, offset = 0, query = "", lines = {}, detailOffset = 0 }
  local f -- built on first Open

  local function RenderDetail()
    local d = f.detail
    for i, row in ipairs(d.rows) do
      local line = win.lines[win.detailOffset + i]
      row.data = line and line[3]
      if line then
        row.name:SetText(line[1])
        row.pct:SetText(line[2] or "")
        row:Show()
      else
        row:Hide()
      end
    end
  end

  local function Select(r, keepScroll)
    local d = f.detail
    win.selected = r and r.id
    for _, b in ipairs(f.buttons) do b:UpdateHighlight() end
    if not keepScroll then win.detailOffset = 0 end
    if not r then
      d.name:SetText(""); d.sub:SetText(""); d.source:SetText("")
      win.lines = {}
    else
      local header, lines = spec.detail(r)
      d.name:SetText(header.name or "")
      d.sub:SetText(header.sub or "")
      d.source:SetText(header.source or "")
      win.lines = lines or {}
    end
    win.detailOffset = math.min(win.detailOffset, math.max(0, #win.lines - DETAIL_ROWS))
    RenderDetail()
  end

  local function RenderList()
    for i, b in ipairs(f.buttons) do
      local r = win.results[win.offset + i]
      b.result = r
      if r then
        local left, right = spec.listText(r)
        b.text:SetText(left)
        b.level:SetText(right or "")
        b:Show()
      else
        b:Hide()
      end
      b:UpdateHighlight()
    end
    local n = #win.results
    if win.query == "" then
      f.count:SetText("Type part of " .. (spec.noun == "item" and "an item's" or "a mob's") .. " name.")
    elseif n == 0 then
      f.count:SetText("No " .. spec.noun .. "s match.")
    else
      f.count:SetText(n >= MAX_RESULTS and ("First " .. n .. " matches") or (n == 1 and "1 match" or (n .. " matches")))
    end
  end

  local function RunSearch(query, selectID)
    win.query = query or ""
    win.results = spec.search(win.query)
    win.offset = 0
    local pick = win.results[1]
    if selectID then
      for i, r in ipairs(win.results) do
        if r.id == selectID then
          pick = r
          win.offset = math.max(0, math.min(i - 1, #win.results - VISIBLE))
          break
        end
      end
    end
    RenderList()
    Select(pick)
  end

  local function Build()
    f = CreateBaseFrame(spec.name)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText(spec.title)

    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(220, 20)
    box:SetPoint("TOPLEFT", 22, -34)
    box:SetAutoFocus(false)
    box:SetScript("OnTextChanged", function(self, userInput)
      if userInput then RunSearch(self:GetText()) end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    -- While the box has the cursor it gets the Shift key, not the game, so
    -- pass Shift presses on to the window (expands grey items / contents).
    local function OnShift(down)
      ns.shiftOverride = down
      win:Reselect()
      ns.shiftOverride = nil
    end
    box:SetScript("OnKeyDown", function(_, key)
      if key == "LSHIFT" or key == "RSHIFT" then OnShift(true) end
    end)
    box:SetScript("OnKeyUp", function(_, key)
      if key == "LSHIFT" or key == "RSHIFT" then OnShift(false) end
    end)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    f.box = box

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.count:SetPoint("BOTTOMLEFT", 18, 14)

    -- Back: return to the previous search (after Ctrl+click jumps).
    local back = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    back:SetSize(80, 22)
    back:SetPoint("BOTTOMRIGHT", -16, 10)
    back:SetText("< Back")
    back:SetScript("OnClick", function() ns.SearchBack() end)
    f.back = back

    -- Closing the search window (not swapping to the other one) ends the history.
    f:SetScript("OnHide", function()
      if not swapping then
        wipe(history)
        UpdateBackButtons()
      end
    end)

    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", 16, -62)
    list:SetSize(232, VISIBLE * 21)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
      local maxOffset = math.max(0, #win.results - VISIBLE)
      win.offset = math.min(maxOffset, math.max(0, win.offset - delta * 3))
      RenderList()
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
      b.text:SetWordWrap(false) -- one line; too-long text ends in "..."
      b.level = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      b.level:SetPoint("RIGHT", -6, 0)
      b.UpdateHighlight = function(self)
        self.sel:SetShown(self.result ~= nil and self.result.id == win.selected)
      end
      b:SetScript("OnClick", function(self) Select(self.result) end)
      f.buttons[i] = b
    end

    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", list, "TOPRIGHT", 16, 26)
    d:SetPoint("BOTTOMRIGHT", -18, 34)
    d:EnableMouseWheel(true)
    d:SetScript("OnMouseWheel", function(_, delta)
      local maxOffset = math.max(0, #win.lines - DETAIL_ROWS)
      win.detailOffset = math.min(maxOffset, math.max(0, win.detailOffset - delta * 3))
      RenderDetail()
    end)
    f.detail = d
    d.name = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.name:SetPoint("TOPLEFT")
    d.name:SetPoint("RIGHT")
    d.name:SetJustifyH("LEFT")
    d.name:SetWordWrap(false)
    d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.sub:SetPoint("TOPLEFT", d.name, "BOTTOMLEFT", 0, -4)
    d.source = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.source:SetPoint("TOPLEFT", d.sub, "BOTTOMLEFT", 0, -6)
    d.source:SetPoint("RIGHT")
    d.source:SetJustifyH("LEFT")

    d.rows = {}
    for i = 1, DETAIL_ROWS do
      local row = CreateFrame("Button", nil, d)
      row:SetHeight(17)
      row:SetPoint("TOPLEFT", d.source, "BOTTOMLEFT", 0, -10 - (i - 1) * 18)
      row:SetPoint("RIGHT", d, "RIGHT")
      row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.name:SetPoint("LEFT", 4, 0)
      row.name:SetPoint("RIGHT", -56, 0)
      row.name:SetJustifyH("LEFT")
      row.name:SetWordWrap(false) -- one line; hover the row for the full details
      row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.pct:SetPoint("RIGHT", -4, 0)
      row:SetScript("OnEnter", function(self)
        if spec.onRowEnter and self.data ~= nil then
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          spec.onRowEnter(self, self.data)
          GameTooltip:Show()
        end
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      -- Ctrl+click jumps to the other search (item -> /drops item, mob -> /drops search).
      row:SetScript("OnClick", function(self)
        if spec.onRowClick and self.data ~= nil and IsControlKeyDown() then spec.onRowClick(self.data) end
      end)
      row:Hide()
      d.rows[i] = row
    end
  end

  function win:IsShown() return f ~= nil and f:IsShown() end

  -- fromBack: reopening a history entry, so don't record the current view.
  function win:Open(query, selectID, fromBack)
    if not f then
      Build()
      openFrames[#openFrames + 1] = f
    end
    -- Remember what's on screen now, so Back can return to it.
    if not fromBack then
      for _, w in ipairs(windows) do
        if w:IsShown() and w.query ~= "" then
          history[#history + 1] = { w, w.query, w.selected }
          if #history > MAX_HISTORY then table.remove(history, 1) end
        end
      end
    end
    -- Only one search window at a time: if another is open (e.g. after a
    -- Ctrl+click jump), close it and open this one in its place.
    swapping = true
    for _, other in ipairs(openFrames) do
      if other ~= f and other:IsShown() then
        local left, top = other:GetLeft(), other:GetTop()
        other:Hide()
        if left and top then
          f:ClearAllPoints()
          f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
      end
    end
    swapping = false
    if spec.onOpen then spec.onOpen() end
    f:Show()
    f.box:SetText(query or "")
    f.box:SetFocus()
    f.box:HighlightText()
    RunSearch(query, selectID)
    UpdateBackButtons()
  end

  -- Redraw the selected entry (e.g. when Shift changes).
  function win:Reselect()
    if not (f and f:IsShown() and win.selected) then return end
    for _, r in ipairs(win.results) do
      if r.id == win.selected then Select(r, true) return end
    end
  end

  windows[#windows + 1] = win
  return win
end

-- Go back to the previous search, in whichever window it was.
function ns.SearchBack()
  local entry = table.remove(history)
  if not entry then return end
  entry[1]:Open(entry[2], entry[3], true)
end
