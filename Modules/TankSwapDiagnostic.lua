----------------------------------------------------------------------
-- VoidRaidTools — Tank Swap Diagnostic
--
-- Architecture validator. Captures Blizzard event payloads to
-- VoidRaidToolsDB.diagnostics so we can confirm — outside of Voidspire
-- specifically — that the foundational APIs the tank-swap modules
-- depend on actually behave as documented in 12.0.5:
--
--   1. ENCOUNTER_TIMELINE_EVENT_ADDED fires for boss casts; eventInfo
--      payload (source, duration, spellID, spellName) is readable.
--   2. C_UnitAuras.GetAuraDataBySpellName returns valid AuraData with
--      a usable `applications` field for player debuffs.
--   3. C_UnitAuras.AddPrivateAuraAppliedSound is callable + returns a
--      sound ID (or graceful nil).
--   4. ENCOUNTER_START / CHALLENGE_MODE_START dispatch reach modules.
--
-- Capture is automatic; nothing to type. Run any content (M+, LFR,
-- Follower Dungeon, world boss). On /reload, the data is on disk for
-- review. Use the panel "Show Summary" button for an in-game readout.
----------------------------------------------------------------------

local M = {
    state = {
        recording          = true,
        encounter_active   = false,
        current_encounter  = nil,    -- {id=, name=}
        auto_aura_known    = {},     -- spell_id → last-seen applications (dedupe)
    },
}

M.id          = "diagnostic"
M.name        = "Tank Swap Diagnostic"
M.description = "Logs ETEA / aura / encounter events to SavedVariables so we can validate the architecture without needing a Voidspire pull. Run any content; review captures later."
-- Intentionally NO encounter_id — Core dispatches OnEncounterStart to
-- modules without an encounter_id for ALL encounters.

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local CAP_ETEA       = 200       -- last N ETEA events kept
local CAP_ENCOUNTER  = 100       -- last N encounter starts/ends
local CAP_AURA       = 50        -- last N manual aura scans
local CAP_CL         = 50        -- last N challenge-mode starts
local CAP_AUTO_AURAS = 400       -- last N auto-captured aura changes

----------------------------------------------------------------------
-- Forward declarations
-- These functions are defined later in the file but referenced from
-- M:OnInit / OnEncounterStart / OnZoneChanged above their definitions.
-- Without forward declarations Lua resolves them to globals (nil) at
-- the moment OnInit's body runs.
----------------------------------------------------------------------
local CollectSecretsProbe, PrintProbeVerbose
local ProbeSecrets, ProbeSecretsAuto, ProbeSecretReadTest, ShowSecretsProbeLog
-- Trigger label propagated from probe call sites into CollectSecretsProbe.
-- Must be forward-declared too — same Lua scoping reason.
local _next_probe_trigger = "tick"

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function GetStore()
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.diagnostics = VoidRaidToolsDB.diagnostics or {}
    local d = VoidRaidToolsDB.diagnostics
    d.etea_events    = d.etea_events    or {}
    d.encounter_log  = d.encounter_log  or {}
    d.cl_log         = d.cl_log         or {}
    d.aura_scans     = d.aura_scans     or {}
    d.auto_auras     = d.auto_auras     or {}
    d.pa_test        = d.pa_test        or nil
    d.api_status     = d.api_status     or nil
    d.started_at     = d.started_at     or time()
    d.recording      = (d.recording ~= false)  -- default true
    return d
end

local function PushCapped(tbl, entry, cap)
    table.insert(tbl, entry)
    while #tbl > cap do table.remove(tbl, 1) end
end

local function SafeReadField(t, field)
    if not t then return nil, "no_table" end
    -- Distinguish "field actually nil" from "field returned a
    -- secret-tainted value". Both cause the read to be unusable, but
    -- knowing which lets us tell apart "Blizzard didn't populate the
    -- field" vs "the secret-protection system is hiding it from us".
    local ok, val, was_secret = pcall(function()
        local v = t[field]
        if issecretvalue and issecretvalue(v) then return nil, true end
        return v, false
    end)
    if not ok then return nil, "pcall_error" end
    if was_secret then return nil, "secret" end
    if val == nil then return nil, "nil" end
    return val, "ok"
end

local function NowEpoch() return time() end

-- PA Anchor + sound test scaffolding REMOVED 2026-06-05 — architecture
-- validated in M+ Mag Terrace (Gemellus Neural Link icon rendered in
-- the test frame, confirming AddPrivateAuraAnchor pipeline works).
-- StackTankSwap.lua carries the production version of the anchor.

