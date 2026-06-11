----------------------------------------------------------------------
-- VoidRaidTools — Lightblinded Vanguard Tank Router (Voidspire H/M)
--
-- Mechanic:
--   Bellamy and Venel each cast their own "Judgment" (Shield of the
--   Righteous / Final Verdict) tankbusters as PAIRED events ~4s apart.
--   With 2 tanks, the prog convention is: one tank claims Bellamy and
--   one claims Venel; on each Judgment the SWAP PARTNER taunts. Both
--   tanks effectively trade bosses on every pair.
--
-- Architecture (v0.4 — DBM-style ETEA observation):
--   - Pre-pull: shows an assignment frame ("I take Bellamy" / "I take
--     Venel"). Click broadcasts to the other tank.
--   - On ENCOUNTER_START(3180): builds per-boss absolute schedules from
--     hardcoded NSRT/DBM-derived arrays. Schedules the NEXT popup per
--     boss only (chains on fire-then-schedule-next basis).
--   - ENCOUNTER_TIMELINE_EVENT_ADDED (Blizzard's clean untainted API):
--     fires whenever the boss queues a Judgment. We read eventInfo.
--     duration (NeverSecret) for the cast time, and eventInfo.spellID
--     (often readable but may be secret on encounter events).
--     If spellID readable → direct boss match. Otherwise → match by
--     timing against the static schedule. On every observation we
--     compare to predicted and RE-ANCHOR the schedule if drift > 1.5s.
--     This auto-corrects for phase pauses, immunities, hotfixes.
--   - ~3s before each (corrected) scheduled Judgment, the non-active
--     tank gets a big TAUNT popup. The popup IS a SecureActionButton —
--     clicking it fires `/cast [@bossN] Taunt; Hand of Reckoning;
--     Growl; Dark Command; Provoke; Torment` (class-agnostic fallback).
--   - Private Aura sound (registered at PLAYER_LOGIN) plays when the
--     Judgment debuff lands on us, as a confirmation cue.
--
-- Why this beats DBM:
--   * DBM uses a 700-line per-fight state machine to identify spells
--     from timer deltas. We use spellID directly (with timing fallback).
--   * DBM warns BOTH tanks every Judgment. We route to the specific tank.
--   * DBM has no built-in one-click taunt. We do.
--   * DBM clients don't share state. We use the same Blizzard API on
--     every client — group naturally syncs, no INSTANCE_CHAT needed.
--   * If ETEA is disabled or feature not available, we gracefully fall
--     back to pure static schedule (still better than DBM's fallback).
--
-- Boss unit tokens:
--   Per Blizz convention, boss1/boss2/boss3 are populated for multi-boss
--   encounters in pull order (Bellamy/Venel/Senn for Lightblinded
--   Vanguard). Confirm against actual pull frame if a future patch
--   shuffles them.
----------------------------------------------------------------------

local M = {
    state = {
        active                = false,    -- ENCOUNTER_START fired, ENCOUNTER_END not yet
        difficulty_key        = nil,      -- "Heroic" / "Mythic" / nil (LFR/Normal no-op)
        my_assignment         = nil,      -- "bellamy" / "venel" / nil
        partner_assignment    = nil,      -- the other tank's claim
        partner_name          = nil,
        my_name               = nil,
        encounter_start_clock = nil,      -- GetTime() at ENCOUNTER_START

        -- Per-boss mutable schedules (absolute GetTime() values). Built
        -- from JUDGMENT_SCHEDULE at ENCOUNTER_START. ETEA observations
        -- can re-anchor entries in place.
        schedule = {
            bellamy = {},
            venel   = {},
        },
        -- Index of the next popup to fire (1-based) per boss
        next_idx = {
            bellamy = 1,
            venel   = 1,
        },
        -- Currently-scheduled popup C_Timer handle per boss (so we can
        -- cancel + reschedule when ETEA observation re-anchors timing)
        popup_handle = {
            bellamy = nil,
            venel   = nil,
        },

        pa_sound_ids = {},                -- registered Private Aura sound IDs (for cleanup)
    },
}

M.id             = "lightblinded"
M.name           = "Lightblinded Vanguard — Tank Router"
M.encounter_id   = 3180
M.encounter_name = "Lightblinded Vanguard"
M.description    = "Lightblinded Vanguard — one-click TAUNT popup. Addon decides which tank (you or co-tank) should be on Bellamy vs Venel based on Judgment debuff stacks, you just click. DBM says 'swap', this picks WHO and gives you the button. Heroic+ only."

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local BELLAMY_JUDGMENT_SPELL = 1251857  -- Judgement (Shield of the Righteous)
local VENEL_JUDGMENT_SPELL   = 1246736  -- Judgement (Final Verdict)

-- Cross-validated timer arrays. Source:
--   NSRT BossTimelines/LightblindedVanguard.lua, Wago build 2026-05.
--   DBM-Raids-Midnight/VoidSpire/LightblindedVanguard.lua.
-- Bellamy and Venel Judgments fire as PAIRED events ~4s apart. Tanks taunt
-- in near-simultaneous swap — Tank 1 ends up on the boss Tank 2 was on
-- and vice versa.
--
-- Per-boss times derived from Shield-of-the-Righteous (Bellamy follow-up)
-- and Final-Verdict (Venel follow-up) timestamps minus the follow-up gap
-- (1s on Heroic, 3s on Mythic). NSRT's combined "Judgment" array was
-- missing 2 of Bellamy's late Heroic Judgments (346, 363) — we restore
-- them from the Shield timestamps.
--
-- Heroic pair 3 (113 / 115) is anomalously 2s apart (vs the usual 4s).
-- Could be a real tight-swap moment in that part of the fight, or a data
-- quirk. Watch for it in the first pull and flag if the popup misfires.
local JUDGMENT_SCHEDULE = {
    Heroic = {
        bellamy = {29, 71, 113, 127, 151, 171, 191, 243, 303, 323, 346, 363},
        venel   = {33, 75, 115, 131, 155, 175, 195, 247, 307, 327, 350, 367},
    },
    Mythic = {
        bellamy = {22, 58, 112, 148, 166, 220, 274, 310, 328, 382, 436},
        venel   = {26, 62, 116, 152, 170, 224, 278, 314, 332, 386, 440},
    },
}

-- Boss display names + which boss1/2/3 token they correspond to + the
-- per-boss Judgment spell ID for Private Aura registration.
-- 6-char RGB (alpha is supplied by the `|cff` prefix at each call site).
local BOSS_INFO = {
    bellamy = { display = "Bellamy",  unit = "boss1", spell = BELLAMY_JUDGMENT_SPELL, color = "ffd700" },
    venel   = { display = "Venel",    unit = "boss2", spell = VENEL_JUDGMENT_SPELL,   color = "20c0ff" },
}

local PRE_WARN_SECONDS = 3      -- popup shows this many seconds before scheduled Judgment
local POPUP_DURATION   = 6      -- auto-hide after Judgment lands + small grace
local TAUNT_MACRO_FMT  = "/cast [@%s] Taunt\n/cast [@%s] Hand of Reckoning\n/cast [@%s] Growl\n/cast [@%s] Dark Command\n/cast [@%s] Provoke\n/cast [@%s] Torment"

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT.modules and VRT:ModuleSettings("lightblinded").debug) then return end
    VRT:Print(("[LV] " .. fmt):format(...))
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

local function GetDifficultyKey()
    if not GetInstanceInfo then return nil end
    local _, _, diff = GetInstanceInfo()
    -- 14 = Normal, 15 = Heroic, 16 = Mythic, 17 = LFR.
    -- Normal + LFR aliased to Heroic data (mechanic schedule typically
    -- identical; only damage scales). LFR may simplify or skip mechanics
    -- entirely, in which case ETEA observation will re-anchor or popups
    -- simply won't fire if Blizz queues nothing. Best-effort coverage.
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
-- SecureActionButton popups (one per boss, pre-created at PLAYER_LOGIN)
--
-- Cannot be created / SetAttribute'd during combat. Must exist BEFORE
-- ENCOUNTER_START. We build them once at PLAYER_LOGIN.
----------------------------------------------------------------------
local taunt_popups = {}  -- ["bellamy"] = SecureActionButton, ["venel"] = SecureActionButton

local function BuildTauntPopup(boss_key)
    if InCombatLockdown() then return end
    if taunt_popups[boss_key] then return end
    local info = BOSS_INFO[boss_key]
    if not info then return end

    local btn = CreateFrame("Button", "VRT_LV_Taunt_" .. boss_key, UIParent, "SecureActionButtonTemplate")
    btn:SetSize(260, 100)
    btn:SetFrameStrata("DIALOG")
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", BuildTauntMacro(info.unit))

    -- Default position mimics DBM Special Warning placement. /vrt edit
    -- overrides this with the saved position via VRT:RegisterMovable.
    btn:SetPoint("TOP", UIParent, "TOP", 0, -185)

    -- background + colored border
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.10, 0.02, 0.02, 0.55)

    local function MakeBorderEdge(point1, point2, w, h)
        local t = btn:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 0.35, 0.1, 1)
        if point1 and point2 then
            t:SetPoint(point1)
            t:SetPoint(point2)
        end
        if w then t:SetWidth(w) end
        if h then t:SetHeight(h) end
        return t
    end
    MakeBorderEdge("TOPLEFT",     "TOPRIGHT",    nil, 2)
    MakeBorderEdge("BOTTOMLEFT",  "BOTTOMRIGHT", nil, 2)
    MakeBorderEdge("TOPLEFT",     "BOTTOMLEFT",  2,   nil)
    MakeBorderEdge("TOPRIGHT",    "BOTTOMRIGHT", 2,   nil)

    -- Title: "TAUNT BELLAMY"
    local title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetTextColor(1, 1, 1)
    title:SetText(("|cff%s%s|r"):format(info.color, info.display:upper()))
    btn.title = title

    -- Big "TAUNT" verb
    local verb = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    verb:SetPoint("CENTER", 0, -4)
    verb:SetTextColor(1, 0.85, 0.2)
    local font, _, flags = verb:GetFont()
    if font then verb:SetFont(font, 22, flags) end
    verb:SetText("CLICK TO TAUNT")
    btn.verb = verb

    -- Countdown timer
    local cd = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cd:SetPoint("BOTTOM", 0, 8)
    cd:SetTextColor(1, 1, 1)
    btn.cd = cd

    btn:Hide()
    taunt_popups[boss_key] = btn

    -- Register for the TAUNT keybind so user's bound key clicks this
    -- popup when it's visible.
    if VRT and VRT.RegisterTauntPopup then
        VRT:RegisterTauntPopup(btn)
    end

    -- Register with Core's edit-mode so /vrt edit shows + drags this frame.
    -- secure=true: don't attach native drag scripts (would eat the taunt click).
    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id     = "lightblinded.taunt." .. boss_key,
            frame  = btn,
            label  = ("LV TAUNT — %s"):format(info.display),
            secure = true,
            default_point = { point = "TOP", relPoint = "TOP", x = 0, y = -185 },
        })
    end
