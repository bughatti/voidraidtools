----------------------------------------------------------------------
-- VoidRaidTools — Vaelgor & Ezzorak Tank Router (Voidspire H, N only)
--
-- Mechanic (per user's prog convention, confirmed 2026-06-04):
--   The tank swap happens on the FLY-PHASE transition, not on Gloom.
--   Both bosses fly up during Midnight Flames (intermission), then land
--   together. Tanks swap which dragon they hold each landing cycle.
--
-- This differs from VoidCheatSheet's documented "swap on Gloom" guidance;
-- the user's guild has killed it twice WITHOUT Gloom swaps. We honor
-- the user's convention.
--
-- Mythic note:
--   Per research doc "Bosses stay grounded -- Removes flying alternation",
--   so the MF-based swap doesn't apply on Mythic. Module no-ops on
--   difficulty 16.
--
-- Schedule (Heroic, absolute seconds from ENCOUNTER_START):
--   Midnight Flames cast times: 114, 246, 496
--   Bosses land ~12s after MF starts (estimated from MF duration).
--   Popup fires at MF + 8s (3s warning before landing).
--
-- Convention:
--   Tank A claims Vaelgor at pull. Tank B claims Ezzorak.
--   At each MF + landing, they swap: A goes to Ezzorak, B goes to Vaelgor.
--   Next MF: they swap back.
----------------------------------------------------------------------

local M = {
    state = {
        active                = false,
        difficulty_key        = nil,
        my_assignment         = nil,      -- "vaelgor" or "ezzorak"
        partner_assignment    = nil,
        partner_name          = nil,
        my_name               = nil,
        encounter_start_clock = nil,

        schedule = { intermission = {} }, -- absolute MF cast times
        next_idx = { intermission = 1 },
        popup_handle = { intermission = nil },
    },
}

M.id             = "vaelgor"
M.name           = "Vaelgor & Ezzorak — Tank Router"
M.encounter_id   = 3178
M.encounter_name = "Vaelgor & Ezzorak"
M.description    = "Routes tank swaps after each Midnight Flames intermission. Tanks swap dragons on landing. Heroic only."

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local MIDNIGHT_FLAMES_SPELL = 1249748  -- Midnight Flames cast that puts bosses airborne
local VAELGOR_TANKBUSTER    = 1265131  -- Vaelwing (for spell-id-based reverse ID if needed)
local EZZORAK_TANKBUSTER    = 1245645  -- Rakfang

-- Heroic Midnight Flames cast times (absolute from ENCOUNTER_START).
-- Source: NSRT BossTimelines/VaelgorEzzorak.lua P2 relative {8, 140, 390}
-- offset by P2 start = 106 → absolute {114, 246, 496}.
-- Normal aliased to Heroic (same boss schedule, less damage scaling).
local INTERMISSION_SCHEDULE = {
    Heroic = {114, 246, 496},
}

local DRAGON_INFO = {
    vaelgor = { display = "Vaelgor", unit = "boss1", color = "ffd700" },
    ezzorak = { display = "Ezzorak", unit = "boss2", color = "ff5577" },
}

local LANDING_DELAY_SECONDS = 12   -- estimate: bosses land ~12s after MF starts
local PRE_WARN_SECONDS      = 3    -- popup appears 3s before landing
local POPUP_DURATION        = 8
local TAUNT_MACRO_FMT       = "/cast [@%s] Taunt\n/cast [@%s] Hand of Reckoning\n/cast [@%s] Growl\n/cast [@%s] Dark Command\n/cast [@%s] Provoke\n/cast [@%s] Torment"

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT.modules and VRT:ModuleSettings(M.id).debug) then return end
    VRT:Print(("[V&E] " .. fmt):format(...))
end

local function MyFullName()
    local n = UnitName("player") or "?"
    local r = (GetRealmName and GetRealmName() or ""):gsub("%s+", "")
    if r == "" then return n end
    return n .. "-" .. r
end

local function GetDifficultyKey()
    if not GetInstanceInfo then return nil end
    local _, _, diff = GetInstanceInfo()
    -- Normal (14) + LFR (17) aliased to Heroic — both have the fly-phase
    -- mechanic, so the intermission-based swap applies.
    if diff == 14 then return "Heroic" end
    if diff == 15 then return "Heroic" end
    if diff == 17 then return "Heroic" end
    if diff == 16 then return nil end       -- Mythic: bosses grounded, MF swap N/A
    return nil
