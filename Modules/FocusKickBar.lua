----------------------------------------------------------------------
-- VoidRaidTools — Focus Kick Bar
--
-- A clean cast bar that mirrors your focus target's hostile cast.
-- Hides itself automatically when the cast is NON-interruptible, so you
-- never waste a kick / Mind Freeze on something you can't kick anyway.
--
-- THE TRICK (verified 2026-06-08 in EXWIND addon source):
--   `notInterruptible` from UnitCastingInfo is SECRET-tainted in 12.0.5
--   instances. Doing `if notInt then ... end` taints our addon's
--   execution chain and breaks VRT's secure buttons.
--
--   BUT — two Blizzard widget methods accept secret booleans and resolve
--   them in C-side engine code without ever exposing them to Lua:
--
--     region:SetAlphaFromBoolean(secretBool, alphaIfTrue, alphaIfFalse)
--     texture:SetVertexColorFromBoolean(secretBool, colorIfTrue, colorIfFalse)
--
--   We pass the raw secret value straight to these methods. The engine
--   reads it and applies the appropriate visual. Lua never branches on
--   the value, so taint never propagates. Confirmed working pattern from
--   EXWIND/ExwindTools (Chinese addon, 757K downloads).
--
-- See [[wow-12-c-side-boolean-widget-methods]] memory for the full
-- pattern + EXWIND source quotes.
--
-- 2026-10-06 rebuild: the bar now shows the spell name, icon and a filling
-- progress bar the way Plater's Midnight cast bar does (UnitCastingDuration +
-- SetTimerDuration; name/icon passed straight to SetText/SetTexture — never
-- read). It watches your FOCUS, or your TARGET when no hostile focus is set,
-- so it works for players who never use focus.
--
-- Non-interruptible casts still go fully transparent; interruptible casts
-- show bright green. NO instance gating.
----------------------------------------------------------------------

local M = {
    id   = "focuskickbar",
    name = "Focus Kick Bar",
    description = "A big cast bar for your focus (or your target if you have no focus): spell name, icon and time left, green when you can kick it, grey when you can't. Just your mob, never drowned out by raid-wide warnings.",
    state = {
        active_cast_kind = nil,  -- "cast" | "channel" | nil
        unit             = nil,  -- "focus" | "target" | nil
    },
}

local bar  -- the cast bar frame

local BAR_W, BAR_H = 280, 30

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------
local function BuildBar()
    if bar then return bar end

    local f = CreateFrame("Frame", "VRT_FocusKickBar", UIParent, "BackdropTemplate")
    f:SetSize(BAR_W, BAR_H)
    f:SetPoint("CENTER", 0, 160)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.02, 0.02, 0.04, 0.85)
    f:SetBackdropBorderColor(0.4, 0.5, 0.7, 0.9)

    -- Spell icon on the left.
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(BAR_H - 4, BAR_H - 4)
    icon:SetPoint("LEFT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    -- Status bar fills over the cast time.
    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", icon, "TOPRIGHT", 2, 0)
    sb:SetPoint("BOTTOMRIGHT", -2, 2)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    f.sb = sb
    f.tex = sb:GetStatusBarTexture()
    local sbg = sb:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints(); sbg:SetColorTexture(0.03, 0.03, 0.05, 0.9)

    -- Spell name (secret — passed straight to SetText).
    local txt = sb:CreateFontString(nil, "OVERLAY")
    txt:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    txt:SetPoint("LEFT", 6, 0)
    txt:SetPoint("RIGHT", -52, 0)
    txt:SetJustifyH("LEFT")
    txt:SetWordWrap(false)
    f.txt = txt

    -- Which unit we're watching.
    local who = sb:CreateFontString(nil, "OVERLAY")
    who:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    who:SetPoint("RIGHT", -6, 0)
    who:SetTextColor(0.75, 0.85, 1)
    f.who = who

    f:Hide()
    bar = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "focuskickbar.bar",
            frame = f,
            label = "Focus Kick Bar",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = 160 },
        })
    end
    return f
end