end

local function HideAllPopups()
    for _, btn in pairs(taunt_popups) do
        if not InCombatLockdown() then
            btn:Hide()
        else
            -- In combat we cannot reliably Hide() a protected frame's parent,
            -- but Button:Hide() on a SecureActionButtonTemplate is allowed.
            btn:Hide()
        end
    end
end

local function ShowTauntPopup(boss_key, seconds_until_judgment)
    local btn = taunt_popups[boss_key]
    if not btn then return end
    btn:Show()

    -- Live countdown via OnUpdate
    local end_time = GetTime() + (seconds_until_judgment or PRE_WARN_SECONDS) + POPUP_DURATION
    local judgment_time = GetTime() + (seconds_until_judgment or 0)
    btn:SetScript("OnUpdate", function(self, elapsed)
        local now = GetTime()
        if now >= end_time then
            self:SetScript("OnUpdate", nil)
            self:Hide()
            return
        end
        local until_jdg = judgment_time - now
        if until_jdg > 0.05 then
            self.cd:SetText(("Judgment in %.1fs"):format(until_jdg))
        else
            self.cd:SetText("|cffff4040LANDED — taunt now if you haven't|r")
        end
    end)
end

----------------------------------------------------------------------
-- Assignment frame (pre-pull "I take Bellamy" / "I take Venel")
----------------------------------------------------------------------
local assignment_frame
local function BuildAssignmentFrame()
    if assignment_frame then return end
    if InCombatLockdown() then return end

    local f = CreateFrame("Frame", "VRT_LV_Assignment", UIParent)
    f:SetSize(320, 170)
    f:SetPoint("CENTER", -260, 60)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cffffd700Lightblinded Vanguard|r")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("|cff8c8c9eClick the boss you will tank first.|r")

    local bel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bel:SetSize(140, 34)
    bel:SetPoint("TOPLEFT", 14, -64)
    bel:SetText("I take |cffffd700Bellamy|r")
    bel:SetScript("OnClick", function() M:ClaimBoss("bellamy") end)

    local ven = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ven:SetSize(140, 34)
    ven:SetPoint("TOPRIGHT", -14, -64)
    ven:SetText("I take |cff20c0ffVenel|r")
    ven:SetScript("OnClick", function() M:ClaimBoss("venel") end)

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
            id    = "lightblinded.assignment",
            frame = f,
            label = "LV — Assign Boss",
            default_point = { point = "CENTER", relPoint = "CENTER", x = -260, y = 60 },
        })
    end