end

local function BuildTauntMacro(unit_token)
    return TAUNT_MACRO_FMT:format(unit_token, unit_token, unit_token, unit_token, unit_token, unit_token)
end

----------------------------------------------------------------------
-- Two SecureActionButton popups (one per dragon) pre-created at LOGIN
----------------------------------------------------------------------
local taunt_popups = {}

local function BuildTauntPopup(dragon_key)
    if InCombatLockdown() then return end
    if taunt_popups[dragon_key] then return end
    local info = DRAGON_INFO[dragon_key]
    if not info then return end

    local btn = CreateFrame("Button", "VRT_VE_Taunt_" .. dragon_key, UIParent, "SecureActionButtonTemplate")
    btn:SetSize(280, 110)
    btn:SetFrameStrata("DIALOG")
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", BuildTauntMacro(info.unit))
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
    title:SetText(("|cff%s%s|r"):format(info.color, info.display:upper()))
    btn.title = title

    local verb = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    verb:SetPoint("CENTER", 0, -2)
    verb:SetTextColor(1, 0.85, 0.2)
    local font, _, flags = verb:GetFont()
    if font then verb:SetFont(font, 22, flags) end
    verb:SetText("CLICK TO TAUNT")
    btn.verb = verb

    local cd = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cd:SetPoint("BOTTOM", 0, 8)
    cd:SetTextColor(1, 1, 1)
    btn.cd = cd

    btn:Hide()
    taunt_popups[dragon_key] = btn

    if VRT and VRT.RegisterTauntPopup then VRT:RegisterTauntPopup(btn) end

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id     = "vaelgor.taunt." .. dragon_key,
            frame  = btn,
            label  = ("V&E TAUNT — %s"):format(info.display),
            secure = true,
            default_point = { point = "TOP", relPoint = "TOP", x = 0, y = -185 },
        })
    end
end

local function HideAllPopups()
    for _, btn in pairs(taunt_popups) do btn:Hide() end
end

local function ShowTauntPopup(dragon_key, seconds_until_land)
    local btn = taunt_popups[dragon_key]
    if not btn then return end
    btn:Show()
    local end_time  = GetTime() + (seconds_until_land or PRE_WARN_SECONDS) + POPUP_DURATION
    local land_time = GetTime() + (seconds_until_land or 0)
    btn:SetScript("OnUpdate", function(self)
        local now = GetTime()
        if now >= end_time then self:SetScript("OnUpdate", nil); self:Hide(); return end
        local until_land = land_time - now
        if until_land > 0.05 then
            self.cd:SetText(("Landing in %.1fs"):format(until_land))
        else
            self.cd:SetText("|cffff4040LANDED — TAUNT NOW|r")
        end
    end)
end

----------------------------------------------------------------------
-- Assignment frame
----------------------------------------------------------------------
local assignment_frame

local function BuildAssignmentFrame()
    if assignment_frame then return end
    if InCombatLockdown() then return end

    local f = CreateFrame("Frame", "VRT_VE_Assignment", UIParent)
    f:SetSize(320, 170)
    f:SetPoint("CENTER", -260, 60)
    f:SetFrameStrata("MEDIUM")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cffffd700Vaelgor|r |cffffffff&|r |cffff5577Ezzorak|r")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("|cff8c8c9eClick which dragon you start on.|r")

    local vael = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    vael:SetSize(140, 34)
    vael:SetPoint("TOPLEFT", 14, -64)
    vael:SetText("I take |cffffd700Vaelgor|r")
    vael:SetScript("OnClick", function() M:ClaimDragon("vaelgor") end)

    local ezz = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ezz:SetSize(140, 34)
    ezz:SetPoint("TOPRIGHT", -14, -64)
    ezz:SetText("I take |cffff5577Ezzorak|r")
    ezz:SetScript("OnClick", function() M:ClaimDragon("ezzorak") end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("BOTTOMLEFT", 14, 38)
    status:SetPoint("BOTTOMRIGHT", -14, 38)
    status:SetJustifyH("LEFT")
    status:SetText(" ")
    f.status = status

    local partner = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    partner:SetPoint("BOTTOMLEFT", 14, 16)
    partner:SetPoint("BOTTOMRIGHT", -14, 16)
    partner:SetJustifyH("LEFT")
    partner:SetTextColor(0.7, 0.7, 0.7)
    partner:SetText(" ")
    f.partner = partner

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    f:Hide()
    assignment_frame = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "vaelgor.assignment",
            frame = f,
            label = "V&E — Assign Dragon",
            default_point = { point = "CENTER", relPoint = "CENTER", x = -260, y = 60 },
        })
    end