----------------------------------------------------------------------
-- One-shot API + Private-Aura registration test at addon load
----------------------------------------------------------------------
local function RunStartupApiCheck()
    local d = GetStore()
    d.api_status = {
        captured_at = NowEpoch(),
        C_EncounterTimeline = (C_EncounterTimeline and true) or false,
        ETEA_IsFeatureEnabled = (C_EncounterTimeline and C_EncounterTimeline.IsFeatureEnabled
                                  and C_EncounterTimeline.IsFeatureEnabled()) or false,
        ETEA_IsFeatureAvailable = (C_EncounterTimeline and C_EncounterTimeline.IsFeatureAvailable
                                    and C_EncounterTimeline.IsFeatureAvailable()) or false,
        C_UnitAuras = (C_UnitAuras and true) or false,
        GetAuraDataBySpellName = (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName and true) or false,
        AddPrivateAuraAppliedSound = (C_UnitAuras and C_UnitAuras.AddPrivateAuraAppliedSound and true) or false,
        C_ChallengeMode = (C_ChallengeMode and true) or false,
        GetActiveChallengeMapID = (C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID and true) or false,
        issecretvalue_global = (issecretvalue and true) or false,
    }

    -- Try registering a Private Aura sound for an arbitrary tank-swap
    -- spell. Bellamy Judgment is in our codebase and known to use this
    -- mechanism per DBM. Failure indicates the API contract changed.
    if C_UnitAuras and C_UnitAuras.AddPrivateAuraAppliedSound then
        local ok, sound_id = pcall(C_UnitAuras.AddPrivateAuraAppliedSound, {
            spellID       = 1251857,   -- Bellamy Judgment
            unitToken     = "player",
            soundFileName = "Sound\\Interface\\AlarmClockWarning2.ogg",
        })
        d.pa_test = {
            tested_at = NowEpoch(),
            ok = ok and true or false,
            sound_id = (ok and sound_id) or nil,
            err = (not ok) and tostring(sound_id) or nil,
        }
        -- Clean up immediately so we don't double-register
        if ok and sound_id and C_UnitAuras.RemovePrivateAuraAppliedSound then
            pcall(C_UnitAuras.RemovePrivateAuraAppliedSound, sound_id)
        end
    else
        d.pa_test = { tested_at = NowEpoch(), ok = false, err = "API not available" }
    end
end

----------------------------------------------------------------------
-- ETEA observer — capture every encounter timeline event
----------------------------------------------------------------------
function M:OnTimelineEvent(eventInfo)
    local d = GetStore()
    if not d.recording then return end
    if not eventInfo then return end

    local source,    src_status   = SafeReadField(eventInfo, "source")
    local duration,  dur_status   = SafeReadField(eventInfo, "duration")
    local spell_id,  sid_status   = SafeReadField(eventInfo, "spellID")
    local spell_nm,  sn_status    = SafeReadField(eventInfo, "spellName")
    local id_evt,    id_status    = SafeReadField(eventInfo, "id")
    local approx,    appr_status  = SafeReadField(eventInfo, "isApproximate")
    local severity,  sev_status   = SafeReadField(eventInfo, "severity")

    -- BRIDGE TEST: try C_EncounterEvents.GetEventInfo(event_id). If the
    -- timeline's event_id is the same number space as the static
    -- encounter-events database, this returns a struct with a CLEAN
    -- spellID we can use. If it returns nil, the two IDs are different
    -- number spaces and the bridge doesn't exist.
    local ce_status = "not_tried"
    local ce_spell_id = nil
    local ce_spell_id_status = nil
    -- PROBE 4: C_Spell.IsSpellImportant on the clean spell ID we got
    -- from the bridge. If true, Blizzard's UI flags it as important and
    -- shows the ImportantCastFlashAnim. Lets us filter to "definitely
    -- worth alerting" without our own priority table.
    local imp_status = "not_tried"
    local imp_value = nil
    if id_evt and C_EncounterEvents and C_EncounterEvents.GetEventInfo then
        local ok, info = pcall(C_EncounterEvents.GetEventInfo, id_evt)
        if not ok then
            ce_status = "pcall_error"
        elseif info == nil then
            ce_status = "returned_nil"
        else
            ce_status = "returned_info"
            local v
            v, ce_spell_id_status = SafeReadField(info, "spellID")
            ce_spell_id = v
            if ce_spell_id_status == "ok" and ce_spell_id and C_Spell and C_Spell.IsSpellImportant then
                local ok2, important = pcall(C_Spell.IsSpellImportant, ce_spell_id)
                if not ok2 then
                    imp_status = "pcall_error"
                elseif important == nil then
                    imp_status = "nil"
                elseif issecretvalue and issecretvalue(important) then
                    imp_status = "secret"
                else
                    imp_status = "ok"
                    imp_value = important and true or false
                end
            end
        end
    end

    PushCapped(d.etea_events, {
        captured_at      = NowEpoch(),
        event_id         = id_evt,
        event_id_status  = id_status,
        source           = source,
        source_status    = src_status,
        duration         = duration,
        duration_status  = dur_status,
        spell_id         = spell_id,
        spell_id_status  = sid_status,
        spell_name       = spell_nm,
        spell_name_status= sn_status,
        is_approximate   = approx,
        is_approx_status = appr_status,
        severity         = severity,
        severity_status  = sev_status,
        -- Bridge attempt via C_EncounterEvents
        ce_status        = ce_status,
        ce_spell_id      = ce_spell_id,
        ce_spell_id_status = ce_spell_id_status,
        -- PROBE 4: IsSpellImportant on the bridged spell ID
        imp_status       = imp_status,
        imp_value        = imp_value,
    }, CAP_ETEA)
end

----------------------------------------------------------------------
-- Encounter lifecycle taps (no encounter_id filter on M so we see ALL)
----------------------------------------------------------------------
function M:OnEncounterStart(encounterID)
    local d = GetStore()
    if not d.recording then return end
    local name = "?"
    local diff = nil
    if GetInstanceInfo then
        local instName, _, dID = GetInstanceInfo()
        name = instName or "?"
        diff = dID
    end
    PushCapped(d.encounter_log, {
        captured_at    = NowEpoch(),
        event          = "ENCOUNTER_START",
        encounter_id   = encounterID,
        instance_name  = name,
        difficulty_id  = diff,
    }, CAP_ENCOUNTER)

    -- Arm automatic aura capture for the duration of the encounter.
    M.state.encounter_active  = true
    M.state.current_encounter = { id = encounterID, name = name, diff = diff }
    M.state.auto_aura_known   = {}  -- reset dedupe map per encounter

    -- Auto-fire a C_Secrets probe at boss pull — most interesting moment
    -- to see if boss/nameplates become readable or stay fully gated.
    if ProbeSecretsAuto then
        _next_probe_trigger = "encounter_start"
        ProbeSecretsAuto()
    end
