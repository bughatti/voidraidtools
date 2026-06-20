----------------------------------------------------------------------
-- VoidRaidTools — Class Sequences (per-class, per-encounter macro popups)
--
-- For specific encounter+class+spec combos, ships a SecureActionButton
-- with a castsequence macrotext that progresses through a multi-step
-- play (e.g. Grip Grip Kick on Chimaerus Haunting Essence for DK).
--
-- The popup uses the same dynamic-keybind-override pattern as the
-- TAUNT popups, but with its own binding name VOIDRAIDTOOLS_SEQUENCE
-- so it can coexist with TAUNT (you might be tanking + needing to grip
-- in the same fight).
--
-- Smart targeting via PreClick:
--   SecureActionButtons fire PreClick BEFORE the secure cast. PreClick
--   can call TargetUnit on a nameplate unit (allowed for player-
--   initiated targeting in combat). So we can auto-pick the right
--   essence on each click without the user tab-targeting.
--
-- Sequence position tracking:
--   /castsequence is opaque to Lua — we can't read its position. So we
--   track our OWN click counter, reset on combat end / 15s of click
--   inactivity. Used to switch targeting strategy between grip-clicks
--   (1-2) and interrupt-click (3).
----------------------------------------------------------------------

local M = {
    state = {
        active_config       = nil,    -- which config is currently armed
        click_count         = 0,
        last_click_time     = 0,
        gripped_guids       = {},     -- GUIDs we've targeted for grip already this wave
        my_class            = nil,    -- "DEATHKNIGHT", etc.
    },
}

M.id          = "classsequences"
M.name        = "Class Sequences"
M.description = "Death Knight only — Grip / Grip / Kick castsequence popup for Chimaerus Haunting Essences. One keybind launches the 3-step sequence and auto-targets the next un-gripped add each press. DBM announces the cast; this DOES it."

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local CLICK_RESET_SECONDS = 15

----------------------------------------------------------------------
-- Per-encounter+class config registry. Each entry:
--   encounter_id  — 3182 (Chimaerus), etc.
--   class         — "DEATHKNIGHT"
--   spec          — nil (any spec) or { "Unholy", "Frost" }
--   label         — display text on the popup
--   macrotext     — castsequence macro
--   target_keywords — name-substrings to scan nameplates for (any match)
--   interrupt_step — which click index uses interrupt targeting (vs grip)
--   color         — hex RGB for the popup title
----------------------------------------------------------------------
local SEQUENCE_CONFIGS = {
    {
        encounter_id    = 3306,         -- Chimaerus, the Undreamt God (Dreamrift)
                                        -- Confirmed via voidscout-data/mechanics_lib.py:361
                                        -- and chimaerus_mythic.json. Previous value 3182
                                        -- was Belo'ren (Child of Al'ar, MQD) — that bug
                                        -- caused the Grip/Grip/Kick popup to incorrectly
                                        -- arm during the Belo'ren fight.
        encounter_name  = "Chimaerus",
        class           = "DEATHKNIGHT",
        spec            = nil,          -- any spec — all DKs have Death Grip + Mind Freeze
        label           = "GRIP / GRIP / KICK",
        sub_label       = "Haunting Essences",
        -- castsequence advances only on a successful cast. If Death Grip
        -- is on CD when the user clicks, sequence position does NOT
        -- advance — they can re-click when it's ready.
        macrotext       = "/castsequence reset=combat/15 Death Grip, Death Grip, Mind Freeze",
        target_keywords = { "Haunting Essence", "Essence", "Wraith" },
        interrupt_step  = 3,            -- click 3 = Mind Freeze
        color           = "9966cc",
    },
}

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT:ModuleSettings(M.id).debug) then return end
    VRT:Print(("[Sequences] " .. fmt):format(...))
end

local function MyClass()
    if not UnitClass then return nil end
    local _, cls = UnitClass("player")
    return cls
end

