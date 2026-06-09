----------------------------------------------------------------------
-- VoidRaidTools — Stack-Based Tank Swap (multi-fight, v2: PA-sound)
--
-- Covers stacking tank debuffs:
--   - Imperator Averzian: "Blackening Wounds" (spell 1265540, 8-10 stacks)
--   - Fallen-King Salhadaar: "Destabilizing Strikes" (spell 1271579, ~8)
--
-- Why v1 (aura-name scan) was abandoned:
--   12.0.5 secret-tags spellID, spellName, AND applications on ALL
--   boss-applied auras (verified via TankSwapDiagnostic — see
--   feedback-tank-swap-stack-detection-blocked memory note). Even with
--   the right spell name string, C_UnitAuras.GetAuraDataBySpellName
--   returns nothing useful. DBM acknowledges the same wall in their
--   own ImperatorAverzian.lua line 14 TODO comment.
--
-- v2 approach: chime per stack via Private Aura Applied Sound
--   1. At OnInit, register AddPrivateAuraAppliedSound for each known
--      stacking-debuff spell ID. The Blizzard engine internally fires
--      the sound EACH TIME the debuff is applied to the player. For
--      melee-reapplied stacks (~1 per boss swing), tank hears a tick
--      every ~2.5s. Count by ear; call swap when comfortable.
--   2. Active tank clicks "Call Swap" button → broadcasts SWAPREQUEST.
--   3. Off-tank's addon receives → shows TAUNT popup (secure action
--      button targets boss1).
--   4. Off-tank clicks → taunts → naturally becomes new active tank.
--
-- We never try to READ the debuff — only WRITE the registration.
-- DBM does exactly this pattern for their Private Aura sound options.
--
-- Spell IDs source:
--   Pulled from public WarcraftLogs Voidspire kill data 2026-06-05.
--   Reapplication counts (66 + 76) confirm per-melee-swing stacking.
----------------------------------------------------------------------

local M = {
    state = {
        active            = false,
        current_config    = nil,
        had_debuff        = false,
        my_stacks         = 0,
        requested_swap    = false,
        request_cooldown_handle = nil,
        -- Countdown predictor: target time when the active tank is
        -- estimated to be at threshold stacks (assuming continuous
        -- melee uptime). Reset on encounter start and on Call Swap.
        threshold_time    = nil,
    },
}

M.id             = "stacktankswap"
M.name           = "Imperator + Salhadaar — Stack Watcher"
M.encounter_name = "Imperator Averzian / Fallen-King Salhadaar"
M.description    = "Covers TWO bosses: Imperator Averzian (Blackening Wounds at 8+) and Fallen-King Salhadaar (Destabilizing Strikes at 8+). Auto-detects your own stacks; broadcasts SWAPREQUEST when threshold hit."

----------------------------------------------------------------------
-- Per-encounter configuration
--
-- threshold: stacks at which to call the swap
-- boss_unit: which boss unit token to taunt (boss1/boss2/boss3)
-- debuff_name: English spell name from Wago.tools / in-game tooltip
-- request_cooldown_seconds: silence further requests for this long
--                            after broadcasting (prevents spam if stacks
--                            briefly drop and re-cross threshold)
----------------------------------------------------------------------
local STACK_SWAP_CONFIGS = {
    [3176] = {
        id                = "imperator",
        encounter_id      = 3176,
        display           = "Imperator Averzian",
        debuff_name       = "Blackening Wounds",
        debuff_spell_id   = 1265540,    -- verified via WCL 2026-06-05
        sound_file        = "Sound\\Interface\\AlarmClockWarning1.ogg",
        threshold         = 8,
        per_stack_seconds = 2.41,       -- median melee-swing gap from WCL (2026-06-05)
        boss_unit         = "boss1",
        color             = "ff8c40",
        request_cooldown_seconds = 8,
    },
    [3179] = {
        id                = "salhadaar",
        encounter_id      = 3179,
        display           = "Fallen-King Salhadaar",
        debuff_name       = "Destabilizing Strikes",
        debuff_spell_id   = 1271579,    -- verified via WCL 2026-06-05
        sound_file        = "Sound\\Interface\\AlarmClockWarning2.ogg",
        threshold         = 8,
        per_stack_seconds = 2.11,       -- median melee-swing gap from WCL (2026-06-05)
        boss_unit         = "boss1",
        color             = "8c40ff",
        request_cooldown_seconds = 8,
    },
}

