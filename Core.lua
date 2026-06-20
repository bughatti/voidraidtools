----------------------------------------------------------------------
-- VoidRaidTools — Core
--
-- A skeleton + dispatcher. Knows nothing about specific bosses. Each
-- boss mechanic is a self-contained module file in `Modules/`. Modules
-- register themselves at file-load time via `VRT:RegisterModule(spec)`.
-- Core handles:
--   - SavedVariables initialization
--   - WoW event registration + per-module dispatch
--   - Slash command routing (`/vrt`, `/voidraidtools`)
--   - Addon-to-addon message routing via INSTANCE_CHAT
--   - Per-module enable/disable state (so users can opt-out individually)
--
-- Module spec (all fields except id/encounter_id are optional):
--   {
--     id              = "lura",                       -- short stable identifier
--     name            = "L'ura Memory Game",          -- display name
--     encounter_id    = 3183,                         -- Blizz encounter ID
--     encounter_name  = "Midnight Falls",             -- for chat/help text
--     description     = "...",                        -- shown by /vrt list
--     OnInit          = function(self) end,           -- once at PLAYER_LOGIN
--     OnZoneChanged   = function(self) end,           -- PLAYER_ENTERING_WORLD + ZONE_CHANGED_NEW_AREA
--     OnEncounterStart= function(self, eid) end,      -- gated to my encounter_id
--     OnEncounterEnd  = function(self, eid) end,      -- gated to my encounter_id
--     OnUnitAura      = function(self, unit) end,     -- raw event; filter inside
--     OnAddonMessage  = function(self, kind, data, sender) end,  -- routed to me
--     OnSlash         = function(self, args) end,     -- `/vrt <id> <args>`
--   }
--
-- Addon-message protocol:
--   Prefix: "VRT"
--   Payload format: "<module_id>|<kind>|<data>"
--   Example: "lura|FLASH|triangle,star,square,diamond,circle"
----------------------------------------------------------------------

local ADDON_NAME   = ...
local ADDON_PREFIX = "VRT"
local SLASH_LONG   = "voidraidtools"

VRT = VRT or {}
VRT.version = "0.10.0"

----------------------------------------------------------------------
-- Module registry
----------------------------------------------------------------------
VRT.modules = VRT.modules or {}

function VRT:RegisterModule(spec)
    assert(type(spec) == "table", "VRT:RegisterModule expects a table")
    assert(type(spec.id) == "string", "module needs an id")
    self.modules[spec.id] = spec
end

function VRT:GetModule(id)
    return self.modules and self.modules[id] or nil
end

function VRT:ForEachModule(fn)
    for _, mod in pairs(self.modules or {}) do fn(mod) end
end

----------------------------------------------------------------------
-- Utility: chat print
----------------------------------------------------------------------
function VRT:Print(msg)
    print("|cff00c7ff[VRT]|r " .. tostring(msg))
end

----------------------------------------------------------------------
-- Addon message helpers (called by modules)
----------------------------------------------------------------------
function VRT:SendModuleMessage(module_id, kind, data, channel)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local payload = ("%s|%s|%s"):format(module_id, kind, data or "")
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, payload, channel or "INSTANCE_CHAT")
end

local function DispatchAddonMessage(prefix, payload, channel, sender)
    if prefix ~= ADDON_PREFIX or type(payload) ~= "string" then return end
    local mod_id, kind, data = payload:match("^([^|]+)|([^|]+)|(.*)$")
    if not mod_id then return end
    local mod = VRT:GetModule(mod_id)
    if not mod or not mod.OnAddonMessage then return end
    if VRT:IsModuleEnabled(mod_id) == false then return end
    pcall(mod.OnAddonMessage, mod, kind, data or "", sender or "")
end

----------------------------------------------------------------------
-- Per-module enable/disable (persisted)
----------------------------------------------------------------------
function VRT:IsModuleEnabled(id)
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.modules = VoidRaidToolsDB.modules or {}
    local v = VoidRaidToolsDB.modules[id]
    if v == nil then return true end  -- default on
    return v
end

