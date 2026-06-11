----------------------------------------------------------------------
-- VoidRaidTools — Vorasius Tank Router (Voidspire H/M, 6-cast cycle)
--
-- Mechanic:
--   Smashing Frenzy (spell 1241836) — single boss tankbuster. Per
--   prog convention (research doc § Vorasius § Shadowclaw Slam):
--     "Tank 1 eats first two hits (gets Smashed: +150% physical
--      damage taken, 2 min). Tank 2 swaps in with 0 stacks, soaks
--      remaining slams."
--   Cycle pattern observed in NSRT data: 4-cluster + 2-cluster = 6 casts
--   per ~2-minute cycle. T1 takes positions 1-2, T2 takes positions 3-6.
--   Cycle repeats — T1 comes back at the start of each new cycle once
--   Smashed has worn off (~120s).
--
-- Architecture: same ETEA-observation skeleton as LightblindedTanks.
-- One source (Vorasius himself, boss1). Tanks pre-claim "I go first"
-- vs "I go second"; popups route to whichever tank is up.
--
-- Boss unit token: boss1 (Vorasius, single boss encounter).
----------------------------------------------------------------------

local M = {
    state = {
        active                = false,
        difficulty_key        = nil,
        my_assignment         = nil,      -- "first" or "second"
        partner_assignment    = nil,
        partner_name          = nil,
        my_name               = nil,
        encounter_start_clock = nil,

        schedule = { frenzy = {} },
        next_idx = { frenzy = 1 },
        popup_handle = { frenzy = nil },

        pa_sound_ids = {},
    },
}

M.id             = "vorasius"
M.name           = "Vorasius — Tank Router"
M.encounter_id   = 3177
M.encounter_name = "Vorasius"
M.description    = "Vorasius — Smashing Frenzy cycle router. Tracks the 6-cast cycle and pops a one-click TAUNT button at the right beat (T1 takes 2 casts, T2 takes 4). No spreadsheet, no counting. Heroic+ only."

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local FRENZY_SPELL_ID = 1241836  -- Smashing Frenzy

-- Cross-validated NSRT/DBM data. Heroic and Mythic share the same
-- timestamps in NSRT (only damage/raid-mech tuning differs on Mythic).
local FRENZY_SCHEDULE = {
    Heroic = {17, 27, 36, 46, 68, 78, 137, 147, 157, 166, 191, 201, 258, 267, 277, 287, 314, 323},
    Mythic = {17, 27, 36, 46, 68, 78, 137, 147, 157, 166, 191, 201, 258, 267, 277, 287, 314, 323},
}

local SOURCE_INFO = {
    frenzy = { display = "Smashing Frenzy", unit = "boss1", spell = FRENZY_SPELL_ID, color = "ff8c40" },
}

-- Vorasius cycles: 6 casts per ~2-min cycle (4-cluster + 2-cluster).
-- Per prog convention, T1 eats positions 1-2 of each cycle (gets Smashed:
-- +150% physical damage taken, 2 min). T2 then taunts at position 3 and
-- soaks the remaining 4 casts (positions 3-6) of that cycle. Cycle 2 starts
-- with T1 again at position 7 (Smashed has expired by then — ~120s later).
local CYCLE_LENGTH        = 6   -- casts per cycle
local T1_CASTS_PER_CYCLE  = 2   -- positions 1-2 → T1, positions 3-6 → T2
local PRE_WARN_SECONDS = 3
local POPUP_DURATION   = 6
local TAUNT_MACRO_FMT  = "/cast [@%s] Taunt\n/cast [@%s] Hand of Reckoning\n/cast [@%s] Growl\n/cast [@%s] Dark Command\n/cast [@%s] Provoke\n/cast [@%s] Torment"

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT.modules and VRT:ModuleSettings(M.id).debug) then return end
    VRT:Print(("[Vora] " .. fmt):format(...))
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
    -- Normal (14) + LFR (17) both aliased to Heroic; ETEA re-anchors live.
    if diff == 14 then return "Heroic" end
    if diff == 15 then return "Heroic" end
    if diff == 16 then return "Mythic" end
    if diff == 17 then return "Heroic" end
    return nil
end

local function BuildTauntMacro(unit_token)
    return TAUNT_MACRO_FMT:format(unit_token, unit_token, unit_token, unit_token, unit_token, unit_token)
end

