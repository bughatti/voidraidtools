----------------------------------------------------------------------
-- VoidRaidTools — Master Panel + Minimap Icon
--
-- Replaces typed slash commands as the primary UX. Everything is a
-- button: enable/disable per module, open setup UI, fire test popups,
-- simulate encounters, toggle Edit Mode, reset frame positions.
--
-- Modules declare their action set in `M.actions`:
--   M.actions = {
--     { label = "Open Setup",      action = function() M:OpenSetup() end },
--     { label = "Test Popup",      action = function() M:TestPopup() end },
--     { label = "Sim Heroic",      action = function() M:SimHeroic() end },
--   }
-- Panel walks the registry, builds a row per module with these buttons.
--
-- Minimap icon (standardized 28x28 +6-radius spec per
-- [[void-addons-architecture]]): left-click toggles panel, right-click
-- toggles Edit Mode.
----------------------------------------------------------------------

local ADDON_NAME, ns = ...

VRT = VRT or {}

----------------------------------------------------------------------
-- Module action registry
--
-- Modules can either declare M.actions = { ... } as a static field, or
-- register dynamically via VRT:RegisterModuleAction(module_id, spec).
----------------------------------------------------------------------
function VRT:RegisterModuleAction(module_id, spec)
    local mod = self:GetModule(module_id)
    if not mod then return end
    mod.actions = mod.actions or {}
    table.insert(mod.actions, spec)
end

----------------------------------------------------------------------
-- Master panel frame
----------------------------------------------------------------------
local panel
local module_rows = {}   -- module_id → frame

local PANEL_WIDTH       = 460
local ROW_HEIGHT_BASE   = 36     -- header line of each module row
local ACTION_BUTTON_H   = 22
local ACTION_BUTTON_PAD = 6

local function CreatePanelFrame()
    if panel then return panel end

    panel = CreateFrame("Frame", "VRT_MasterPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 540)
    panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    panel:SetFrameStrata("HIGH")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    panel:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
    panel:SetBackdropBorderColor(0, 0.78, 1, 1)

    -- Title bar
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00c7ffVoidRaidTools|r")
    panel.title = title

    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetTextColor(0.55, 0.55, 0.65)
    subtitle:SetText("v" .. (VRT.version or "?") .. "  |  click a module action to invoke")
    panel.subtitle = subtitle

    -- Close button
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- Scrollable module list
    local scroll = CreateFrame("ScrollFrame", "VRT_PanelScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -52)
    scroll:SetPoint("BOTTOMRIGHT", -32, 68)
    panel.scroll = scroll

    local content = CreateFrame("Frame", "VRT_PanelContent", scroll)
    content:SetSize(PANEL_WIDTH - 50, 1)
    scroll:SetScrollChild(content)
    panel.content = content

    -- Bottom bar — Edit Mode + Reset Positions + bulk enable/disable
    local editBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    editBtn:SetSize(110, 26)
    editBtn:SetPoint("BOTTOMLEFT", 14, 14)
    editBtn:SetText("Edit Mode")
    editBtn:SetScript("OnClick", function() VRT:ToggleEditMode() end)
    panel.editBtn = editBtn

    local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(130, 26)
    resetBtn:SetPoint("LEFT", editBtn, "RIGHT", 6, 0)
    resetBtn:SetText("Reset Positions")
    resetBtn:SetScript("OnClick", function() VRT:ResetAllPositions() end)
    panel.resetBtn = resetBtn

    -- Bulk-toggle buttons: requested by users who want to start clean
    -- and re-enable only the modules they want (e.g. a tank who wants
    -- ONLY LuraMemory + tank-swap modules, ignoring kick/dispel alerts).
    local enableAllBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    enableAllBtn:SetSize(90, 26)
    enableAllBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    enableAllBtn:SetText("Enable All")
    enableAllBtn:SetScript("OnClick", function()
        for _, mod in pairs(VRT.modules or {}) do
            VRT:SetModuleEnabled(mod.id, true)
        end
        VRT:Print("All modules enabled. Open the panel again to verify.")
        VRT:RefreshPanel()
    end)
    panel.enableAllBtn = enableAllBtn

    local disableAllBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    disableAllBtn:SetSize(95, 26)
    disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 4, 0)
    disableAllBtn:SetText("Disable All")
    disableAllBtn:SetScript("OnClick", function()
        for _, mod in pairs(VRT.modules or {}) do
            VRT:SetModuleEnabled(mod.id, false)
        end
        VRT:Print("All modules disabled. Re-enable the ones you want from this panel.")
        VRT:RefreshPanel()
    end)
    panel.disableAllBtn = disableAllBtn

    -- Slash hint (small, gray, not the primary path)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMRIGHT", -16, 18)
    hint:SetTextColor(0.4, 0.4, 0.45)
    hint:SetText("(/vrt panel also opens this)")
    panel.hint = hint

    panel:Hide()

    -- Save position via Core's movable registry
    if VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "vrt.masterpanel",
            frame = panel,
            label = "VRT Master Panel",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
        })
    end

    return panel