function VRT:SetModuleEnabled(id, on)
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.modules = VoidRaidToolsDB.modules or {}
    local was_on = VoidRaidToolsDB.modules[id]
    if was_on == nil then was_on = true end  -- default on
    VoidRaidToolsDB.modules[id] = on and true or false
    if was_on == (on and true or false) then return end  -- no change

    -- Auto-hide every registered movable frame whose id matches this
    -- module's id (either exact, or as a `<mod_id>.<subid>` prefix).
    -- Modules register their draggable frames here so /vrt edit can find
    -- them; reusing the registry means we don't have to touch every
    -- module to wire up the toggle.
    local prefix = id .. "."
    for _, mv in ipairs(self.movables or {}) do
        if mv.id == id or (mv.id and mv.id:sub(1, #prefix) == prefix) then
            if mv.frame then
                if on then
                    -- Defer "should this be visible?" to the module — context
                    -- matters (in-instance check, user_hidden flag, etc.).
                    -- If the module didn't define OnEnable we just Show().
                    -- Modules that need conditional show implement OnEnable.
                else
                    mv.frame:Hide()
                end
            end
        end
    end

    -- Notify the module so it can run custom show/hide logic too.
    -- Modules opt in by defining OnDisable / OnEnable.
    --
    -- IMPORTANT: when ENABLING a module we do NOT auto-show its frames.
    -- Most module frames are popups that should only appear when a
    -- specific trigger fires (boss cast, debuff stack threshold, tank
    -- swap broadcast, etc.). The previous default of "show all movables
    -- on enable" turned the Enable All button into a screen full of
    -- popups even outside combat.
    --
    -- Modules that want a frame visible immediately on enable (e.g.
    -- KickRotation when you're in an instance) implement OnEnable
    -- themselves and decide their own show logic. Modules without an
    -- OnEnable stay silent until their normal trigger fires.
    local mod = self.modules and self.modules[id]
    if mod then
        if on and type(mod.OnEnable) == "function" then
            pcall(mod.OnEnable, mod)
        elseif not on and type(mod.OnDisable) == "function" then
            pcall(mod.OnDisable, mod)
        end
    end
end

----------------------------------------------------------------------
-- Saved settings helper for modules (each module gets its own table)
----------------------------------------------------------------------
function VRT:ModuleSettings(id)
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.settings = VoidRaidToolsDB.settings or {}
    VoidRaidToolsDB.settings[id] = VoidRaidToolsDB.settings[id] or {}
    return VoidRaidToolsDB.settings[id]
end

----------------------------------------------------------------------
-- Event dispatch
----------------------------------------------------------------------
local function DispatchEncounterStart(encounterID)
    VRT:ForEachModule(function(mod)
        if not VRT:IsModuleEnabled(mod.id) then return end
        if mod.encounter_id and mod.encounter_id ~= encounterID then return end
        if mod.OnEncounterStart then
            pcall(mod.OnEncounterStart, mod, encounterID)
        end
    end)
end

local function DispatchEncounterEnd(encounterID)
    VRT:ForEachModule(function(mod)
        if not VRT:IsModuleEnabled(mod.id) then return end
        if mod.encounter_id and mod.encounter_id ~= encounterID then return end
        if mod.OnEncounterEnd then
            pcall(mod.OnEncounterEnd, mod, encounterID)
        end
    end)
end

local function DispatchUnitAura(unit)
    VRT:ForEachModule(function(mod)
        if not VRT:IsModuleEnabled(mod.id) then return end
        if mod.OnUnitAura then
            pcall(mod.OnUnitAura, mod, unit)
        end
    end)
end

-- Blizzard's clean (un-tainted) encounter timeline event. Fires whenever
-- the boss queues an upcoming ability, with eventInfo containing duration
-- (NeverSecret) and spellID (possibly secret on encounter events). This is
-- THE official API for boss-timing data in 12.0.5 — used by DBM internally.
-- Modules implement OnTimelineEvent(self, eventInfo) to react.
local function DispatchTimelineEvent(eventInfo)
    VRT:ForEachModule(function(mod)
        if not VRT:IsModuleEnabled(mod.id) then return end
        if mod.OnTimelineEvent then
            pcall(mod.OnTimelineEvent, mod, eventInfo)
        end
    end)
end

----------------------------------------------------------------------
-- Edit Mode: drag-to-place every registered module frame at once
--
-- Modules call VRT:RegisterMovable(spec) after building any draggable
-- frame. /vrt edit then forces all such frames visible, paints a colored
-- drag overlay on each, and saves positions globally to
-- VoidRaidToolsDB.movables.
--
-- spec = {
--   id           = "lightblinded.assignment",  -- unique stable identifier
--   frame        = <frame object>,             -- the frame to move
--   label        = "Lightblinded — Assign",    -- shown on overlay during edit
--   default_point = {                          -- optional, for /vrt resetpos
--     point = "TOP", relPoint = "TOP", x = 0, y = -185,
--   },
-- }
----------------------------------------------------------------------
VRT.movables = VRT.movables or {}
local edit_mode_active = false
local edit_overlays    = {}   -- spec.id → overlay button
local edit_was_shown   = {}   -- spec.id → was the frame visible before edit?
local edit_panel              -- floating "Done" panel

local function SavePositionFor(spec)
    local point, _, relPoint, x, y = spec.frame:GetPoint()
    if not point then return end
    VoidRaidToolsDB.movables = VoidRaidToolsDB.movables or {}
    VoidRaidToolsDB.movables[spec.id] = {
        point = point, relPoint = relPoint, x = x, y = y,
    }
end

function VRT:RegisterMovable(spec)
    assert(type(spec) == "table" and type(spec.id) == "string"
           and type(spec.frame) == "table",
           "VRT:RegisterMovable requires {id, frame, label, ...}")
    table.insert(self.movables, spec)
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.movables = VoidRaidToolsDB.movables or {}
    local saved = VoidRaidToolsDB.movables[spec.id]
    if saved and saved.point then
        spec.frame:ClearAllPoints()
        spec.frame:SetPoint(saved.point, UIParent,
                            saved.relPoint or saved.point,
                            saved.x or 0, saved.y or 0)
    end
    spec.frame:SetMovable(true)

    -- For non-secure frames, attach native drag scripts so the user can
    -- reposition them any time without /vrt edit. SecureActionButton
    -- popups (spec.secure=true) skip this because LeftButton drag would
    -- eat the click that fires the taunt macro — those frames are
    -- movable only via /vrt edit overlay.
    if not spec.secure then
        spec.frame:EnableMouse(true)
        spec.frame:RegisterForDrag("LeftButton")
        spec.frame:SetScript("OnDragStart", function(self)
            if InCombatLockdown() then return end
            self:StartMoving()
        end)
        spec.frame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            SavePositionFor(spec)
        end)
    end
end

local function CreateEditOverlay(spec)
    local ov = CreateFrame("Button", nil, spec.frame, "BackdropTemplate")
    ov:SetAllPoints(spec.frame)
    ov:SetFrameStrata("FULLSCREEN_DIALOG")
    ov:EnableMouse(true)
    ov:RegisterForDrag("LeftButton")

    ov:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    ov:SetBackdropColor(1, 0.5, 0.1, 0.35)
    ov:SetBackdropBorderColor(1, 0.6, 0.1, 1)

    local label = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER")
    label:SetTextColor(1, 1, 1)
    label:SetText(spec.label or spec.id)

    ov:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        spec.frame:StartMoving()
    end)
    ov:SetScript("OnDragStop", function()
        spec.frame:StopMovingOrSizing()
        SavePositionFor(spec)
    end)
    return ov
end

local function BuildEditPanel()
    if edit_panel then return end
    local p = CreateFrame("Frame", "VRT_EditPanel", UIParent, "BackdropTemplate")
    p:SetSize(260, 96)
    p:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    p:SetBackdropColor(0, 0, 0, 0.85)
    p:SetBackdropBorderColor(1, 0.85, 0.2, 1)

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cffffd700VRT Edit Mode|r")

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -2)
    hint:SetTextColor(0.75, 0.75, 0.75)
    hint:SetText("Drag any orange box. This panel is also movable.")

    local done = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    done:SetSize(220, 24)
    done:SetPoint("BOTTOM", 0, 8)
    done:SetText("Done — Lock Positions")
    done:SetScript("OnClick", function() VRT:ExitEditMode() end)
    edit_panel = p