end

-- Auto-fire on zone change (capital city, world, instance entry, etc.)
-- so we capture baseline + change-over-time without typing anything.
-- Debounced: PEW + ZONE_CHANGED_NEW_AREA both fire OnZoneChanged within
-- ~50ms, so suppress duplicates within 1s.
local last_zone_probe = 0
function M:OnZoneChanged()
    if not ProbeSecretsAuto then return end
    local now = GetTime()
    if (now - last_zone_probe) < 1.0 then return end
    last_zone_probe = now
    _next_probe_trigger = "zone_change"
    ProbeSecretsAuto()
end

function M:OnEncounterEnd(encounterID, ...)
    local d = GetStore()
    if not d.recording then return end
    PushCapped(d.encounter_log, {
        captured_at    = NowEpoch(),
        event          = "ENCOUNTER_END",
        encounter_id   = encounterID,
        success_arg    = select(1, ...),  -- best-effort capture of varargs
    }, CAP_ENCOUNTER)

    -- Disarm automatic aura capture.
    M.state.encounter_active  = false
    M.state.current_encounter = nil
    M.state.auto_aura_known   = {}
end

----------------------------------------------------------------------
-- Auto aura capture during encounters — hooks UNIT_AURA on player,
-- logs any NEW debuff or any stack-count change. Dedup via spell_id →
-- last-seen applications so we don't spam the log with no-op events.
-- Triggered by Core's UNIT_AURA dispatch (mod.OnUnitAura).
----------------------------------------------------------------------
function M:OnUnitAura(unit)
    if unit ~= "player" then return end
    local d = GetStore()
    if not d.recording then return end
    if not M.state.encounter_active then return end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end

    -- Scan harmful auras; compare against last-seen map.
    local seen_now = {}
    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
        if not ok or not aura then break end
        local sid,    sid_status    = SafeReadField(aura, "spellId")
        local name,   name_status   = SafeReadField(aura, "name")
        local apps_raw, apps_status = SafeReadField(aura, "applications")
        local apps                  = apps_raw or 0
        local dur,    dur_status    = SafeReadField(aura, "duration")
        local source, src_status    = SafeReadField(aura, "sourceUnit")

        -- Dedup by spell_id (fall back to name when spell_id is secret)
        local key = sid or ("name:" .. tostring(name or "?:" .. i))
        seen_now[key] = true
        local last = M.state.auto_aura_known[key]
        if last == nil or last ~= apps then
            local change = (last == nil and "new")
                        or (last < apps and "stack_up")
                        or (last > apps and "stack_down")
                        or "same"
            -- Probe GetAuraDataBySpellName with the captured name (if any)
            -- to verify by-name lookup works even when the AuraData's
            -- name field is secret-protected.
            local by_name_works = nil
            if name and C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
                local ok2, probe = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HARMFUL")
                by_name_works = (ok2 and probe ~= nil) and true or false
            end

            PushCapped(d.auto_auras, {
                captured_at         = NowEpoch(),
                encounter_id        = M.state.current_encounter and M.state.current_encounter.id,
                encounter_name      = M.state.current_encounter and M.state.current_encounter.name,
                spell_id            = sid,
                spell_id_status     = sid_status,
                spell_id_secret     = (sid == nil) and true or false,
                spell_name          = name,
                name_status         = name_status,
                name_secret         = (name == nil) and true or false,
                applications        = apps,
                applications_status = apps_status,   -- "ok" = real 0; "nil_or_secret" = field is hidden
                duration            = dur,
                duration_status     = dur_status,
                source_unit         = source,
                source_status       = src_status,
                change              = change,
                previous_stacks     = last,
                by_name_works       = by_name_works,
            }, CAP_AUTO_AURAS)
            M.state.auto_aura_known[key] = apps
        end
    end

    -- Detect removed auras (in last-seen map but not in current scan)
    for key, last in pairs(M.state.auto_aura_known) do
        if not seen_now[key] then
            PushCapped(d.auto_auras, {
                captured_at     = NowEpoch(),
                encounter_id    = M.state.current_encounter and M.state.current_encounter.id,
                encounter_name  = M.state.current_encounter and M.state.current_encounter.name,
                spell_id        = (type(key) == "number") and key or nil,
                spell_name      = (type(key) == "string") and key:gsub("^name:", "") or nil,
                applications    = 0,
                change          = "removed",
                previous_stacks = last,
            }, CAP_AUTO_AURAS)
            M.state.auto_aura_known[key] = nil
        end
    end
end