end

----------------------------------------------------------------------
-- Per-module row rendering
----------------------------------------------------------------------
local function BuildModuleRow(content, mod, y_cursor)
    local row = CreateFrame("Frame", nil, content)
    row:SetWidth(PANEL_WIDTH - 60)

    -- Enable toggle (checkbox)
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 0, 0)
    cb:SetChecked(VRT:IsModuleEnabled(mod.id))
    cb:SetScript("OnClick", function(self)
        VRT:SetModuleEnabled(mod.id, self:GetChecked() and true or false)
    end)
    cb.tooltipText = "Enable / Disable this module"

    -- Module name
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    name:SetTextColor(1, 0.85, 0.2)
    name:SetText(mod.name or mod.id)

    -- Encounter context (optional)
    if mod.encounter_name then
        local enc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        enc:SetPoint("LEFT", name, "RIGHT", 6, 0)
        enc:SetTextColor(0.55, 0.55, 0.65)
        enc:SetText("(" .. mod.encounter_name .. ")")
    end

    -- Description (below name)
    local desc
    if mod.description then
        desc = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 4, -2)
        desc:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        desc:SetTextColor(0.7, 0.7, 0.75)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        desc:SetText(mod.description)
    end

    -- Action buttons row (below description)
    local actions = mod.actions or {}
    local prev_anchor = desc or cb
    local prev_anchor_point = desc and "BOTTOMLEFT" or "BOTTOMLEFT"
    local btn_y_offset = desc and -6 or -4
    local btn_x = 4
    local btn_y = btn_y_offset
    local row_count = 0
    local btns = {}

    if #actions == 0 then
        -- No actions: small gray "no actions" notice
        local empty = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", prev_anchor, prev_anchor_point, 4, btn_y_offset)
        empty:SetTextColor(0.5, 0.5, 0.55)
        empty:SetText("(no actions exposed)")
        row_count = 1
    else
        local cursor_x = btn_x
        local cursor_y = btn_y
        local row_h = ACTION_BUTTON_H + 4
        for _, spec in ipairs(actions) do
            local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            local label = spec.label or "?"
            local w = math.max(70, label:len() * 6.5 + 14)
            b:SetSize(w, ACTION_BUTTON_H)
            if cursor_x + w > PANEL_WIDTH - 80 then
                cursor_x = btn_x
                cursor_y = cursor_y - row_h
                row_count = row_count + 1
            end
            b:SetPoint("TOPLEFT", prev_anchor, prev_anchor_point, cursor_x, cursor_y)
            b:SetText(label)
            b:SetScript("OnClick", function()
                if spec.action then pcall(spec.action) end
            end)
            cursor_x = cursor_x + w + ACTION_BUTTON_PAD
            table.insert(btns, b)
        end
        row_count = row_count + 1
    end

    -- Compute row height.
    --
    -- The naive GetStringHeight() approach didn't work because the
    -- FontString hasn't been rendered yet at this point (the row isn't
    -- anchored to content until below), so the value comes back as either
    -- 0 or the single-line height. Instead estimate wrap lines from the
    -- string length divided by chars-per-line at the row's wrap width.
    -- GameFontNormalSmall renders ~7.5px wide per char on average and the
    -- row is PANEL_WIDTH - 60 wide minus the checkbox indent (~22 + 4) =
    -- effective text width ~414px → ~55 chars per line. Conservative.
    local row_h = ROW_HEIGHT_BASE
    if desc then
        local CHARS_PER_LINE = 55
        local LINE_HEIGHT    = 12
        local nlines = math.ceil(#mod.description / CHARS_PER_LINE)
        if nlines < 1 then nlines = 1 end
        row_h = row_h + (nlines * LINE_HEIGHT) + 6
    end
    row_h = row_h + (row_count * (ACTION_BUTTON_H + 4))
    row:SetHeight(row_h)
    row:SetPoint("TOPLEFT", 0, y_cursor)
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

    -- Separator line below
    local sep = row:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.2, 0.2, 0.25, 0.6)
    sep:SetPoint("BOTTOMLEFT", 0, -2)
    sep:SetPoint("BOTTOMRIGHT", 0, -2)
    sep:SetHeight(1)

    return row, row_h + 6
