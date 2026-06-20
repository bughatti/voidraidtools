----------------------------------------------------------------------
-- VoidRaidTools Minimap — standardized minimap button.
-- Global name VoidRaidToolsMinimapBtn so VoidHubBundle discovers it.
--
--   Size: 28x28 button, 20x20 icon, 54x54 border, offset (-2, 2)
--   Radius: (Minimap:GetWidth() / 2) + 6
--   Angle stored as DEGREES in VoidRaidToolsCharDB.minimapAngle (default 230)
--
-- Click behavior:
--   Left  -> open VRT Panel (or /vrt panel)
--   Right -> /vrt edit (move-mode for raid frames)
----------------------------------------------------------------------
local btn

local function PositionButton(b)
    VoidRaidToolsCharDB = VoidRaidToolsCharDB or {}
    local angle  = math.rad(VoidRaidToolsCharDB.minimapAngle or 230)
    local radius = (Minimap:GetWidth() / 2) + 6
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function CreateMinimapButton()
    if btn then return btn end
    if _G.VoidRaidToolsMinimapBtn then btn = _G.VoidRaidToolsMinimapBtn; return btn end
    if not Minimap then return end

    btn = CreateFrame("Button", "VoidRaidToolsMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\Spell_Arcane_Arcane01")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if VRT and VRT.ToggleEditMode then VRT:ToggleEditMode() end
        else
            if VRT and VRT.TogglePanel then VRT:TogglePanel() end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidRaidTools|r", 1, 1, 1)
        GameTooltip:AddLine("Left-click: open panel", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-click: edit mode (move frames)", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Drag: reposition around minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) self._dragging = true end)
    btn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    btn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            if not mx or not px or not scale then return end
            px = px / scale; py = py / scale
            VoidRaidToolsCharDB = VoidRaidToolsCharDB or {}
            VoidRaidToolsCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionButton(self)
        end
    end)

    PositionButton(btn)
    return btn
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    CreateMinimapButton()
    VoidRaidToolsCharDB = VoidRaidToolsCharDB or {}
    if btn and VoidRaidToolsCharDB.minimapHidden then btn:Hide() end
end)