----------------------------------------------------------------------
-- CHALLENGE_MODE_START tap — verify our PEW backfill is unneeded
-- (i.e., the event actually fires for joined-in-progress runs).
----------------------------------------------------------------------
local function HookChallengeStart()
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHALLENGE_MODE_START")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event)
        local d = GetStore()
        if not d.recording then return end
        if event == "CHALLENGE_MODE_START" then
            local name, mapID, diff
            if GetInstanceInfo then name, _, diff = GetInstanceInfo() end
            if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
                mapID = C_ChallengeMode.GetActiveChallengeMapID()
            end
            PushCapped(d.cl_log, {
                captured_at   = NowEpoch(),
                event         = "CHALLENGE_MODE_START",
                instance_name = name,
                map_id        = mapID,
                difficulty_id = diff,
            }, CAP_CL)
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Quick check: are we IN an active challenge but no
            -- CHALLENGE_MODE_START arrived? Capture so we can see how
            -- often the backfill path is needed.
            C_Timer.After(2, function()
                if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
                    local mapID = C_ChallengeMode.GetActiveChallengeMapID()
                    if mapID and mapID ~= 0 then
                        local name, diff
                        if GetInstanceInfo then name, _, diff = GetInstanceInfo() end
                        PushCapped(d.cl_log, {
                            captured_at   = NowEpoch(),
                            event         = "PEW_IN_ACTIVE_M_PLUS",
                            instance_name = name,
                            map_id        = mapID,
                            difficulty_id = diff,
                        }, CAP_CL)
                    end
                end
            end)
        end
    end)
end