end

local function RefreshAssignmentFrame()
    if not assignment_frame then return end
    local s = M.state
    local my_part = s.my_assignment
    if my_part then
        local info = BOSS_INFO[my_part]
        assignment_frame.status:SetText(
            ("You: |cff%s%s|r"):format(info.color, info.display))
    else
        assignment_frame.status:SetText("|cff8c8c9eYou: (not claimed)|r")
    end
    if s.partner_assignment and s.partner_name then
        local info = BOSS_INFO[s.partner_assignment]
        assignment_frame.partner:SetText(
            ("Partner: |cff%s%s|r (%s)"):format(info.color, info.display, s.partner_name))
    else
        assignment_frame.partner:SetText("|cff8c8c9ePartner: (waiting)|r")
    end
end

----------------------------------------------------------------------
-- Claim / broadcast protocol
--
-- Messages (module_id "lightblinded", routed by VRT Core):
--   ASSIGN|<boss>=<fullname>             — sender claims this boss
--   RESET                                 — clear all claims
--
-- Both tanks running VRT will mirror each other's state via these.
----------------------------------------------------------------------
function M:ClaimBoss(boss_key)
    if not BOSS_INFO[boss_key] then return end
    local s = self.state
    s.my_assignment = boss_key
    s.my_name = MyFullName()
    RefreshAssignmentFrame()
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "ASSIGN", boss_key .. "=" .. s.my_name)
    end
    VRT:Print(("Lightblinded: you take |cff%s%s|r."):format(
        BOSS_INFO[boss_key].color, BOSS_INFO[boss_key].display))