----------------------------------------------------------------------
-- SecureActionButton popup (one per source, pre-created at PLAYER_LOGIN)
----------------------------------------------------------------------
local taunt_popups = {}

local function BuildTauntPopup(source_key)
    if InCombatLockdown() then return end
    if taunt_popups[source_key] then return end
    local info = SOURCE_INFO[source_key]
    if not info then return end

    local btn = CreateFrame("Button", "VRT_Vora_Taunt_" .. source_key, UIParent, "SecureActionButtonTemplate")
    btn:SetSize(260, 100)
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
    verb:SetPoint("CENTER", 0, -4)
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
    taunt_popups[source_key] = btn

    if VRT and VRT.RegisterTauntPopup then VRT:RegisterTauntPopup(btn) end

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id     = "vorasius.taunt." .. source_key,
            frame  = btn,
            label  = ("Vora TAUNT — %s"):format(info.display),
            secure = true,
            default_point = { point = "TOP", relPoint = "TOP", x = 0, y = -185 },
        })
    end
end

local function HideAllPopups()
    for _, btn in pairs(taunt_popups) do btn:Hide() end
end

local function ShowTauntPopup(source_key, seconds_until_cast)
    local btn = taunt_popups[source_key]
    if not btn then return end
    btn:Show()
    local end_time = GetTime() + (seconds_until_cast or PRE_WARN_SECONDS) + POPUP_DURATION
    local cast_time = GetTime() + (seconds_until_cast or 0)
    btn:SetScript("OnUpdate", function(self)
        local now = GetTime()
        if now >= end_time then self:SetScript("OnUpdate", nil); self:Hide(); return end
        local until_cast = cast_time - now
        if until_cast > 0.05 then
            self.cd:SetText(("Frenzy in %.1fs"):format(until_cast))
        else
            self.cd:SetText("|cffff4040LANDED — taunt now if you haven't|r")
        end
    end)
end

----------------------------------------------------------------------
-- Assignment frame — "I go first" / "I go second"
----------------------------------------------------------------------
local assignment_frame

local function BuildAssignmentFrame()
    if assignment_frame then return end
    if InCombatLockdown() then return end

    local f = CreateFrame("Frame", "VRT_Vora_Assignment", UIParent)
    f:SetSize(320, 170)
    f:SetPoint("CENTER", -260, 60)
    f:SetFrameStrata("MEDIUM")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cffff8c40Vorasius|r")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("|cff8c8c9eClick who eats the first 2 hits.|r")

    local first = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    first:SetSize(140, 34)
    first:SetPoint("TOPLEFT", 14, -64)
    first:SetText("|cffff8c40I go first|r")
    first:SetScript("OnClick", function() M:ClaimRole("first") end)

    local second = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    second:SetSize(140, 34)
    second:SetPoint("TOPRIGHT", -14, -64)
    second:SetText("|cffaaaaaaI go second|r")
    second:SetScript("OnClick", function() M:ClaimRole("second") end)

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
            id    = "vorasius.assignment",
            frame = f,
            label = "Vora — Assign Order",
            default_point = { point = "CENTER", relPoint = "CENTER", x = -260, y = 60 },
        })
    end
end

local function RefreshAssignmentFrame()
    if not assignment_frame then return end
    local s = M.state
    if s.my_assignment then
        assignment_frame.status:SetText(("You: |cffff8c40%s|r"):format(s.my_assignment))
    else
        assignment_frame.status:SetText("|cff8c8c9eYou: (not claimed)|r")
    end
    if s.partner_assignment and s.partner_name then
        assignment_frame.partner:SetText(
            ("Partner: |cffff8c40%s|r (%s)"):format(s.partner_assignment, s.partner_name))
    else
        assignment_frame.partner:SetText("|cff8c8c9ePartner: (waiting)|r")
    end
end

----------------------------------------------------------------------
-- Claim + broadcast
----------------------------------------------------------------------
function M:ClaimRole(role)
    if role ~= "first" and role ~= "second" then return end
    local s = self.state
    s.my_assignment = role
    s.my_name = MyFullName()
    RefreshAssignmentFrame()
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "ASSIGN", role .. "=" .. s.my_name)
    end
    VRT:Print(("Vorasius: you go |cffff8c40%s|r."):format(role))
end

