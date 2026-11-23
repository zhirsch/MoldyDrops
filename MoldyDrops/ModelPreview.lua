local _, ns = ...

-- A small panel with a slowly turning 3D model of a mob, shown under the
-- GameTooltip while you hover a mob in the search windows.

local preview

local function Build()
  local f = CreateFrame("Frame", "MoldyDropsModelPreview", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(200, 220)
  f:SetFrameStrata("TOOLTIP")
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
  end
  local model = CreateFrame("PlayerModel", nil, f)
  model:SetPoint("TOPLEFT", 5, -5)
  model:SetPoint("BOTTOMRIGHT", -5, 5)
  f.model = model
  f.facing = 0
  f:SetScript("OnUpdate", function(self, elapsed)
    self.facing = (self.facing + (elapsed or 0) * 0.8) % (2 * math.pi)
    if self.model.SetFacing then self.model:SetFacing(self.facing) end
  end)
  f:Hide()
  return f
end

-- Shows npcID's model under the GameTooltip (or near the cursor if there's
-- no tooltip). The game's own data for the mob wins; the bundled 1.12 model
-- ID is passed along so mobs you haven't seen yet still show.
function ns.ShowModelPreview(npcID)
  if not npcID then return end
  preview = preview or Build()
  local model = preview.model
  local _, _, _, displayID = ns.MobInfo(npcID)
  if model.ClearModel then model:ClearModel() end
  local ok = model.SetCreature and pcall(model.SetCreature, model, npcID, displayID)
  if not ok and displayID and model.SetDisplayInfo then pcall(model.SetDisplayInfo, model, displayID) end
  preview.facing = 0
  preview:ClearAllPoints()
  if GameTooltip:IsShown() then
    preview:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -2)
  else
    preview:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", GetCursorPosition and select(1, GetCursorPosition()) or 0, 0)
  end
  preview:Show()
end

function ns.HideModelPreview()
  if preview then preview:Hide() end
end