end

function M:OnAddonMessage(kind, data, sender)
    local s = self.state
    if kind == "ASSIGN" then
        local boss_key, fullname = data:match("^([^=]+)=(.+)$")
        if not boss_key or not BOSS_INFO[boss_key] then return end
        if fullname == s.my_name then return end  -- echo of our own broadcast
        s.partner_assignment = boss_key
        s.partner_name = fullname
        -- If I haven't claimed yet, auto-claim the OTHER boss (one-side-claim shortcut)
        if not s.my_assignment then
            for other_key in pairs(BOSS_INFO) do
                if other_key ~= boss_key then
                    s.my_assignment = other_key
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
-- Schedule computation
--
-- For each Bellamy time index i (1-based):
--   i=1: claimant has the boss → at T=time[1] Judgment lands on claimant
--        → so PARTNER taunts ~3s before time[1]
--   i=2: partner has it now → claimant taunts ~3s before time[2]
--   ...
--   ODD i  → partner taunts (i.e., the non-claimant of THIS boss)
--   EVEN i → claimant taunts
--
-- "Claimant of THIS boss" is whoever broadcast ASSIGN|<this boss>=name.
-- For determining "am I the taunter at index i":
--   I'm the claimant of boss X  →  I taunt at EVEN i for X
--   I'm the partner of boss X   →  I taunt at ODD  i for X
----------------------------------------------------------------------
local function IShouldTauntAt(boss_key, index)
    local s = M.state
    if not s.my_assignment then return false end
    local i_claim_this = (s.my_assignment == boss_key)
    if i_claim_this then
        return (index % 2 == 0)
    else
        return (index % 2 == 1)
    end
end