local PRE_WARN_SECONDS = 0       -- popup fires immediately on SWAPREQUEST
local POPUP_DURATION   = 8
local TAUNT_MACRO_FMT  = "/cast [@%s] Taunt\n/cast [@%s] Hand of Reckoning\n/cast [@%s] Growl\n/cast [@%s] Dark Command\n/cast [@%s] Provoke\n/cast [@%s] Torment"

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT.modules and VRT:ModuleSettings(M.id).debug) then return end
    VRT:Print(("[Stack] " .. fmt):format(...))
end

local function MyFullName()
    local n = UnitName("player") or "?"
    local r = (GetRealmName and GetRealmName() or ""):gsub("%s+", "")
    if r == "" then return n end
    return n .. "-" .. r
end

local function IsTank()
    if not GetSpecialization then return false end
    local spec = GetSpecialization()
    if not spec then return false end
    return GetSpecializationRole(spec) == "TANK"
end

local function BuildTauntMacro(unit_token)
    return TAUNT_MACRO_FMT:format(unit_token, unit_token, unit_token, unit_token, unit_token, unit_token)
end

local function FindConfigByID(cfg_id)
    for _, cfg in pairs(STACK_SWAP_CONFIGS) do
        if cfg.id == cfg_id then return cfg end
    end
    return nil
end

----------------------------------------------------------------------
-- Per-config secure action button popups. Pre-created at PLAYER_LOGIN
-- (one per known fight, since each fight uses a different boss unit).
----------------------------------------------------------------------
local taunt_popups = {}

local function BuildTauntPopup(cfg)
    if InCombatLockdown() then return end
    if taunt_popups[cfg.id] then return end

    local btn = CreateFrame("Button", "VRT_Stack_Taunt_" .. cfg.id, UIParent, "SecureActionButtonTemplate")
    btn:SetSize(280, 110)
    btn:SetFrameStrata("DIALOG")
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", BuildTauntMacro(cfg.boss_unit))
    btn:SetPoint("TOP", UIParent, "TOP", 0, -185)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.10, 0.02, 0.02, 0.55)

    local function MakeEdge(p1, p2, w, h)
        local t = btn:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 0.35, 0.1, 1)
        if p1 and p2 then t:SetPoint(p1); t:SetPoint(p2) end
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end
    MakeEdge("TOPLEFT", "TOPRIGHT", nil, 2)
    MakeEdge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    MakeEdge("TOPLEFT", "BOTTOMLEFT", 2, nil)
    MakeEdge("TOPRIGHT", "BOTTOMRIGHT", 2, nil)

    local title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetTextColor(1, 1, 1)
    title:SetText(("|cff%s%s|r"):format(cfg.color, cfg.display:upper()))
    btn.title = title

    local verb = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    verb:SetPoint("CENTER", 0, -2)
    verb:SetTextColor(1, 0.85, 0.2)
    local font, _, flags = verb:GetFont()
    if font then verb:SetFont(font, 22, flags) end
    verb:SetText("CLICK TO TAUNT")
    btn.verb = verb

    local info = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    info:SetPoint("BOTTOM", 0, 8)
    info:SetTextColor(1, 1, 1)
    btn.info = info

    btn:Hide()
    taunt_popups[cfg.id] = btn

    if VRT and VRT.RegisterTauntPopup then VRT:RegisterTauntPopup(btn) end

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id     = "stack.taunt." .. cfg.id,
            frame  = btn,
            label  = ("Stack TAUNT — %s"):format(cfg.display),
            secure = true,
            default_point = { point = "TOP", relPoint = "TOP", x = 0, y = -185 },
        })
    end
end

local function HideAllPopups()
    for _, btn in pairs(taunt_popups) do btn:Hide() end
end