end

local function RefreshAssignmentFrame()
    if not assignment_frame then return end
    local s = M.state
    if s.my_assignment then
        local info = DRAGON_INFO[s.my_assignment]
        assignment_frame.status:SetText(("You start on: |cff%s%s|r"):format(info.color, info.display))
    else
        assignment_frame.status:SetText("|cff8c8c9eYou: (not claimed)|r")
    end
    if s.partner_assignment and s.partner_name then
        local info = DRAGON_INFO[s.partner_assignment]
        assignment_frame.partner:SetText(
            ("Partner: |cff%s%s|r (%s)"):format(info.color, info.display, s.partner_name))
    else
        assignment_frame.partner:SetText("|cff8c8c9ePartner: (waiting)|r")
    end
end

----------------------------------------------------------------------
-- Claim + broadcast (same protocol as other modules)
----------------------------------------------------------------------
function M:ClaimDragon(dragon_key)
    if not DRAGON_INFO[dragon_key] then return end
    local s = self.state
    s.my_assignment = dragon_key
    s.my_name = MyFullName()
    RefreshAssignmentFrame()
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "ASSIGN", dragon_key .. "=" .. s.my_name)
    end
    VRT:Print(("V&E: you start on |cff%s%s|r."):format(
        DRAGON_INFO[dragon_key].color, DRAGON_INFO[dragon_key].display))
end

function M:OnAddonMessage(kind, data, sender)
    local s = self.state
    if kind == "ASSIGN" then
        local dragon_key, fullname = data:match("^([^=]+)=(.+)$")
        if not dragon_key or not DRAGON_INFO[dragon_key] then return end
        if fullname == s.my_name then return end
        s.partner_assignment = dragon_key
        s.partner_name = fullname
        if not s.my_assignment then
            for other in pairs(DRAGON_INFO) do
                if other ~= dragon_key then
                    s.my_assignment = other
                    s.my_name = MyFullName()
                    break
                end
            end
        end
        RefreshAssignmentFrame()
    elseif kind == "RESET" then
        s.my_assignment = nil
        s.partner_assignment = nil
        s.partner_name = nil
        RefreshAssignmentFrame()
    end
end