function M:OnAddonMessage(kind, data, sender)
    local s = self.state
    if kind == "ASSIGN" then
        local role, fullname = data:match("^([^=]+)=(.+)$")
        if not role or (role ~= "first" and role ~= "second") then return end
        if fullname == s.my_name then return end
        s.partner_assignment = role
        s.partner_name = fullname
        if not s.my_assignment then
            s.my_assignment = (role == "first") and "second" or "first"
            s.my_name = MyFullName()
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
-- Parity (single-source, cycle-based asymmetric swap)
--
-- 6-cast cycle. Position 1-2 = T1's, position 3-6 = T2's. New cycle
-- starts at position 1 again (cycle 2 starts at cast index 7).
--
-- Transitions (who taunts):
--   index 1 = cycle 1, pos 1   → opener, no taunt (T1 pulled the boss)
--   index 3 = cycle 1, pos 3   → T2 taunts (incoming)
--   index 7 = cycle 2, pos 1   → T1 taunts (Smashed wore off, takes back)
--   index 9 = cycle 2, pos 3   → T2 taunts
--   index 13 = cycle 3, pos 1  → T1 taunts
--   etc.
--
-- The taunt fires when the position transitions from one tank's range
-- to the other. Mid-range positions (e.g. pos 2 within T1, or pos 4-6
-- within T2) get no taunt — same tank holds.
----------------------------------------------------------------------
local function IShouldTauntAt(index)
    local s = M.state
    if not s.my_assignment then return false end
    if index <= 1 then return false end  -- opener; T1 already on boss from pull

    local pos      = ((index - 1) % CYCLE_LENGTH) + 1
    local prev_pos = ((index - 2) % CYCLE_LENGTH) + 1

    local current_owner  = (pos      <= T1_CASTS_PER_CYCLE) and "first" or "second"
    local previous_owner = (prev_pos <= T1_CASTS_PER_CYCLE) and "first" or "second"
    if current_owner == previous_owner then return false end  -- no transition

    return s.my_assignment == current_owner  -- I'm the incoming tank
end

----------------------------------------------------------------------
-- Schedule management (mirror of LightblindedTanks)
----------------------------------------------------------------------
local function BuildAbsoluteSchedule(start_time)
    local raw = FRENZY_SCHEDULE[M.state.difficulty_key]
    if not raw then return {} end
    local result = {}
    for i, rel in ipairs(raw) do result[i] = start_time + rel end
    return result
end

local function CancelPopupHandle(source_key)
    local h = M.state.popup_handle[source_key]
    if h and h.Cancel then pcall(h.Cancel, h) end
    M.state.popup_handle[source_key] = nil
end

local function ScheduleNextPopup(source_key)
    CancelPopupHandle(source_key)
    local s = M.state
    if not s.active then return end
    local idx = s.next_idx[source_key]
    local cast_at = s.schedule[source_key][idx]
    if not cast_at then return end

    local popup_at = cast_at - PRE_WARN_SECONDS
    local delay = popup_at - GetTime()
    if delay < 0.05 then delay = 0.05 end

    s.popup_handle[source_key] = C_Timer.NewTimer(delay, function()
        if not s.active then return end
        if IShouldTauntAt(idx) then
            local until_cast = (s.schedule[source_key][idx] or GetTime()) - GetTime()
            ShowTauntPopup(source_key, math.max(0, until_cast))
        else
            dbg("skip frenzy[%d] (mid-cluster or not my taunt)", idx)
        end
        s.next_idx[source_key] = idx + 1
        ScheduleNextPopup(source_key)
    end)
end

local DRIFT_THRESHOLD = 1.5
local function ReAnchorSchedule(source_key, idx, observed_cast_time)
    local s = M.state
    local sched = s.schedule[source_key]
    if not sched[idx] then return end
    local raw = FRENZY_SCHEDULE[s.difficulty_key]
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
    CancelPopupHandle("frenzy")
    HideAllPopups()
end

----------------------------------------------------------------------
-- Safe field read + closest index match (same as LightblindedTanks)
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
    max_diff = max_diff or 30
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
-- ETEA observer
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

    -- Single-source fight: match by spellID OR fall back to timing.
    local spell_id = SafeReadField(eventInfo, "spellID")
    if spell_id and spell_id ~= FRENZY_SPELL_ID then return end
    -- If spell_id is nil (tainted), fall back to closest-match (we only
    -- have one source so the match is direct).

    local idx, signed_diff = FindClosestIdx(s.schedule.frenzy, cast_at, 30)
    if not idx then return end

    if math.abs(signed_diff) > DRIFT_THRESHOLD then
        local actual = ReAnchorSchedule("frenzy", idx, cast_at)
        dbg("ETEA frenzy[%d] drift %.2fs -> re-anchored", idx, actual or 0)
        if s.next_idx.frenzy == idx then ScheduleNextPopup("frenzy") end
    else
        dbg("ETEA frenzy[%d] on-schedule (delta=%.2fs)", idx, signed_diff)
    end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    BuildTauntPopup("frenzy")
    BuildAssignmentFrame()
    self.state.my_name = MyFullName()