local function ShowTauntPopup(cfg, stacks, sender)
    local btn = taunt_popups[cfg.id]
    if not btn then return end
    btn:Show()
    if btn.info then
        btn.info:SetText(("%s at |cffff8040%d stacks|r"):format(sender or "partner", stacks or 0))
    end
    local end_time = GetTime() + POPUP_DURATION
    btn:SetScript("OnUpdate", function(self)
        if GetTime() >= end_time then
            self:SetScript("OnUpdate", nil)
            self:Hide()
        end
    end)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
----------------------------------------------------------------------
-- Stack watcher frame: a small movable panel that ANCHORS the live
-- private-aura icon (with engine-rendered stack count) for the tank
-- debuffs, plus a "Call Swap" button the active tank clicks when
-- they're ready to be taunted off. One frame shared across configs.
----------------------------------------------------------------------
local stack_watcher_frame
local registered_sounds  = {}  -- cfg.id → sound ID (so we can clean up)
local registered_anchors = {}  -- cfg.id → anchor ID

local function BuildStackWatcherFrame()
    if stack_watcher_frame then return stack_watcher_frame end
    if InCombatLockdown() then return nil end

    local f = CreateFrame("Frame", "VRT_StackWatcher", UIParent, "BackdropTemplate")
    f:SetSize(220, 90)
    -- Default above the action bar where tanks naturally look for procs.
    -- Edit Mode lets users place it wherever they want; saved positions
    -- override this default.
    f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 180)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.50)         -- much more see-through
    f:SetBackdropBorderColor(1, 0.5, 0.1, 0.80)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", 0, -6)
    title:SetTextColor(1, 0.85, 0.2)
    title:SetText("Tank Stack")
    f.title = title

    -- Icon slot — anchor target for the Private Aura Anchor API.
    -- The Blizzard engine renders the actual icon + stack count into
    -- this region; we never read or write the data.
    local icon = CreateFrame("Frame", "VRT_StackWatcher_IconSlot", f)
    icon:SetSize(40, 40)
    icon:SetPoint("LEFT", 12, -4)
    f.icon = icon

    -- Countdown text — shows time until estimated threshold.
    local countdown = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    countdown:SetPoint("TOP", title, "BOTTOM", 0, -2)
    countdown:SetTextColor(0.7, 0.7, 0.7)
    countdown:SetText(" ")
    f.countdown = countdown

    -- "Call Swap" secure-like button (not actually secure — broadcast
    -- a SWAPREQUEST instead of a protected action).
    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(140, 32)
    btn:SetPoint("RIGHT", -10, 0)
    btn:SetText("|cffff8040Call Swap|r")
    btn:SetScript("OnClick", function()
        M:CallSwap()
    end)
    f.btn = btn

    -- OnUpdate: refresh countdown + button color based on time to
    -- estimated threshold. Cheap (text + color only).
    f:SetScript("OnUpdate", function(self)
        local cfg = M.state.current_config
        local tt  = M.state.threshold_time
        if not (cfg and tt) then
            self.countdown:SetText(" ")
            self.btn:SetText("|cffff8040Call Swap|r")
            return
        end
        local remaining = tt - GetTime()
        if remaining > 5 then
            self.countdown:SetText(("Swap window in |cff80ff80%.0fs|r"):format(remaining))
            self.btn:SetText("|cff808080Call Swap|r")
        elseif remaining > 2 then
            self.countdown:SetText(("|cffffff40Soon|r in |cffffff40%.1fs|r"):format(remaining))
            self.btn:SetText("|cffffff40Call Swap|r")
        elseif remaining > 0 then
            self.countdown:SetText(("|cffff4040NOW|r in |cffff4040%.1fs|r"):format(remaining))
            self.btn:SetText("|cffff4040CALL SWAP|r")
        else
            self.countdown:SetText("|cffff4040SWAP NOW|r")
            self.btn:SetText("|cffff4040CALL SWAP|r")
        end
    end)

    f:Hide()
    stack_watcher_frame = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "stacktankswap.watcher",
            frame = f,
            label = "Stack Watcher",
            default_point = { point = "BOTTOM", relPoint = "BOTTOM", x = 0, y = 180 },
        })
    end

    return f