----------------------------------------------------------------------
-- Parity (which dragon I'm swapping TO at intermission N)
--
-- Intermission 1 (first MF): we swap to OPPOSITE of our start
-- Intermission 2: we swap back to our START
-- Intermission 3: swap to OPPOSITE again
-- ...
-- Odd N: target = opposite of start. Even N: target = start.
----------------------------------------------------------------------
local function MyTauntTargetAt(intermission_idx)
    local s = M.state
    if not s.my_assignment then return nil end
    local opposite
    for other in pairs(DRAGON_INFO) do
        if other ~= s.my_assignment then opposite = other; break end
    end
    if intermission_idx % 2 == 1 then
        return opposite              -- swap to opposite
    else
        return s.my_assignment       -- swap back to start
    end
end

----------------------------------------------------------------------
-- Schedule management
----------------------------------------------------------------------
local function BuildAbsoluteSchedule(start_time)
    local raw = INTERMISSION_SCHEDULE[M.state.difficulty_key]
    if not raw then return {} end
    local result = {}
    for i, rel in ipairs(raw) do result[i] = start_time + rel end
    return result
end

local function CancelPopupHandle(key)
    local h = M.state.popup_handle[key]
    if h and h.Cancel then pcall(h.Cancel, h) end
    M.state.popup_handle[key] = nil
end

local function ScheduleNextIntermission()
    CancelPopupHandle("intermission")
    local s = M.state
    if not s.active then return end
    local idx = s.next_idx.intermission
    local mf_cast_at = s.schedule.intermission[idx]
    if not mf_cast_at then return end

    -- Popup fires (LANDING_DELAY - PRE_WARN) seconds after MF cast, so
    -- ~9s post-cast, giving a 3s warning before estimated land time.
    local popup_at = mf_cast_at + LANDING_DELAY_SECONDS - PRE_WARN_SECONDS
    local delay = popup_at - GetTime()
    if delay < 0.05 then delay = 0.05 end

    s.popup_handle.intermission = C_Timer.NewTimer(delay, function()
        if not s.active then return end
        local target_dragon = MyTauntTargetAt(idx)
        if target_dragon then
            local until_land = (mf_cast_at + LANDING_DELAY_SECONDS) - GetTime()
            ShowTauntPopup(target_dragon, math.max(0, until_land))
            dbg("MF[%d] -> swap to %s", idx, target_dragon)
        end
        s.next_idx.intermission = idx + 1
        ScheduleNextIntermission()
    end)
end

local DRIFT_THRESHOLD = 1.5
local function ReAnchorSchedule(idx, observed_cast_time)
    local s = M.state
    local sched = s.schedule.intermission
    if not sched[idx] then return end
    local raw = INTERMISSION_SCHEDULE[s.difficulty_key]
    if not raw then return end

    local drift = observed_cast_time - sched[idx]
    sched[idx] = observed_cast_time
    for i = idx + 1, #sched do
        local original_gap = (raw[i] or 0) - (raw[i - 1] or 0)
        sched[i] = sched[i - 1] + original_gap
    end
    return drift
end

local function CancelAllPopups()
    CancelPopupHandle("intermission")
    HideAllPopups()
end

----------------------------------------------------------------------
-- Safe field read + closest-index match (shared utility pattern)
----------------------------------------------------------------------
local function SafeReadField(t, field)
    if not t then return nil end
    local ok, val = pcall(function()
        local v = t[field]
        if issecretvalue and issecretvalue(v) then return nil end
        return v
    end)
    if not ok then return nil end
    return val
end

local function FindClosestIdx(schedule, target_time, max_diff)
    max_diff = max_diff or 60
    local best_idx, best_abs, best_signed = nil, math.huge, nil
    for i, t in ipairs(schedule) do
        local d = t - target_time
        local ad = math.abs(d)
        if ad < best_abs then best_abs = ad; best_idx = i; best_signed = d end
    end
    if best_abs > max_diff then return nil end
    return best_idx, best_signed
end

----------------------------------------------------------------------
-- ETEA observer — re-anchor on observed Midnight Flames casts
----------------------------------------------------------------------
function M:OnTimelineEvent(eventInfo)
    local s = self.state
    if not s.active then return end
    if not eventInfo then return end

    local source = SafeReadField(eventInfo, "source")
    if source ~= 0 then return end
    local duration = SafeReadField(eventInfo, "duration")
    if not duration or duration <= 0 then return end
    local cast_at = GetTime() + duration

    local spell_id = SafeReadField(eventInfo, "spellID")
    -- Only care about Midnight Flames. If spellID secret, fall back to
    -- timing-window match (MFs are 100+ seconds apart so unambiguous).
    if spell_id and spell_id ~= MIDNIGHT_FLAMES_SPELL then return end

    local idx, signed_diff = FindClosestIdx(s.schedule.intermission, cast_at, 60)
    if not idx then return end

    if math.abs(signed_diff) > DRIFT_THRESHOLD then
        local actual = ReAnchorSchedule(idx, cast_at)
        dbg("ETEA MF[%d] drift %.2fs -> re-anchored", idx, actual or 0)
        if s.next_idx.intermission == idx then ScheduleNextIntermission() end
    else
        dbg("ETEA MF[%d] on-schedule (delta=%.2fs)", idx, signed_diff)
    end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    BuildTauntPopup("vaelgor")
    BuildTauntPopup("ezzorak")
    BuildAssignmentFrame()
    self.state.my_name = MyFullName()
end

function M:OnEncounterStart(eid)
    if eid ~= self.encounter_id then return end
    local key = GetDifficultyKey()
    if not key then
        VRT:Print("V&E: Mythic doesn't use fly-phase swap (bosses stay grounded). Module idle.")
        return
    end
    local s = self.state
    s.active = true
    s.difficulty_key = key
    s.encounter_start_clock = GetTime()
    s.schedule = { intermission = BuildAbsoluteSchedule(s.encounter_start_clock) }
    s.next_idx = { intermission = 1 }
    s.popup_handle = { intermission = nil }
    ScheduleNextIntermission()
    if assignment_frame then assignment_frame:Hide() end

    local etea_on = (C_EncounterTimeline and C_EncounterTimeline.IsFeatureEnabled
                     and C_EncounterTimeline.IsFeatureEnabled()) or false
    VRT:Print(("V&E started (%s) — %d Midnight Flames intermissions armed. ETEA: %s."):format(
        key, #s.schedule.intermission,
        etea_on and "|cff20ff20ON|r" or "|cffff5050OFF|r"))
end

function M:OnEncounterEnd(eid)
    if eid ~= self.encounter_id then return end
    CancelAllPopups()
    local s = self.state
    s.active = false
    s.difficulty_key = nil
    s.encounter_start_clock = nil
    s.schedule = { intermission = {} }
    s.next_idx = { intermission = 1 }
end

----------------------------------------------------------------------
-- Slash (silent fallback only — panel actions are the primary UX)
----------------------------------------------------------------------
function M:OnSlash(args)
    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = args:match("^(%S+)%s*(.*)$")
    first = (first or ""):lower()

    if first == "" or first == "help" then
        VRT:Print("V&E: use the VRT panel (minimap icon) — these subcommands are fallback only.")
        return
    end
    if first == "show" then
        if not assignment_frame then BuildAssignmentFrame() end
        if assignment_frame then assignment_frame:Show(); RefreshAssignmentFrame() end
        return
    end
    if first == "reset" then
        self.state.my_assignment = nil
        self.state.partner_assignment = nil
        self.state.partner_name = nil
        RefreshAssignmentFrame()
        if VRT and VRT.SendModuleMessage then
            VRT:SendModuleMessage(M.id, "RESET", "")
        end
        return
    end
    if first == "test" then
        local dragon = (rest or ""):lower()
        if not DRAGON_INFO[dragon] then VRT:Print("usage: test <vaelgor|ezzorak>"); return end
        ShowTauntPopup(dragon, PRE_WARN_SECONDS)
        return
    end
    if first == "sim" then
        local diff = (rest or "heroic"):lower()
        local key = "Heroic"
        local s = self.state
        s.active = true
        s.difficulty_key = key
        s.encounter_start_clock = GetTime()
        s.schedule = { intermission = BuildAbsoluteSchedule(s.encounter_start_clock) }
        s.next_idx = { intermission = 1 }
        s.popup_handle = { intermission = nil }
        if not s.my_assignment then
            s.my_assignment = "vaelgor"
            s.my_name = MyFullName()
            VRT:Print("sim: auto-claimed Vaelgor for you.")
        end
        ScheduleNextIntermission()
        VRT:Print(("Simulating V&E %s — %d intermissions armed (first popup in ~%ds)."):format(
            key, #s.schedule.intermission, INTERMISSION_SCHEDULE[key][1] + LANDING_DELAY_SECONDS - PRE_WARN_SECONDS))
        return
    end
    if first == "debug" then
        local st = VRT:ModuleSettings(M.id)
        st.debug = not st.debug
        VRT:Print("V&E debug: " .. (st.debug and "ON" or "OFF"))
        return
    end
end

----------------------------------------------------------------------
-- Panel actions (primary UX)
----------------------------------------------------------------------
M.actions = {
    { label = "Open Assignment", action = function()
        if not assignment_frame then BuildAssignmentFrame() end
        if assignment_frame then assignment_frame:Show(); RefreshAssignmentFrame() end
    end },
    { label = "Test Vaelgor", action = function() ShowTauntPopup("vaelgor", PRE_WARN_SECONDS) end },
    { label = "Test Ezzorak", action = function() ShowTauntPopup("ezzorak", PRE_WARN_SECONDS) end },
    { label = "Sim Heroic",   action = function() M:OnSlash("sim heroic") end },
    { label = "Reset",        action = function() M:OnSlash("reset") end },
}

----------------------------------------------------------------------
-- Register with Core
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