----------------------------------------------------------------------
-- Visual update — THE CRITICAL PATH
--
-- notInterruptible, the spell name/icon and the duration object are all
-- SECRET for non-player units. They are only handed to engine methods
-- (SetAlphaFromBoolean, SetVertexColorFromBoolean, SetText, SetTexture,
-- SetTimerDuration). NEVER `if notInt then`, `== true`, `not`, etc.
----------------------------------------------------------------------
local INTERRUPTIBLE_BG     = CreateColor(0.05, 0.6, 0.15, 1.0)
local NON_INTERRUPTIBLE_BG = CreateColor(0.4, 0.4, 0.4, 1.0)

local function ShowCastBar(unit, notInt, name, tex, dur, cast_kind)
    if not bar then return end
    -- Non-interruptible casts show GREY and dimmer (was: hidden) so you still see the
    -- big cast coming but know not to waste the kick (tested 2026-10-21). The engine
    -- resolves the secret flag.
    if notInt == nil then
        bar:SetAlpha(1)
        bar.tex:SetVertexColor(INTERRUPTIBLE_BG:GetRGBA())
    else
        bar:SetAlphaFromBoolean(notInt, 0.7, 1)
        bar.tex:SetVertexColorFromBoolean(notInt, NON_INTERRUPTIBLE_BG, INTERRUPTIBLE_BG)
    end
    bar.txt:SetText(name)
    bar.icon:SetTexture(tex)
    bar.who:SetText(unit == "focus" and "FOCUS" or "TARGET")
    local ok = false
    if dur and bar.sb.SetTimerDuration then
        ok = pcall(bar.sb.SetTimerDuration, bar.sb, dur, Enum.StatusBarInterpolation.Immediate,
            cast_kind == "channel" and Enum.StatusBarTimerDirection.RemainingTime
                                    or Enum.StatusBarTimerDirection.ElapsedTime)
    end
    if not ok then bar.sb:SetMinMaxValues(0, 1); bar.sb:SetValue(1) end
    bar:Show()
end

local function HideCastBar()
    if not bar then return end
    bar:Hide()
end

----------------------------------------------------------------------
-- Which unit to watch: a hostile focus wins, otherwise a hostile target.
----------------------------------------------------------------------
local function WatchedUnit()
    if UnitExists("focus") and UnitCanAttack("player", "focus") then return "focus" end
    if UnitExists("target") and UnitCanAttack("player", "target") then return "target" end
    return nil
end

local function PollCast()
    local unit = WatchedUnit()
    M.state.unit = unit
    if not unit then HideCastBar(); M.state.active_cast_kind = nil; return end

    local name, _, tex, _, _, _, _, notInt = UnitCastingInfo(unit)
    if name ~= nil then
        ShowCastBar(unit, notInt, name, tex, UnitCastingDuration and UnitCastingDuration(unit), "cast")
        M.state.active_cast_kind = "cast"
        return
    end
    local cName, _, cTex, _, _, _, cNotInt = UnitChannelInfo(unit)
    if cName ~= nil then
        ShowCastBar(unit, cNotInt, cName, cTex, UnitChannelDuration and UnitChannelDuration(unit), "channel")
        M.state.active_cast_kind = "channel"
        return
    end
    HideCastBar()
    M.state.active_cast_kind = nil
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local frame  -- event frame, lifecycle-scoped

local function OnEvent(_, event, unit)
    if event == "PLAYER_FOCUS_CHANGED" or event == "PLAYER_TARGET_CHANGED" then
        PollCast()
        return
    end
    -- UNIT_SPELLCAST_* only matter for the unit we're watching.
    if unit ~= "focus" and unit ~= "target" then return end
    if unit ~= WatchedUnit() then return end
    if event == "UNIT_SPELLCAST_START"
       or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_INTERRUPTIBLE"
       or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        PollCast()
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_FAILED" then
        HideCastBar()
        M.state.active_cast_kind = nil
    end
end

----------------------------------------------------------------------
-- Module lifecycle
----------------------------------------------------------------------
function M:OnInit()
    BuildBar()
    frame = CreateFrame("Frame", "VRT_FocusKickBarEventFrame")
    frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    for _, ev in ipairs({
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_STOP",  "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_SUCCEEDED",
        "UNIT_SPELLCAST_FAILED",
        "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    }) do
        frame:RegisterEvent(ev)
    end
    frame:SetScript("OnEvent", OnEvent)
    PollCast()
end

function M:OnDisable() HideCastBar() end
function M:OnUnitAura(unit) end -- noop, kept for Core dispatch compat

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