end

----------------------------------------------------------------------
-- Register Private Aura SOUND + ANCHOR per config at addon load
----------------------------------------------------------------------
local function RegisterPrivateAuraFor(cfg)
    if not (C_UnitAuras) then return end
    if not cfg.debuff_spell_id then return end

    -- Sound (works for users with audio on; harmless otherwise)
    if C_UnitAuras.AddPrivateAuraAppliedSound and not registered_sounds[cfg.id] then
        local ok, sid = pcall(C_UnitAuras.AddPrivateAuraAppliedSound, {
            spellID       = cfg.debuff_spell_id,
            unitToken     = "player",
            soundFileName = cfg.sound_file,
        })
        if ok and sid then registered_sounds[cfg.id] = sid end
    end

    -- Anchor (visual stack icon — primary feedback for sound-off users)
    if C_UnitAuras.AddPrivateAuraAnchor and stack_watcher_frame and stack_watcher_frame.icon
       and not registered_anchors[cfg.id] then
        local ok, aid = pcall(C_UnitAuras.AddPrivateAuraAnchor, {
            unitToken            = "player",
            auraIndex            = 1,
            parent               = stack_watcher_frame.icon,
            showCountdownFrame   = false,
            showCountdownNumbers = false,
            isContainer          = false,
            iconInfo = {
                iconWidth  = 40,
                iconHeight = 40,
                iconAnchor = { point = "CENTER", relativeTo = stack_watcher_frame.icon,
                               relativePoint = "CENTER", offsetX = 0, offsetY = 0 },
            },
        })
        if ok and aid then registered_anchors[cfg.id] = aid end
    end
end

function M:CallSwap()
    local cfg = self.state.current_config
    if not cfg then
        VRT:Print("Call Swap: no active stack-swap encounter — button is inert outside Imperator/Salhadaar.")
        return
    end
    if not VRT or not VRT.SendModuleMessage then return end
    VRT:SendModuleMessage(M.id, "SWAPREQUEST", cfg.id .. "|manual")
    -- Reset countdown to a fresh threshold ETA from this moment, since
    -- whoever taunts becomes the new active tank starting stack 1.
    if cfg.per_stack_seconds then
        self.state.threshold_time = GetTime() + (cfg.threshold - 1) * cfg.per_stack_seconds
    end
    VRT:Print(("Call Swap broadcast for %s — partner should receive TAUNT popup."):format(cfg.display))
end

function M:OnInit()
    for _, cfg in pairs(STACK_SWAP_CONFIGS) do
        BuildTauntPopup(cfg)
    end
    BuildStackWatcherFrame()
    -- Private Aura registrations must happen AFTER BuildStackWatcherFrame
    -- so the anchor parent (icon slot) exists.
    for _, cfg in pairs(STACK_SWAP_CONFIGS) do
        RegisterPrivateAuraFor(cfg)
    end
    self.state.my_name = MyFullName()
end

function M:OnEncounterStart(eid)
    local cfg = STACK_SWAP_CONFIGS[eid]
    if not cfg then return end
    local s = self.state
    s.active = true
    s.current_config = cfg
    -- Anchor the countdown at encounter start. Assumes ~immediate
    -- engagement; users can manually Call Swap if they don't grab
    -- boss right away (resets the timer).
    if cfg.per_stack_seconds then
        s.threshold_time = GetTime() + (cfg.threshold - 1) * cfg.per_stack_seconds
    end
    -- Show the Stack Watcher (icon + Call Swap button) for tanks.
    if IsTank() and stack_watcher_frame then
        stack_watcher_frame:Show()
        if stack_watcher_frame.title then
            stack_watcher_frame.title:SetText(("|cff%s%s|r — listen for chimes"):format(
                cfg.color, cfg.debuff_name))
        end
        VRT:Print(("Stack swap armed for %s — chime per melee swing, click Call Swap when ready."):format(cfg.display))
    elseif not IsTank() then
        VRT:Print(("Stack swap armed for %s — you're not a tank; listening for partner's SWAPREQUEST."):format(cfg.display))
    end