local function MySpec()
    if not GetSpecialization then return nil end
    local spec = GetSpecialization()
    if not spec then return nil end
    local _, name = GetSpecializationInfo(spec)
    return name
end

local function SpecMatches(cfg)
    if not cfg.spec then return true end  -- nil spec = any
    local mine = MySpec()
    for _, s in ipairs(cfg.spec) do
        if s == mine then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Nameplate scanning (PreClick targeting)
----------------------------------------------------------------------
local function NameplateMatchesKeywords(name, keywords)
    if not name then return false end
    for _, kw in ipairs(keywords) do
        if name:find(kw, 1, true) then return true end
    end
    return false
end

-- 12.0.5: UnitName/UnitGUID on hostile nameplates in instances can be
-- secret-tainted, and the taint propagates into the addon scope as soon
-- as a tainted value flows into a comparison or table key. Since this
-- function is called from inside a SecureActionButton's PreClick handler,
-- ANY taint here breaks every secure button in the addon. Guard each
-- field with issecretvalue BEFORE touching it.
local function SafeNameplateFields(unit)
    local name = UnitName(unit)
    if issecretvalue and issecretvalue(name) then name = nil end
    if not name then return nil, nil end
    local guid = UnitGUID(unit)
    if issecretvalue and issecretvalue(guid) then guid = nil end
    return name, guid
end

local function FindGripTarget(cfg)
    -- Pick the first nameplate matching keywords whose GUID is not yet
    -- in gripped_guids. This rotates through fresh essences.
    if not (UnitExists and UnitName and UnitGUID and UnitCanAttack) then return nil end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            local name, guid = SafeNameplateFields(unit)
            if name and NameplateMatchesKeywords(name, cfg.target_keywords) then
                if guid and not M.state.gripped_guids[guid] then
                    return unit, guid, name
                end
            end
        end
    end
    -- Fallback: first matching nameplate even if previously targeted
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            local name, guid = SafeNameplateFields(unit)
            if name and NameplateMatchesKeywords(name, cfg.target_keywords) then
                return unit, guid, name
            end
        end
    end
    return nil
end

----------------------------------------------------------------------
-- The popup (one shared frame, retargets via PreClick per config)
----------------------------------------------------------------------
local popup_frame
local secure_button

local function ResetClickState()
    M.state.click_count = 0
    M.state.last_click_time = 0
    M.state.gripped_guids = {}
end

local function PreClickHandler(self)
    local cfg = M.state.active_config
    if not cfg then return end

    -- Reset click counter if it's been > 15s since last click
    local now = GetTime()
    if now - M.state.last_click_time > CLICK_RESET_SECONDS then
        ResetClickState()
    end
    M.state.click_count = M.state.click_count + 1
    M.state.last_click_time = now

    -- For all clicks: target the next un-gripped matching nameplate.
    -- For the interrupt step (click 3), targeting a "casting" mob would
    -- be ideal — but UnitCastingInfo on hostile nameplates is secret-
    -- tainted in 12.0.5 and reading it inside a SecureActionButton
    -- PreClick handler propagates taint that breaks every secure button
    -- in the addon. The fallback is good enough: any matching nameplate
    -- is targeted, the secure /castsequence fires Mind Freeze on it. If
    -- the player wants a specific caster, they tab-target before the
    -- click — that overrides our PreClick targeting cleanly.
    local target_unit, target_guid, target_name = FindGripTarget(cfg)

    if target_unit then
        TargetUnit(target_unit)
        if target_guid and M.state.click_count < cfg.interrupt_step then
            M.state.gripped_guids[target_guid] = true
        end
    end
end