----------------------------------------------------------------------
-- Schedule management — per-boss chain scheduling
--
-- Each boss has its own mutable absolute-time schedule built at
-- ENCOUNTER_START. We hold exactly ONE C_Timer outstanding per boss at
-- a time — when it fires we show the popup (if applicable), advance
-- next_idx, and schedule the next one. This makes ETEA re-anchoring
-- trivial: cancel current handle, mutate the schedule table in place,
-- re-schedule.
----------------------------------------------------------------------
local function BuildAbsoluteSchedule(boss_key, start_time)
    local diff_table = JUDGMENT_SCHEDULE[M.state.difficulty_key]
    local raw = diff_table and diff_table[boss_key]
    if not raw then return {} end
    local result = {}
    for i, rel in ipairs(raw) do
        result[i] = start_time + rel
    end
    return result
end

local function CancelPopupHandle(boss_key)
    local h = M.state.popup_handle[boss_key]
    if h and h.Cancel then pcall(h.Cancel, h) end
    M.state.popup_handle[boss_key] = nil
end

local function ScheduleNextPopup(boss_key)
    CancelPopupHandle(boss_key)
    local s = M.state
    if not s.active then return end
    local idx = s.next_idx[boss_key]
    local cast_at = s.schedule[boss_key][idx]
    if not cast_at then return end  -- past end of schedule

    local popup_at = cast_at - PRE_WARN_SECONDS
    local delay = popup_at - GetTime()
    if delay < 0.05 then delay = 0.05 end

    s.popup_handle[boss_key] = C_Timer.NewTimer(delay, function()
        if not s.active then return end
        if IShouldTauntAt(boss_key, idx) then
            local until_cast = (s.schedule[boss_key][idx] or GetTime()) - GetTime()
            ShowTauntPopup(boss_key, math.max(0, until_cast))
        else
            dbg("skip %s[%d] (not my taunt)", boss_key, idx)
        end
        s.next_idx[boss_key] = idx + 1
        ScheduleNextPopup(boss_key)
    end)
end

-- ETEA observation tells us the real cast time for some Judgment. If it
-- diverges from prediction by > DRIFT_THRESHOLD, mutate the schedule
-- in place — both the observed index AND all later indices, preserving
-- the ORIGINAL GAP between consecutive Judgments (which captures the
-- fight's known non-uniform cadence — e.g. the 14s gap between H[3]
-- and H[4]). This keeps subsequent predictions accurate even after a
-- single delay/early/skip event.
local DRIFT_THRESHOLD = 1.5
local function ReAnchorSchedule(boss_key, idx, observed_cast_time)
    local s = M.state
    local sched = s.schedule[boss_key]
    if not sched[idx] then return end
    local diff_table = JUDGMENT_SCHEDULE[s.difficulty_key]
    local raw = diff_table and diff_table[boss_key]
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
    CancelPopupHandle("bellamy")
    CancelPopupHandle("venel")
    HideAllPopups()
end

----------------------------------------------------------------------
-- Helpers — safe field read (encounter event fields can be secret in
-- 12.0.5) + closest-index lookup for ETEA → schedule matching.
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
        if ad < best_abs then
            best_abs = ad
            best_idx = i
            best_signed = d
        end
    end
    if best_abs > max_diff then return nil end
    return best_idx, best_signed
end