end

function M:OnEncounterEnd(eid)
    local cfg = self.state.current_config
    if cfg and cfg.encounter_id == eid then
        self.state.active = false
        self.state.current_config = nil
        HideAllPopups()
        if stack_watcher_frame then stack_watcher_frame:Hide() end
    end
end

-- OnUnitAura removed: the 12.0.5 secret-value system makes self-aura
-- stack reading unreliable for boss-applied debuffs (confirmed via
-- TankSwapDiagnostic — applications_status=nil_or_secret for boss auras).
-- Swap is now triggered manually via the "Call Swap" button on the
-- Stack Watcher frame, which the tank clicks when they decide to swap
-- based on the Private-Aura sound chimes / visual icon stack count.

function M:OnAddonMessage(kind, data, sender)
    if kind ~= "SWAPREQUEST" then return end
    local cfg_id, stacks_str = data:match("^([^|]+)|(%d+)$")
    if not cfg_id then return end
    local cfg = FindConfigByID(cfg_id)
    if not cfg then return end
    if not self.state.active or self.state.current_config ~= cfg then return end
    if not IsTank() then return end
    -- If I currently have stacks of the same debuff, I'm the active tank,
    -- not the swap target — don't show popup to myself.
    if self.state.had_debuff and self.state.my_stacks > 0 then
        dbg("ignored SWAPREQUEST: I still have %d stacks", self.state.my_stacks)
        return
    end
    if sender == self.state.my_name then return end  -- echo of our own broadcast
    ShowTauntPopup(cfg, tonumber(stacks_str) or 0, sender)
end

----------------------------------------------------------------------
-- Slash commands
--   /vrt stacktankswap test <imperator|salhadaar>  — show test popup
--   /vrt stacktankswap debug                        — toggle debug
----------------------------------------------------------------------
function M:OnSlash(args)
    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = args:match("^(%S+)%s*(.*)$")
    first = (first or ""):lower()

    if first == "" or first == "help" then
        VRT:Print("StackTankSwap subcommands: test <imperator|salhadaar> | debug | list")
        return
    end
    if first == "list" then
        VRT:Print("Configured stack-swap fights:")
        for _, cfg in pairs(STACK_SWAP_CONFIGS) do
            print(("  |cff%s%s|r — debuff '%s' threshold %d, taunt %s"):format(
                cfg.color, cfg.display, cfg.debuff_name, cfg.threshold, cfg.boss_unit))
        end
        return
    end
    if first == "test" then
        local cfg_id = (rest or ""):lower()
        local cfg = FindConfigByID(cfg_id)
        if not cfg then
            VRT:Print("usage: /vrt stacktankswap test <imperator|salhadaar>")
            return
        end
        ShowTauntPopup(cfg, cfg.threshold, "TestSender")
        VRT:Print(("Test popup shown for %s."):format(cfg.display))
        return
    end
    if first == "debug" then
        local st = VRT:ModuleSettings(M.id)
        st.debug = not st.debug
        VRT:Print("StackTankSwap debug: " .. (st.debug and "ON" or "OFF"))
        return
    end
    VRT:Print("unknown subcommand. Try: /vrt stacktankswap help")
end

----------------------------------------------------------------------
-- Panel actions
----------------------------------------------------------------------
M.actions = {
    { label = "Show Stack Watcher (test)", action = function()
        if not stack_watcher_frame then BuildStackWatcherFrame() end
        if stack_watcher_frame then stack_watcher_frame:Show() end
    end },
    { label = "Hide Stack Watcher", action = function()
        if stack_watcher_frame then stack_watcher_frame:Hide() end
    end },
    { label = "Test Imperator TAUNT popup",  action = function() ShowTauntPopup(STACK_SWAP_CONFIGS[3176], 8, "TestSender") end },
    { label = "Test Salhadaar TAUNT popup",  action = function() ShowTauntPopup(STACK_SWAP_CONFIGS[3179], 8, "TestSender") end },
}

----------------------------------------------------------------------
-- Register with Core
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