end

local function RefreshPanel()
    if not panel or not panel.content then return end
    for _, r in pairs(module_rows) do
        r:Hide()
        r:SetParent(nil)
    end
    module_rows = {}

    local y = -6
    local total_height = 12
    local ordered = {}
    if VRT and VRT.modules then
        for _, mod in pairs(VRT.modules) do
            table.insert(ordered, mod)
        end
    end
    table.sort(ordered, function(a, b)
        return (a.name or a.id) < (b.name or b.id)
    end)
    for _, mod in ipairs(ordered) do
        local r, used = BuildModuleRow(panel.content, mod, y)
        module_rows[mod.id] = r
        y = y - used
        total_height = total_height + used
    end
    panel.content:SetHeight(math.max(total_height, 1))
end

function VRT:OpenPanel()
    if not panel then CreatePanelFrame() end
    RefreshPanel()
    panel:Show()
end

function VRT:ClosePanel() if panel then panel:Hide() end end

-- Public refresh — used by bulk Enable All / Disable All so the panel's
-- checkbox row state catches up to the new persistent flag immediately.
function VRT:RefreshPanel()
    if not panel then return end
    RefreshPanel()
end
function VRT:TogglePanel()
    if panel and panel:IsShown() then panel:Hide()
    else self:OpenPanel() end
end

----------------------------------------------------------------------
-- Minimap icon — moved to Minimap.lua, which creates
-- VoidRaidToolsMinimapBtn (the name VoidHubBundle discovers). The old
-- VRT_MinimapButton this file used to create lived outside the hub
-- cluster, causing a duplicate icon. No-op stub kept so the boot block
-- below can keep calling CreateMinimapButton without crashing.
----------------------------------------------------------------------
local function CreateMinimapButton() end

----------------------------------------------------------------------
-- Slash + boot
----------------------------------------------------------------------
local function HandlePanelSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if msg == "" or msg == "show" or msg == "open" or msg == "panel" then
        VRT:TogglePanel()
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    -- Wait one frame after PLAYER_LOGIN so modules' OnInit (which can
    -- declare M.actions) has already fired via Core's dispatch.
    C_Timer.After(0.1, function()
        CreateMinimapButton()
        _G.SLASH_VRTPANEL1 = "/vrtpanel"
        _G.SLASH_VRTPANEL2 = "/vrtp"
        SlashCmdList.VRTPANEL = HandlePanelSlash
    end)
end)