----------------------------------------------------------------------
-- ETEA (ENCOUNTER_TIMELINE_EVENT_ADDED) observer — Blizzard's clean
-- untainted boss-timing API for 12.0.5. Routed in from Core's event
-- dispatcher. Fires whenever the boss queues an upcoming ability.
----------------------------------------------------------------------
function M:OnTimelineEvent(eventInfo)
    local s = self.state
    if not s.active then return end
    if not eventInfo then return end

    -- Per Blizz docs, source is NeverSecret. 0 = Encounter (what we want).
    local source = SafeReadField(eventInfo, "source")
    if source ~= 0 then return end

    -- duration is NeverSecret — the seconds until the event resolves.
    local duration = SafeReadField(eventInfo, "duration")
    if not duration or duration <= 0 then return end
    local cast_at = GetTime() + duration

    -- Identify the boss. Prefer direct spellID; fall back to closest-
    -- match against our prediction tables if spellID is secret.
    local spell_id = SafeReadField(eventInfo, "spellID")
    local boss_key
    if spell_id == BELLAMY_JUDGMENT_SPELL then
        boss_key = "bellamy"
    elseif spell_id == VENEL_JUDGMENT_SPELL then
        boss_key = "venel"
    else
        local b_idx, b_diff = FindClosestIdx(s.schedule.bellamy, cast_at, 5)
        local v_idx, v_diff = FindClosestIdx(s.schedule.venel, cast_at, 5)
        if b_idx and (not v_idx or math.abs(b_diff) < math.abs(v_diff)) then
            boss_key = "bellamy"
        elseif v_idx then
            boss_key = "venel"
        end
    end
    if not boss_key then return end

    local idx, signed_diff = FindClosestIdx(s.schedule[boss_key], cast_at, 30)
    if not idx then return end

    if math.abs(signed_diff) > DRIFT_THRESHOLD then
        local actual = ReAnchorSchedule(boss_key, idx, cast_at)
        dbg("ETEA %s[%d] drift %.2fs → re-anchored", boss_key, idx, actual or 0)
        if s.next_idx[boss_key] == idx then
            ScheduleNextPopup(boss_key)
        end
    else
        dbg("ETEA %s[%d] on-schedule (delta=%.2fs)", boss_key, idx, signed_diff)
    end
end

