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
-- USAGE: /focus a hostile mob. The bar shows when they cast. If their
-- cast is non-interruptible (uninterruptible boss casts, etc.) the bar
-- becomes fully transparent automatically. Interruptible casts show
-- bright green and stay visible — that's your kick window.
--
-- NO instance gating. Works in follower dungeons, M+ keys, raids,
-- open world, scenarios — anywhere you have a hostile focus.
----------------------------------------------------------------------

local M = {
    id   = "focuskickbar",
    name = "Focus Kick Bar",
    description = "Shows focus target's cast — auto-hides non-interruptible casts.",
    state = {
        active_cast_kind = nil,  -- "cast" | "channel" | nil
        start_gt         = nil,  -- GetTime() at cast start
    },
}

local bar  -- the cast bar frame

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------
local function BuildBar()
    if bar then return bar end

    local f = CreateFrame("Frame", "VRT_FocusKickBar", UIParent, "BackdropTemplate")
    f:SetSize(220, 28)
    f:SetPoint("CENTER", 0, -120)
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

    -- Actual status bar inside the backdrop frame.
    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", 2, -2)
    sb:SetPoint("BOTTOMRIGHT", -2, 2)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    f.sb = sb

    local tex = sb:GetStatusBarTexture()
    f.tex = tex

    -- Text label centered on the bar.
    local txt = sb:CreateFontString(nil, "OVERLAY")
    txt:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    txt:SetPoint("CENTER", 0, 0)
    txt:SetText("")
    f.txt = txt

    -- Subtle border-color animation via flash when an interruptible cast
    -- starts. Catches the eye without being obnoxious.
    -- (Optional: skip if visual is too busy in practice.)

    f:Hide()
    bar = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "focuskickbar.bar",
            frame = f,
            label = "Focus Kick Bar",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = -120 },
        })
    end
    return f
end

----------------------------------------------------------------------
-- Visual update — THE CRITICAL PATH
--
-- All consumption of the secret `notInt` value happens via the C-side
-- methods. NEVER `if notInt then`, `== true`, `not`, etc. Doing so
-- would taint VRT's execution chain and break its SecureActionButtons.
----------------------------------------------------------------------
local INTERRUPTIBLE_BG    = CreateColor(0.05, 0.6, 0.15, 1.0)
local NON_INTERRUPTIBLE_BG = CreateColor(0.4, 0.4, 0.4, 1.0)

local function ShowCastBar(notInt, cast_kind)
    if not bar then return end
    -- Hide non-interruptible casts entirely (alpha 0). Show
    -- interruptible casts at full alpha. Engine resolves the secret bool.
    bar:SetAlphaFromBoolean(notInt, 0, 1)
    -- Color the fill: gray if non-int, vivid green if int. Even though
    -- we hide non-int via alpha, set the color too so if a user disables
    -- the hide-on-non-int via setting, the gray still clearly says "skip".
    bar.tex:SetVertexColorFromBoolean(notInt, NON_INTERRUPTIBLE_BG, INTERRUPTIBLE_BG)
    -- Border color: bright orange for kickable, dim for non-kickable.
    -- We can't use the FromBoolean method for backdrop border, so leave
    -- the border at a neutral color. The fill + alpha is the discriminator.
    bar.txt:SetText(cast_kind == "channel" and "CHANNEL" or "CASTING")
    bar:Show()
end

local function HideCastBar()
    if not bar then return end
    bar:Hide()
end

----------------------------------------------------------------------
-- Focus cast detection
----------------------------------------------------------------------
local function PollFocusCast()
    if not UnitExists("focus") then HideCastBar(); return end
    if not UnitCanAttack("player", "focus") then HideCastBar(); return end

    -- Read UnitCastingInfo. The notInt field is SECRET-tainted. We
    -- assign it to a local but NEVER branch on it.
    local name, _, _, _, _, _, _, notInt = UnitCastingInfo("focus")
    if name then
        ShowCastBar(notInt, "cast")
        M.state.active_cast_kind = "cast"
        M.state.start_gt = GetTime()
        return
    end
    -- Not casting — try channel
    local cName, _, _, _, _, _, cNotInt = UnitChannelInfo("focus")
    if cName then
        ShowCastBar(cNotInt, "channel")
        M.state.active_cast_kind = "channel"
        M.state.start_gt = GetTime()
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
    if event == "PLAYER_FOCUS_CHANGED" then
        PollFocusCast()
        return
    end
    -- All UNIT_SPELLCAST_* events only matter when their unit is "focus".
    if unit ~= "focus" then return end
    if event == "UNIT_SPELLCAST_START"
       or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_INTERRUPTIBLE"
       or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        PollFocusCast()
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
    -- Register UNIT_SPELLCAST events. RegisterUnitEvent("focus") would
    -- be cleaner but is capped at 8 units — we'd waste 7 slots. Plain
    -- RegisterEvent + filter-by-unit in handler is fine; focus events
    -- are low volume.
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
    -- Initial poll in case focus was already set before login.
    PollFocusCast()
end

function M:OnUnitAura(unit) end -- noop, kept for Core dispatch compat

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