end

function VRT:EnterEditMode()
    if InCombatLockdown() then
        VRT:Print("Edit mode unavailable in combat. Try again out of combat.")
        return
    end
    if edit_mode_active then return end
    edit_mode_active = true
    BuildEditPanel()
    edit_panel:Show()
    for _, spec in ipairs(self.movables) do
        edit_was_shown[spec.id] = spec.frame:IsShown()
        spec.frame:Show()
        local ov = edit_overlays[spec.id]
        if not ov then
            ov = CreateEditOverlay(spec)
            edit_overlays[spec.id] = ov
        end
        ov:Show()
    end
    VRT:Print(("Edit Mode ON — %d frame(s) movable. Drag any orange box; click Done when finished."):format(#self.movables))
end

function VRT:ExitEditMode()
    if not edit_mode_active then return end
    if InCombatLockdown() then
        -- Can't hide secure frames in combat; defer exit.
        VRT:Print("Exit deferred — in combat. Will exit when combat ends.")
        return
    end
    edit_mode_active = false
    if edit_panel then edit_panel:Hide() end
    for _, spec in ipairs(self.movables) do
        local ov = edit_overlays[spec.id]
        if ov then ov:Hide() end
        if edit_was_shown[spec.id] == false then
            spec.frame:Hide()
        end
    end
    edit_was_shown = {}
    VRT:Print("Edit Mode OFF — positions saved.")
end

function VRT:ToggleEditMode()
    if edit_mode_active then self:ExitEditMode() else self:EnterEditMode() end
end

function VRT:ResetAllPositions()
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.movables = {}
    VRT:Print("All saved positions cleared. /reload to apply defaults.")
end

function VRT:IsEditMode() return edit_mode_active end

----------------------------------------------------------------------
-- Taunt-popup keybind registry
--
-- Each tank-swap module registers its TAUNT popup (a SecureActionButton)
-- via VRT:RegisterTauntPopup(button). When a popup becomes visible we
-- apply SetOverrideBindingClick so the user's bound VOIDRAIDTOOLS_TAUNT
-- key routes to that specific popup's secure macro. When the popup
-- hides we either rebind to another visible popup or clear the
-- override so the key falls back to its normal behavior (the user's
-- regular Taunt keybind on their action bar).
----------------------------------------------------------------------
_G.BINDING_HEADER_VOIDRAIDTOOLS_BINDING_HEADER = "VoidRaidTools"
_G.BINDING_NAME_VOIDRAIDTOOLS_TAUNT             = "TAUNT (any visible VRT popup)"
_G.BINDING_NAME_VOIDRAIDTOOLS_SEQUENCE          = "Sequence (visible Class Sequence popup)"

VRT.taunt_popups    = VRT.taunt_popups    or {}
VRT.sequence_popups = VRT.sequence_popups or {}
local taunt_owner    = CreateFrame("Frame", "VRT_TauntBindingOwner")
local sequence_owner = CreateFrame("Frame", "VRT_SequenceBindingOwner")

-- Generic override application. `owner` namespaces the override so
-- TAUNT and SEQUENCE keys can coexist without clobbering each other.
local function ApplyOverride(owner, binding_name, btn_name)
    local key1, key2 = GetBindingKey(binding_name)
    ClearOverrideBindings(owner)
    if not key1 or not btn_name then return end
    SetOverrideBindingClick(owner, true, key1, btn_name)
    if key2 then SetOverrideBindingClick(owner, true, key2, btn_name) end
end

local function RecheckList(list, owner, binding_name)
    for _, btn in ipairs(list) do
        if btn and btn:IsShown() then
            ApplyOverride(owner, binding_name, btn:GetName())
            return
        end
    end
    if not InCombatLockdown() then ClearOverrideBindings(owner) end
end

function VRT:RecheckTauntOverride()
    RecheckList(self.taunt_popups, taunt_owner, "VOIDRAIDTOOLS_TAUNT")
end

function VRT:RecheckSequenceOverride()
    RecheckList(self.sequence_popups, sequence_owner, "VOIDRAIDTOOLS_SEQUENCE")
end

function VRT:RegisterTauntPopup(button)
    if not button or not button.GetName or not button:GetName() then return end
    table.insert(self.taunt_popups, button)
    button:HookScript("OnShow", function(b) ApplyOverride(taunt_owner, "VOIDRAIDTOOLS_TAUNT", b:GetName()) end)
    button:HookScript("OnHide", function() VRT:RecheckTauntOverride() end)
end

function VRT:RegisterSequencePopup(button)
    if not button or not button.GetName or not button:GetName() then return end
    table.insert(self.sequence_popups, button)
    button:HookScript("OnShow", function(b) ApplyOverride(sequence_owner, "VOIDRAIDTOOLS_SEQUENCE", b:GetName()) end)
    button:HookScript("OnHide", function() VRT:RecheckSequenceOverride() end)
end

----------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------
local function PrintHelp()
    VRT:Print("Commands:")
    print("  |cffffd700/vrt list|r              — list installed modules")
    print("  |cffffd700/vrt edit|r              — toggle Edit Mode (drag-to-place all frames)")
    print("  |cffffd700/vrt resetpos|r          — clear all saved frame positions")
    print("  |cffffd700/vrt <id> <args>|r       — pass args to a module (e.g. /vrt lura test)")
    print("  |cffffd700/vrt enable <id>|r       — enable a module")
    print("  |cffffd700/vrt disable <id>|r      — disable a module")
end

local function PrintModuleList()
    VRT:Print("Installed modules:")
    local any = false
    VRT:ForEachModule(function(mod)
        any = true
        local on = VRT:IsModuleEnabled(mod.id)
        local state = on and "|cff20ff20ON|r" or "|cffff5050OFF|r"
        local enc = mod.encounter_name and (" — " .. mod.encounter_name) or ""
        print(("  %s |cffffd700%s|r%s — %s"):format(
            state, mod.id, enc, mod.name or "(unnamed)"))
        if mod.description then
            print("        |cff8c8c9e" .. mod.description .. "|r")
        end
    end)
    if not any then print("  (none registered)") end
end

local function HandleSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = msg:lower()

    if msg == "" or lower == "help" then
        PrintHelp(); return
    end
    if lower == "list" or lower == "ls" then
        PrintModuleList(); return
    end
    if lower == "edit" or lower == "editmode" then
        VRT:ToggleEditMode(); return
    end
    if lower == "resetpos" or lower == "resetpositions" then
        VRT:ResetAllPositions(); return
    end
    if lower == "panel" or lower == "open" or lower == "show" then
        if VRT.TogglePanel then VRT:TogglePanel() end
        return
    end

    local first, rest = msg:match("^(%S+)%s*(.*)$")
    if not first then PrintHelp(); return end
    first = first:lower()

    if first == "enable" or first == "disable" then
        local id = rest:lower()
        if id == "" then VRT:Print("usage: /vrt " .. first .. " <module-id>"); return end
        local mod = VRT:GetModule(id)
        if not mod then VRT:Print("unknown module: " .. id); return end
        VRT:SetModuleEnabled(id, first == "enable")
        VRT:Print(("module |cffffd700%s|r is now %s"):format(
            id, first == "enable" and "|cff20ff20enabled|r" or "|cffff5050disabled|r"))
        return
    end

    -- Otherwise: route to module by id
    local mod = VRT:GetModule(first)
    if not mod then
        VRT:Print("unknown command or module: " .. first)
        PrintHelp(); return
    end
    if not VRT:IsModuleEnabled(first) then
        VRT:Print(("module |cffffd700%s|r is disabled — enable with /vrt enable %s"):format(first, first))
        return
    end
    if mod.OnSlash then
        pcall(mod.OnSlash, mod, rest)
    else
        VRT:Print(("module |cffffd700%s|r has no slash interface"):format(first))
    end
end

----------------------------------------------------------------------
-- Boot
----------------------------------------------------------------------
local frame = CreateFrame("Frame", "VoidRaidToolsEventFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED")

frame:SetScript("OnEvent", function(_, event, a, b, c, d, e)
    if event == "ADDON_LOADED" then
        if a ~= ADDON_NAME then return end
        VoidRaidToolsDB = VoidRaidToolsDB or {}
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        end
    elseif event == "PLAYER_LOGIN" then
        -- Slash command
        _G.SLASH_VRT1 = "/vrt"
        _G.SLASH_VRT2 = "/" .. SLASH_LONG
        SlashCmdList.VRT = HandleSlash
        -- Init each module
        VRT:ForEachModule(function(mod)
            if mod.OnInit then pcall(mod.OnInit, mod) end
        end)
        local count = 0
        for _ in pairs(VRT.modules) do count = count + 1 end
        VRT:Print(("v%s loaded — %d module%s. Type |cffffd700/vrt|r for commands."):format(
            VRT.version, count, count == 1 and "" or "s"))
        -- Reader is the required companion that captures cross-class data
        -- so the alert engine sees casts from other classes' perspective.
        -- Nudge the user once at login if it's missing.
        local hasReader = false
        if C_AddOns and C_AddOns.GetAddOnInfo then
            local _, _, _, loadable = C_AddOns.GetAddOnInfo("VoidRaidToolsReader")
            hasReader = loadable and true or false
        end
        if not hasReader then
            VRT:Print("|cffff8080REQUIRED COMPANION:|r install |cffffd700VoidRaidToolsReader|r alongside VRT — it captures cross-class boss data that the alert engine relies on.")
        end
    elseif event == "ENCOUNTER_START" then
        DispatchEncounterStart(a)
    elseif event == "ENCOUNTER_END" then
        DispatchEncounterEnd(a)
    elseif event == "UNIT_AURA" then
        DispatchUnitAura(a)
    elseif event == "CHAT_MSG_ADDON" then
        DispatchAddonMessage(a, b, c, d)
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        DispatchTimelineEvent(a)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        VRT:ForEachModule(function(mod)
            if not VRT:IsModuleEnabled(mod.id) then return end
            if mod.OnZoneChanged then pcall(mod.OnZoneChanged, mod) end
        end)
    end
end)