----------------------------------------------------------------------
-- Private Aura: resync confirmation
--
-- When a Judgment debuff lands on the player (as a private aura), play
-- the registered sound. This tells the active tank "you got hit — the
-- next one is on your partner." We don't strictly need to mutate state
-- here because the schedule is deterministic, but the audio cue is a
-- valuable confirmation that the timer fired correctly.
----------------------------------------------------------------------
local function RegisterPrivateAuraSounds()
    if not (C_UnitAuras and C_UnitAuras.AddPrivateAuraAppliedSound) then return end
    if #M.state.pa_sound_ids > 0 then return end  -- already registered
    for _, spell_id in ipairs({ BELLAMY_JUDGMENT_SPELL, VENEL_JUDGMENT_SPELL }) do
        local ok, sound_id = pcall(C_UnitAuras.AddPrivateAuraAppliedSound, {
            spellID       = spell_id,
            unitToken     = "player",
            soundFileName = "Sound\\Interface\\AlarmClockWarning2.ogg",
        })
        if ok and sound_id then
            table.insert(M.state.pa_sound_ids, sound_id)
        end
    end
    dbg("PA sounds registered: %d", #M.state.pa_sound_ids)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    BuildTauntPopup("bellamy")
    BuildTauntPopup("venel")
    BuildAssignmentFrame()
    RegisterPrivateAuraSounds()
    self.state.my_name = MyFullName()
end

function M:OnZoneChanged()
    -- Show assignment UI on tanks who are in a raid instance. We don't
    -- key off a specific Voidspire instance ID (might shift between
    -- patches); the UI is harmless on other raids and can be closed.
    if not assignment_frame then return end
    if IsTank() and IsInInstance() == true then
        -- Don't auto-show — the user can summon it via /vrt lightblinded show.
        -- Auto-show in Voidspire only if we add a confirmed map ID later.
    end
end

function M:OnEncounterStart(eid)
    if eid ~= self.encounter_id then return end
    local key = GetDifficultyKey()
    if not key then
        VRT:Print("Lightblinded: Heroic+ only (this difficulty has no tank-router data).")
        return
    end
    local s = self.state
    s.active = true
    s.difficulty_key = key
    s.encounter_start_clock = GetTime()
    s.schedule = {
        bellamy = BuildAbsoluteSchedule("bellamy", s.encounter_start_clock),
        venel   = BuildAbsoluteSchedule("venel",   s.encounter_start_clock),
    }
    s.next_idx     = { bellamy = 1, venel = 1 }
    s.popup_handle = { bellamy = nil, venel = nil }
    ScheduleNextPopup("bellamy")
    ScheduleNextPopup("venel")
    if assignment_frame then assignment_frame:Hide() end

    -- ETEA status check: tell the user whether drift correction is live.
    local etea_on = true
    if C_EncounterTimeline and C_EncounterTimeline.IsFeatureEnabled then
        etea_on = C_EncounterTimeline.IsFeatureEnabled() and true or false
    end
    VRT:Print(("Lightblinded started (%s) — %d+%d Judgments armed. ETEA drift correction: %s."):format(
        key,
        #s.schedule.bellamy, #s.schedule.venel,
        etea_on and "|cff20ff20ON|r" or "|cffff5050OFF|r (enable Encounter Timeline in WoW settings)"))
end

function M:OnEncounterEnd(eid)
    if eid ~= self.encounter_id then return end
    CancelAllPopups()
    local s = self.state
    s.active = false
    s.difficulty_key = nil
    s.encounter_start_clock = nil
    s.schedule = { bellamy = {}, venel = {} }
    s.next_idx = { bellamy = 1, venel = 1 }
end

----------------------------------------------------------------------
-- Slash commands
--   /vrt lightblinded show          — open assignment frame
--   /vrt lightblinded reset         — clear claims + broadcast RESET
--   /vrt lightblinded test bellamy  — simulate a Bellamy TAUNT popup
--   /vrt lightblinded test venel    — simulate a Venel TAUNT popup
--   /vrt lightblinded sim heroic    — schedule a full Heroic encounter NOW
--   /vrt lightblinded sim mythic    — schedule a full Mythic encounter NOW
--   /vrt lightblinded debug         — toggle dbg() prints
----------------------------------------------------------------------
function M:OnSlash(args)
    args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local first, rest = args:match("^(%S+)%s*(.*)$")
    first = (first or ""):lower()

    if first == "" or first == "help" then
        VRT:Print("Lightblinded subcommands: show | reset | test <bellamy|venel> | sim <heroic|mythic> | debug")
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
        VRT:Print("Lightblinded: assignments cleared.")
        return
    end

    if first == "test" then
        local boss = (rest or ""):lower()
        if not BOSS_INFO[boss] then VRT:Print("usage: /vrt lightblinded test bellamy|venel"); return end
        ShowTauntPopup(boss, PRE_WARN_SECONDS)
        VRT:Print(("Test %s popup shown."):format(boss))
        return
    end

    if first == "sim" then
        local diff = (rest or "heroic"):lower()
        local key = (diff == "mythic") and "Mythic" or "Heroic"
        local s = self.state
        s.active = true
        s.difficulty_key = key
        s.encounter_start_clock = GetTime()
        s.schedule = {
            bellamy = BuildAbsoluteSchedule("bellamy", s.encounter_start_clock),
            venel   = BuildAbsoluteSchedule("venel",   s.encounter_start_clock),
        }
        s.next_idx     = { bellamy = 1, venel = 1 }
        s.popup_handle = { bellamy = nil, venel = nil }
        if not s.my_assignment then
            s.my_assignment = "bellamy"
            s.my_name = MyFullName()
            VRT:Print("sim: auto-claimed Bellamy for you. Use /vrt lightblinded reset after.")
        end
        ScheduleNextPopup("bellamy")
        ScheduleNextPopup("venel")
        VRT:Print(("Simulating %s encounter — %d+%d Judgments armed (ETEA inert outside real combat)."):format(
            key, #s.schedule.bellamy, #s.schedule.venel))
        return
    end

    if first == "debug" then
        local st = VRT:ModuleSettings("lightblinded")
        st.debug = not st.debug
        VRT:Print("Lightblinded debug: " .. (st.debug and "ON" or "OFF"))
        return
    end

    VRT:Print("unknown subcommand. Try: /vrt lightblinded help")
end

----------------------------------------------------------------------
-- Panel actions (replaces typed slash commands as primary UX)
----------------------------------------------------------------------
M.actions = {
    { label = "Open Assignment", action = function()
        if not assignment_frame then BuildAssignmentFrame() end
        if assignment_frame then assignment_frame:Show(); RefreshAssignmentFrame() end
    end },
    { label = "Test Bellamy", action = function() ShowTauntPopup("bellamy", PRE_WARN_SECONDS) end },
    { label = "Test Venel",   action = function() ShowTauntPopup("venel",   PRE_WARN_SECONDS) end },
    { label = "Sim Heroic", action = function() M:OnSlash("sim heroic") end },
    { label = "Sim Mythic", action = function() M:OnSlash("sim mythic") end },
    { label = "Reset", action = function() M:OnSlash("reset") end },
}

----------------------------------------------------------------------
-- Register with Core
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