----------------------------------------------------------------------
-- Manual aura scan — iterates player debuffs + reports stacks
----------------------------------------------------------------------
local function ScanPlayerAurasNow()
    local d = GetStore()
    local found = {}

    -- Use the modern API if available; fall back to legacy UnitAura.
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
            if not ok or not aura then break end
            local nm, ok_nm = SafeReadField(aura, "name")
            local sid       = SafeReadField(aura, "spellId")
            local apps      = SafeReadField(aura, "applications")
            local dur       = SafeReadField(aura, "duration")
            table.insert(found, {
                idx       = i,
                name      = nm or "<secret>",
                spell_id  = sid,
                stacks    = apps or 0,
                duration  = dur,
            })
        end
    end

    -- Also probe by-name for our known tank-swap debuff names so we
    -- can verify GetAuraDataBySpellName returns sensibly.
    local probes = { "Blackening Wounds", "Destabilizing Strikes",
                     "Smashed", "Rift Slash", "Rakfang", "Vaelwing" }
    local probe_results = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
        for _, n in ipairs(probes) do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", n, "HARMFUL")
            table.insert(probe_results, {
                probe = n,
                ok = ok and true or false,
                found = (ok and aura) and true or false,
                stacks = (ok and aura) and SafeReadField(aura, "applications") or nil,
            })
        end
    end

    PushCapped(d.aura_scans, {
        captured_at   = NowEpoch(),
        all_harmful   = found,
        named_probes  = probe_results,
    }, CAP_AURA)

    -- Print live summary so the user doesn't need a reload to see it.
    VRT:Print(("Aura scan: %d HARMFUL aura(s) on player. %d known tank-debuff probes ran. Stored in SavedVariables."):format(
        #found, #probe_results))
    for _, p in ipairs(probe_results) do
        if p.found then
            print(("  |cffff8040FOUND|r %s (%d stacks)"):format(p.probe, p.stacks or 0))
        end
    end
end

----------------------------------------------------------------------
-- In-game summary (button-driven; no typing)
----------------------------------------------------------------------
local function PrintSummary()
    local d = GetStore()
    VRT:Print("Diagnostic summary:")
    local last_etea = d.etea_events[#d.etea_events]
    print(("  ETEA events captured: %d %s"):format(
        #d.etea_events,
        last_etea and ("(last at " .. date("%H:%M:%S", last_etea.captured_at) .. ")") or "(none)"
    ))

    local sid_readable, sid_secret = 0, 0
    for _, e in ipairs(d.etea_events) do
        if e.spell_id then sid_readable = sid_readable + 1
        else sid_secret = sid_secret + 1 end
    end
    print(("    spellID readable: |cff20ff20%d|r   |   spellID secret: |cffff5050%d|r"):format(sid_readable, sid_secret))

    print(("  Encounter events: %d"):format(#d.encounter_log))
    print(("  Challenge-mode events: %d"):format(#d.cl_log))
    print(("  Manual aura scans: %d"):format(#d.aura_scans))
    print(("  Auto aura captures (during encounters): %d"):format(#d.auto_auras))

    if d.pa_test then
        local color = d.pa_test.ok and "|cff20ff20OK|r" or "|cffff5050FAILED|r"
        print(("  Private Aura registration test: %s  sound_id=%s"):format(
            color, tostring(d.pa_test.sound_id or "nil")))
    end

    if d.api_status then
        local function yn(b) return b and "|cff20ff20Y|r" or "|cffff5050N|r" end
        print(("  APIs:  C_EncounterTimeline=%s  IsFeatureEnabled=%s  GetAuraDataBySpellName=%s  AddPrivateAuraAppliedSound=%s"):format(
            yn(d.api_status.C_EncounterTimeline),
            yn(d.api_status.ETEA_IsFeatureEnabled),
            yn(d.api_status.GetAuraDataBySpellName),
            yn(d.api_status.AddPrivateAuraAppliedSound)))
    end

    local rec = d.recording and "|cff20ff20ON|r" or "|cffff5050OFF|r"
    print(("  Recording: %s   |   /reload to flush to disk for review"):format(rec))
end

local function ClearLog()
    VoidRaidToolsDB = VoidRaidToolsDB or {}
    VoidRaidToolsDB.diagnostics = {
        started_at = time(),
        recording = true,
        etea_events = {},
        encounter_log = {},
        cl_log = {},
        aura_scans = {},
        auto_auras = {},
        pa_test = nil,
        api_status = nil,
    }
    -- Re-run startup probe so we always have current API status.
    RunStartupApiCheck()
    VRT:Print("Diagnostic log cleared. Startup API probe re-run.")
end

local function ToggleRecording()
    local d = GetStore()
    d.recording = not d.recording
    VRT:Print("Diagnostic recording: " .. (d.recording and "|cff20ff20ON|r" or "|cffff5050OFF|r"))
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    RunStartupApiCheck()
    HookChallengeStart()
    local d = GetStore()
    VRT:Print(("|cff8c40ffDiagnostic|r recording (%d entries)."):format(
        #d.etea_events + #d.encounter_log + #d.cl_log + #d.aura_scans + (#d.auto_auras or 0)))

    -- (Taint Test button was here — removed. Sibling-addon architecture
    -- has been verified across many pulls; the visible yellow-bordered
    -- button at screen center was just for the original verification.)

    -- VRT-Reader sibling addon listener.
    --
    -- VRT-Reader broadcasts hostile cast snapshots on the "VRT_R" addon
    -- prefix via WHISPER-to-self. We REGISTER + LISTEN ONLY here. No
    -- decisions, no popups, no actions. Pure data collection. The test
    -- objective: confirm VRT's secure buttons keep working while we
    -- receive these messages, AND collect what VRT-Reader actually saw.
    d.reader_events = d.reader_events or {}
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix("VRT_R")
    end
    local reader_recv_count = 0
    local reader_frame = CreateFrame("Frame", "VRT_Diag_ReaderListener")
    reader_frame:RegisterEvent("CHAT_MSG_ADDON")
    reader_frame:SetScript("OnEvent", function(_, _, prefix, payload, channel, sender)
        if prefix ~= "VRT_R" then return end
        local kind, body = payload:match("^([^|]+)|(.*)$")
        reader_recv_count = reader_recv_count + 1
        -- POLY ALERT — superseded by MarkerKickAlert (precise: alerts
        -- ONLY when a marked nameplate starts casting, no heuristics).
        -- The Reader still emits POLY_INCOMING from its count-based AB
        -- prediction; we accept and silently drop it. No flash, no sound.
        if kind == "POLY_INCOMING" then
            return
        end
        -- Silently record everything else (no chat print)
        if not d.recording then return end
        PushCapped(d.reader_events, {
            at = NowEpoch(),
            kind = kind,
            body = body,
            channel = channel,
            sender = sender,
            in_combat = InCombatLockdown and InCombatLockdown() or false,
        }, 500)
    end)

    -- One-shot C_EncounterEvents probe at boot — collect the static
    -- encounter-events database stats so we know what to look for in
    -- the bridge correlation.
    d.encounter_events_db = d.encounter_events_db or {}
    if C_EncounterEvents and C_EncounterEvents.GetEventList then
        local ok, list = pcall(C_EncounterEvents.GetEventList)
        if ok and type(list) == "table" then
            d.encounter_events_db.list_count = #list
            d.encounter_events_db.list_sample = {}
            for i = 1, math.min(20, #list) do
                local id = list[i]
                local entry = { id = id }
                if C_EncounterEvents.GetEventInfo then
                    local ok2, info = pcall(C_EncounterEvents.GetEventInfo, id)
                    if ok2 and info then
                        local sid, sid_st = SafeReadField(info, "spellID")
                        local enabled, en_st = SafeReadField(info, "enabled")
                        entry.spell_id = sid
                        entry.spell_id_status = sid_st
                        entry.enabled = enabled
                        entry.enabled_status = en_st
                    else
                        entry.info_status = ok2 and "nil" or "pcall_error"
                    end
                end
                d.encounter_events_db.list_sample[i] = entry
            end
            VRT:Print(("|cff8c40ffDiagnostic|r C_EncounterEvents.GetEventList() returned %d IDs (sample stored)."):format(#list))
        else
            d.encounter_events_db.error = ok and "not_a_table" or "pcall_error"
            VRT:Print("|cff8c40ffDiagnostic|r C_EncounterEvents.GetEventList() failed or returned non-table.")
        end
    else
        d.encounter_events_db.error = "api_missing"
    end

    -- Hook UNIT_AURA on player to capture aura changes during combat.
    -- For each fire, walk the populated slots and check if any have
    -- ShouldUnitAuraIndexBeSecret == false (which would mean we CAN
    -- read that specific slot even though the global flag says secret).
    d.unit_aura_log = d.unit_aura_log or {}
    local aura_frame = CreateFrame("Frame")
    aura_frame:RegisterUnitEvent("UNIT_AURA", "player")
    aura_frame:SetScript("OnEvent", function(_, _, unit, updateInfo)
        if unit ~= "player" then return end
        if not d.recording then return end
        local cs = _G.C_Secrets
        local entry = {
            captured_at = NowEpoch(),
            in_combat   = InCombatLockdown and InCombatLockdown() or false,
            slots_checked = 0,
            slots_safe    = 0,
            safe_slots    = {},  -- slot indices that came back safe
        }
        if cs and cs.ShouldUnitAuraIndexBeSecret then
            for i = 1, 20 do
                local v = cs.ShouldUnitAuraIndexBeSecret("player", i, "HARMFUL")
                if v ~= nil then
                    entry.slots_checked = entry.slots_checked + 1
                    if v == false then
                        entry.slots_safe = entry.slots_safe + 1
                        entry.safe_slots[#entry.safe_slots + 1] = i
                    end
                end
            end
        end
        -- If updateInfo carries spellID for added auras, try to read it
        if updateInfo and type(updateInfo) == "table" then
            local added = updateInfo.addedAuras
            if type(added) == "table" and #added > 0 then
                local a = added[1]
                local sid, sid_st = SafeReadField(a, "spellId")
                entry.added_spell_id = sid
                entry.added_spell_id_status = sid_st
            end
        end
        PushCapped(d.unit_aura_log, entry, 200)
    end)

    -- Auto-probe ticker — fires every 10s while in any instance (was 30s;
    -- shortened so we catch combat-state transitions faster).
    local last_probe = 0
    local ticker_frame = CreateFrame("Frame")
    ticker_frame:SetScript("OnUpdate", function(_, dt)
        last_probe = last_probe + dt
        if last_probe < 10 then return end
        last_probe = 0
        if not IsInInstance then return end
        local inI = IsInInstance()
        if not inI then return end
        if ProbeSecretsAuto then
            _next_probe_trigger = "tick"
            ProbeSecretsAuto()
        end
    end)

    -- Combat-state hooks — capture the moment combat starts and ends, since
    -- the secret-protection predicate flips with combat state. These are
    -- the most valuable probe moments for analyzing the data.
    local combat_frame = CreateFrame("Frame")
    combat_frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    combat_frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    combat_frame:SetScript("OnEvent", function(_, event)
        if not ProbeSecretsAuto then return end
        _next_probe_trigger = (event == "PLAYER_REGEN_DISABLED") and "combat_start" or "combat_end"
        ProbeSecretsAuto()
        -- Combat-start: schedule a follow-up probe 3s in, when auras
        -- have settled. The "moment of pull" probe captures the flip;
        -- the +3s probe captures stable mid-fight state.
        if event == "PLAYER_REGEN_DISABLED" then
            C_Timer.After(3, function()
                _next_probe_trigger = "combat_3s"
                if ProbeSecretsAuto then ProbeSecretsAuto() end
            end)
        end
    end)

    -- Fire one probe at login too — baseline before any zoning.
    C_Timer.After(2, function()
        if ProbeSecretsAuto then
            _next_probe_trigger = "boot"
            ProbeSecretsAuto()
        end
    end)
end

----------------------------------------------------------------------
-- Panel actions (button-driven; no typed commands per user feedback)
----------------------------------------------------------------------
----------------------------------------------------------------------
-- C_Secrets predicate probe — verify the pre-check API exists and
-- returns sensible values for current context.
--
-- Reads ONLY C_Secrets.* — never touches UnitCastingInfo etc. So this
-- itself is taint-free regardless of result.
--
-- Mode "verbose": full output to chat (button press / manual review).
-- Mode "auto":    silent unless something interesting happens. Stores
--                 result to SavedVariables for later inspection.
----------------------------------------------------------------------
local CAP_SECRETS_PROBE = 60   -- last N probes kept

function CollectSecretsProbe()
    local cs = _G.C_Secrets
    if not cs then return nil end
    local probe = {
        at          = time(),
        trigger     = _next_probe_trigger,
        in_combat   = InCombatLockdown and InCombatLockdown() or false,
        zone        = GetZoneText and GetZoneText() or "?",
        instance_type = nil, difficulty = nil, difficulty_id = nil,
        global = {
            hasRestrict = cs.HasSecretRestrictions and cs.HasSecretRestrictions(),
            auras       = cs.ShouldAurasBeSecret    and cs.ShouldAurasBeSecret(),
            cooldowns   = cs.ShouldCooldownsBeSecret and cs.ShouldCooldownsBeSecret(),
            stats       = cs.ShouldUnitStatsBeSecret and cs.ShouldUnitStatsBeSecret(),
        },
        units = {},
        nameplates = { total = 0, all_secret = 0, partially_safe = 0, safe_examples = {} },
    }
    if IsInInstance and GetInstanceInfo then
        local inI, itype = IsInInstance()
        if inI then
            local _, _, diffID, diffName = GetInstanceInfo()
            probe.instance_type = itype
            probe.difficulty    = diffName
            probe.difficulty_id = diffID
        end
    end
    local function unitData(unit)
        if not UnitExists(unit) then return nil end
        local d = {
            identity = cs.ShouldUnitIdentityBeSecret    and cs.ShouldUnitIdentityBeSecret(unit),
            cast     = cs.ShouldUnitSpellCastingBeSecret and cs.ShouldUnitSpellCastingBeSecret(unit),
            hp       = cs.ShouldUnitHealthMaxBeSecret    and cs.ShouldUnitHealthMaxBeSecret(unit),
            power    = cs.ShouldUnitPowerBeSecret        and cs.ShouldUnitPowerBeSecret(unit),
        }
        -- Per-aura predicate sweep: walk first 20 slots in each filter
        -- and count how many are readable (predicate returns false).
        -- This is the data that decides if post-cast detection works
        -- during combat — the global flag is a heuristic, per-index is
        -- the actual gate.
        if cs.ShouldUnitAuraIndexBeSecret then
            local harm_safe, harm_total = 0, 0
            local help_safe, help_total = 0, 0
            for i = 1, 20 do
                local h = cs.ShouldUnitAuraIndexBeSecret(unit, i, "HARMFUL")
                if h ~= nil then
                    harm_total = harm_total + 1
                    if h == false then harm_safe = harm_safe + 1 end
                end
                local f = cs.ShouldUnitAuraIndexBeSecret(unit, i, "HELPFUL")
                if f ~= nil then
                    help_total = help_total + 1
                    if f == false then help_safe = help_safe + 1 end
                end
            end
            d.harm_safe = harm_safe
            d.harm_total = harm_total
            d.help_safe = help_safe
            d.help_total = help_total
            -- Keep slot 1 individual for the one-liner format
            d.aura_harmful_1 = cs.ShouldUnitAuraIndexBeSecret(unit, 1, "HARMFUL")
            d.aura_helpful_1 = cs.ShouldUnitAuraIndexBeSecret(unit, 1, "HELPFUL")
        end
        return d
    end
    for _, u in ipairs({ "player", "target", "boss1", "boss2", "boss3",
                          "party1", "party2", "party3", "party4" }) do
        local d = unitData(u)
        if d then probe.units[u] = d end
    end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            probe.nameplates.total = probe.nameplates.total + 1
            local d = unitData(unit)
            if d then
                local any_safe = (d.identity == false) or (d.cast == false)
                if any_safe then
                    probe.nameplates.partially_safe = probe.nameplates.partially_safe + 1
                    if #probe.nameplates.safe_examples < 5 then
                        local ok, name = pcall(UnitName, unit)
                        probe.nameplates.safe_examples[#probe.nameplates.safe_examples + 1] = {
                            unit = unit,
                            identity = d.identity, cast = d.cast,
                            -- Capture name only if predicate says identity is safe
                            name = (d.identity == false and ok) and tostring(name) or nil,
                        }
                    end
                elseif d.identity and d.cast then
                    probe.nameplates.all_secret = probe.nameplates.all_secret + 1
                end
            end
        end
    end
    return probe
end

function PrintProbeVerbose(p)
    if not p then
        VRT:Print("|cffff5555C_Secrets API not present.|r")
        return
    end
    print("|cff00c7ff[VRT/Secrets]|r ====== probe @ " .. date("%H:%M:%S", p.at) .. " ======")
    print(("  zone=%s | instance=%s | difficulty=%s"):format(
        p.zone or "?", tostring(p.instance_type or "none"), tostring(p.difficulty or "-")))
    print(("  global: hasRestrict=%s | auras=%s | cooldowns=%s | stats=%s"):format(
        tostring(p.global.hasRestrict), tostring(p.global.auras),
        tostring(p.global.cooldowns), tostring(p.global.stats)))
    for _, u in ipairs({ "player", "target", "boss1", "boss2", "boss3",
                          "party1", "party2", "party3", "party4" }) do
        local d = p.units[u]
        if d then
            print(("  %-12s identity=%-5s cast=%-5s hp=%-5s pwr=%-5s harm-aura=%s help-aura=%s"):format(
                u, tostring(d.identity), tostring(d.cast),
                tostring(d.hp), tostring(d.power),
                tostring(d.aura_harmful_1), tostring(d.aura_helpful_1)))
        end
    end
    print(("  nameplates: total=%d  all-secret=%d  partially-safe=%d"):format(
        p.nameplates.total, p.nameplates.all_secret, p.nameplates.partially_safe))
    for _, ex in ipairs(p.nameplates.safe_examples) do
        print(("    %-12s identity=%-5s cast=%-5s  name=%s   <-- SAFE"):format(
            ex.unit, tostring(ex.identity), tostring(ex.cast), ex.name or "(hidden)"))
    end
    if p.nameplates.partially_safe > 0 then
        print("|cffffd700TIP:|r Press 'Probe Read Test' next, then try your VRT taunt key.")
    end
end

local function StoreProbe(p)
    if not p then return end
    local d = GetStore()
    d.secrets_probes = d.secrets_probes or {}
    PushCapped(d.secrets_probes, p, CAP_SECRETS_PROBE)
end

function ProbeSecrets()
    local p = CollectSecretsProbe()
    PrintProbeVerbose(p)
    StoreProbe(p)
end

-- Auto-probe — fires on PEW + ENCOUNTER_START + periodic in instance.
-- Stores every probe and prints a one-liner so the user can see it working
-- and watch values change as they move between contexts.
local last_auto_zone = nil
local probe_api_warned = false
function ProbeSecretsAuto()
    local cs = _G.C_Secrets
    if not cs then
        if not probe_api_warned then
            VRT:Print("|cffff5555[Secrets]|r C_Secrets global not present in this client. The API is documented in the 12.0.5 source mirror but may not be exposed at runtime. Auto-probe disabled.")
            probe_api_warned = true
        end
        return
    end
    -- Verify at least one expected function exists
    if not cs.ShouldUnitSpellCastingBeSecret then
        if not probe_api_warned then
            VRT:Print("|cffff5555[Secrets]|r C_Secrets exists but ShouldUnitSpellCastingBeSecret is missing. Partial API only — auto-probe disabled.")
            probe_api_warned = true
        end
        return
    end
    local p = CollectSecretsProbe()
    if not p then
        VRT:Print("|cffff5555[Secrets]|r CollectSecretsProbe returned nil even though C_Secrets is present. Internal error.")
        return
    end
    StoreProbe(p)
    local zone_changed = (p.zone ~= last_auto_zone)
    last_auto_zone = p.zone

    local g = p.global
    local instLabel = p.instance_type and ("%s/%s"):format(p.instance_type, p.difficulty or "?") or "world"
    local marker
    if p.nameplates.partially_safe > 0 then
        marker = "|cffffd700** SAFE FOUND **|r"
    elseif p.nameplates.total > 0 and p.nameplates.all_secret == p.nameplates.total then
        marker = "|cffff8080all secret|r"
    elseif p.nameplates.total == 0 then
        marker = "|cff808080no hostiles|r"
    else
        marker = "mixed"
    end

    -- Always print a one-liner so testing has visible confirmation.
    -- player aura counts: how many slots are safe out of N populated?
    -- Drives the post-cast detection + broadcast feasibility decision.
    local pd = p.units["player"]
    local pAura = "?"
    if pd then
        pAura = ("%d/%d"):format(pd.harm_safe or 0, pd.harm_total or 0)
    end
    -- Silenced: the C_Secrets probe spam was useful during taint
    -- discovery but the gate is now proven total. See
    -- [[wow-12-secret-spellid-impossible]]. Data still recorded in
    -- secrets_probes table for forensic review; no chat output.
end

----------------------------------------------------------------------
-- Read test — actually call UnitCastingInfo on a nameplate that the
-- predicate says is safe. After this, immediately try one of VRT's
-- secure buttons (e.g. taunt). If it fires, the pre-check pattern is
-- safe. If "blocked from action" appears, the predicate didn't protect
-- us.
--
-- This will only read from a unit where ShouldUnitSpellCastingBeSecret
-- returned false. If no such unit exists, it bails without reading.
----------------------------------------------------------------------
function ProbeSecretReadTest()
    local cs = _G.C_Secrets
    if not cs or not cs.ShouldUnitSpellCastingBeSecret then
        VRT:Print("|cffff5555C_Secrets.ShouldUnitSpellCastingBeSecret missing.|r")
        return
    end
    local target_unit
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            if cs.ShouldUnitSpellCastingBeSecret(unit) == false then
                target_unit = unit
                break
            end
        end
    end
    if not target_unit then
        VRT:Print("No hostile nameplate where casting is non-secret. Walk into a wider area / different content and retry.")
        return
    end
    print(("|cff00c7ff[VRT/Secrets]|r Reading UnitCastingInfo on %s (predicate said SAFE)..."):format(target_unit))
    local name, _, _, _, _, _, _, notInt, spellID = UnitCastingInfo(target_unit)
    print(("  name=%s spellID=%s notInt=%s"):format(
        tostring(name), tostring(spellID), tostring(notInt)))
    print("|cffffd700CRITICAL TEST:|r now try to press your VRT taunt key. If the button fires normally, pre-check protects us. If 'blocked from action' pop-up appears, the predicate was insufficient.")

    local d = GetStore()
    d.last_secrets_read_test = {
        at = time(), unit = target_unit,
        name = name and tostring(name), spellID = spellID and tostring(spellID),
        zone = GetZoneText and GetZoneText() or "?",
    }
end

function ShowSecretsProbeLog()
    local d = GetStore()
    local list = d.secrets_probes or {}
    if #list == 0 then
        VRT:Print("|cff00c7ff[VRT/Secrets]|r no auto-probes yet. Zone into Silvermoon / a Follower Dungeon / etc. to populate.")
        return
    end
    VRT:Print(("Secrets probes captured: %d (showing last 8)"):format(#list))
    local start = math.max(1, #list - 7)
    for i = start, #list do
        local p = list[i]
        local marker = (p.nameplates.partially_safe > 0) and "|cffffd700**SAFE FOUND**|r" or "all-secret"
        print(("  [%s] %s (%s) — np total=%d safe=%d  %s"):format(
            date("%H:%M:%S", p.at), p.zone or "?",
            p.difficulty or p.instance_type or "outside", p.nameplates.total,
            p.nameplates.partially_safe, marker))
        for _, ex in ipairs(p.nameplates.safe_examples) do
            print(("    %-12s identity=%-5s cast=%-5s  name=%s"):format(
                ex.unit, tostring(ex.identity), tostring(ex.cast), ex.name or "(hidden)"))
        end
    end
end

M.actions = {
    { label = "Show Summary",         action = PrintSummary },
    { label = "Scan My Auras Now",    action = ScanPlayerAurasNow },
    { label = "Probe C_Secrets Now",  action = ProbeSecrets },
    { label = "View Probe Log",       action = ShowSecretsProbeLog },
    { label = "Read Test (after probe finds SAFE)", action = ProbeSecretReadTest },
    { label = "Toggle Recording",     action = ToggleRecording },
    { label = "Clear Log",            action = ClearLog },
}

----------------------------------------------------------------------
-- Slash (silent fallback only)
----------------------------------------------------------------------
function M:OnSlash(args)
    args = (args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if args == "" or args == "summary" then PrintSummary(); return end
    if args == "scan" then ScanPlayerAurasNow(); return end
    if args == "clear" then ClearLog(); return end
    if args == "toggle" then ToggleRecording(); return end
    if args == "secrets" or args == "probe" then ProbeSecrets(); return end
    if args == "readtest" then ProbeSecretReadTest(); return end
    VRT:Print("Diagnostic: use the panel (minimap icon) — buttons are the primary UI.")
end

----------------------------------------------------------------------
-- Register — gated behind VoidRaidToolsDB.settings.debug.
-- Default install does NOT load this 1k-line capture module. Enable
-- with `/run VoidRaidToolsDB.settings = VoidRaidToolsDB.settings or {};
-- VoidRaidToolsDB.settings.debug = true` then /reload.
----------------------------------------------------------------------
local function isDebugEnabled()
    return VoidRaidToolsDB
        and VoidRaidToolsDB.settings
        and VoidRaidToolsDB.settings.debug == true
end

if VRT and VRT.RegisterModule and isDebugEnabled() then
    VRT:RegisterModule(M)
end