end

function M:OnEncounterStart(eid)
    if eid ~= self.encounter_id then return end
    local key = GetDifficultyKey()
    if not key then
        VRT:Print("Vorasius: difficulty not supported (LFR or unknown).")
        return
    end
    local s = self.state
    s.active = true
    s.difficulty_key = key
    s.encounter_start_clock = GetTime()
    s.schedule = { frenzy = BuildAbsoluteSchedule(s.encounter_start_clock) }
    s.next_idx = { frenzy = 1 }
    s.popup_handle = { frenzy = nil }
    ScheduleNextPopup("frenzy")
    if assignment_frame then assignment_frame:Hide() end

    local etea_on = (C_EncounterTimeline and C_EncounterTimeline.IsFeatureEnabled
                     and C_EncounterTimeline.IsFeatureEnabled()) or false
    VRT:Print(("Vorasius started (%s) — %d Smashing Frenzy casts armed (T1 takes 2, T2 takes 4 per cycle). ETEA: %s."):format(
        key, #s.schedule.frenzy,
        etea_on and "|cff20ff20ON|r" or "|cffff5050OFF|r"))
end

function M:OnEncounterEnd(eid)
    if eid ~= self.encounter_id then return end
    CancelAllPopups()
    local s = self.state
    s.active = false
    s.difficulty_key = nil
    s.encounter_start_clock = nil
    s.schedule = { frenzy = {} }
    s.next_idx = { frenzy = 1 }
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
function M:OnSlash(args)
    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = args:match("^(%S+)%s*(.*)$")
    first = (first or ""):lower()

    if first == "" or first == "help" then
        VRT:Print("Vorasius subcommands: show | reset | test | sim <heroic|mythic> | debug")
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
        VRT:Print("Vorasius: assignments cleared.")
        return
    end
    if first == "test" then
        ShowTauntPopup("frenzy", PRE_WARN_SECONDS)
        VRT:Print("Test frenzy popup shown.")
        return
    end
    if first == "sim" then
        local diff = (rest or "heroic"):lower()
        local key = (diff == "mythic") and "Mythic" or "Heroic"
        local s = self.state
        s.active = true
        s.difficulty_key = key
        s.encounter_start_clock = GetTime()
        s.schedule = { frenzy = BuildAbsoluteSchedule(s.encounter_start_clock) }
        s.next_idx = { frenzy = 1 }
        s.popup_handle = { frenzy = nil }
        if not s.my_assignment then
            s.my_assignment = "first"
            s.my_name = MyFullName()
            VRT:Print("sim: auto-claimed 'first' for you. Use /vrt vorasius reset after.")
        end
        ScheduleNextPopup("frenzy")
        VRT:Print(("Simulating Vorasius %s — %d Frenzy casts armed."):format(key, #s.schedule.frenzy))
        return
    end
    if first == "debug" then
        local st = VRT:ModuleSettings(M.id)
        st.debug = not st.debug
        VRT:Print("Vorasius debug: " .. (st.debug and "ON" or "OFF"))
        return
    end
    VRT:Print("unknown subcommand. Try: /vrt vorasius help")
end

----------------------------------------------------------------------
-- Panel actions
----------------------------------------------------------------------
M.actions = {
    { label = "Open Assignment", action = function()
        if not assignment_frame then BuildAssignmentFrame() end
        if assignment_frame then assignment_frame:Show(); RefreshAssignmentFrame() end
    end },
    { label = "Test Popup",  action = function() ShowTauntPopup("frenzy", PRE_WARN_SECONDS) end },
    { label = "Sim Heroic",  action = function() M:OnSlash("sim heroic") end },
    { label = "Sim Mythic",  action = function() M:OnSlash("sim mythic") end },
    { label = "Reset",       action = function() M:OnSlash("reset") end },
}

----------------------------------------------------------------------
-- Register with Core
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