local function BuildSequencePopup()
    if popup_frame then return end
    if InCombatLockdown() then return end

    local f = CreateFrame("Frame", "VRT_SequencePopup", UIParent, "BackdropTemplate")
    f:SetSize(260, 90)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.55)
    f:SetBackdropBorderColor(0.6, 0.4, 0.85, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetTextColor(1, 1, 1)
    f.title = title

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetTextColor(0.7, 0.7, 0.75)
    f.sub = sub

    -- Secure action button — sits inside the frame
    local btn = CreateFrame("Button", "VRT_SequenceButton", f, "SecureActionButtonTemplate")
    btn:SetSize(220, 32)
    btn:SetPoint("BOTTOM", 0, 10)
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetAttribute("type", "macro")
    -- macrotext will be set per-config on ARM

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.15, 0.08, 0.20, 0.85)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    lbl:SetPoint("CENTER")
    lbl:SetTextColor(1, 0.85, 0.2)
    lbl:SetText("CLICK")
    btn.lbl = lbl

    btn:HookScript("PreClick", PreClickHandler)

    secure_button = btn
    f.button = btn

    f:Hide()
    popup_frame = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "classsequences.popup",
            frame = f,
            label = "Sequence Popup",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = 80 },
        })
    end

    -- Register with the SEQUENCE keybind registry (separate from TAUNT)
    if VRT and VRT.RegisterSequencePopup then
        VRT:RegisterSequencePopup(btn)
    end
end

----------------------------------------------------------------------
-- Arm / disarm
----------------------------------------------------------------------
local function FindMatchingConfig(encounterID)
    local cls = MyClass()
    if not cls then return nil end
    for _, cfg in ipairs(SEQUENCE_CONFIGS) do
        if cfg.encounter_id == encounterID and cfg.class == cls and SpecMatches(cfg) then
            return cfg
        end
    end
    return nil
end

local function ArmConfig(cfg)
    if not popup_frame then BuildSequencePopup() end
    if not popup_frame then return end  -- combat lockdown blocked build
    if InCombatLockdown() then return end  -- can't SetAttribute in combat

    M.state.active_config = cfg
    ResetClickState()

    secure_button:SetAttribute("macrotext", cfg.macrotext)
    popup_frame.title:SetText(("|cff%s%s|r"):format(cfg.color, cfg.label))
    popup_frame.sub:SetText(cfg.sub_label or cfg.encounter_name or "")
    secure_button.lbl:SetText(cfg.label)
    popup_frame:Show()
end

local function DisarmConfig()
    M.state.active_config = nil
    ResetClickState()
    if popup_frame then popup_frame:Hide() end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    self.state.my_class = MyClass()
    BuildSequencePopup()
    dbg("init class=%s", tostring(self.state.my_class))
end

function M:OnEncounterStart(encounterID)
    local cfg = FindMatchingConfig(encounterID)
    if not cfg then return end
    ArmConfig(cfg)
    VRT:Print(("Sequence armed: %s (%s) — bind VOIDRAIDTOOLS_SEQUENCE in Key Bindings."):format(
        cfg.label, cfg.encounter_name))
end

function M:OnEncounterEnd(encounterID)
    if M.state.active_config and M.state.active_config.encounter_id == encounterID then
        DisarmConfig()
    end
end

----------------------------------------------------------------------
-- Panel actions
----------------------------------------------------------------------
M.actions = {
    { label = "Show Test Popup (Chim DK)", action = function()
        if not popup_frame then BuildSequencePopup() end
        if popup_frame then
            local test_cfg = SEQUENCE_CONFIGS[1]
            ArmConfig(test_cfg)
            VRT:Print("Test sequence popup shown. Bind VOIDRAIDTOOLS_SEQUENCE in Key Bindings to test the key.")
        end
    end },
    { label = "Hide Sequence Popup", action = function()
        DisarmConfig()
    end },
    { label = "Toggle Debug", action = function()
        local s = VRT:ModuleSettings(M.id)
        s.debug = not s.debug
        VRT:Print("ClassSequences debug: " .. (s.debug and "ON" or "OFF"))
    end },
}

----------------------------------------------------------------------
-- Register
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
