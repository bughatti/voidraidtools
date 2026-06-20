----------------------------------------------------------------------
-- VoidRaidTools — MarkerKickAlert
--
-- Silent until we KNOW it's the important cast.
--
-- A marked nameplate starts casting → we say nothing.
-- Cast time reaches 2.7s and still going → we know it can't be Arcane
-- Bolt (max 2.5s). It IS Polymorph (3.5s) or Terror Wave (4.0s) or
-- any other 3s+ cast. NOW the alert fires: panel flash + RaidWarning
-- sound. DPS hears the sound, kicks. Tank's reflex kick on the
-- earlier short casts is unaided — they don't need help.
--
-- Why this is the right design:
--   - Tanks reflex-kick every cast on instinct, addon can't help them
--   - DPS save kicks for the spell that matters
--   - The 2.7s threshold IS that signal — first 2.7s of every cast is
--     "could be anything, don't react." After 2.7s, we know.
--
-- The threshold:
--   Arcane Bolt   = 2.5s (kick if you want — Bolt fires no alert)
--   Polymorph     = 3.5s (alert at 2.7s — 0.8s remaining to kick)
--   Terror Wave   = 4.0s (alert at 2.7s — 1.3s remaining to kick)
--
-- Marker detection uses the clean predicate:
--   type(GetRaidTargetIndex(unit)) == "number"
-- which doesn't trip the secret-value gate (type() is C-side builtin,
-- and string equality on the type-name is clean).
----------------------------------------------------------------------

local M = {
    id   = "markerkickalert",
    name = "Marker Kick Alert",
    description = "Critical kick alert that fires ONLY when a raid-marked mob (star, circle, etc.) starts an interruptible cast that survives past the 2.7s noise threshold (= confirmed important). Filters out DBM's everyone-gets-every-kickable-cast spam — only YOUR assigned target pings you.",
}

local BOLT_MAX_DURATION = 2.7        -- seconds — past this, it's not Bolt
local ALERT_COOLDOWN    = 2.0        -- per-unit gate against duplicate fires

local active_casts        = {}       -- nameplate token -> { start = gt, fired = bool }
local last_alert          = {}
local active_fingerprints = {}       -- "elite/nil" → count of marked mobs with this signature

----------------------------------------------------------------------
-- Fingerprinting — the "second Magister" fix.
--
-- We can only mark ONE mob per priority via /tm (engine-side /targetexact
-- picks closest match, and the Lua-walker alternative tainted /tm). But
-- our alert layer doesn't care about the visible marker — it just needs
-- a "this is a priority" signal.
--
-- So: when a marker IS placed on a hostile mob, we compute its fingerprint
-- ("elite/nil" for humanoid Magister, "elite/string" for non-humanoid
-- Void Infuser etc.) and add it to active_fingerprints. Then any
-- nameplate that matches the same fingerprint counts as a priority,
-- even if it has no physical marker.
--
-- Reading UnitClassification / UnitCreatureFamily on hostile mobs CAN
-- propagate secret-value taint — but this module has no secure actions,
-- nothing to break. Taint here is harmless.
----------------------------------------------------------------------

local function getFingerprint(unit)
    if not UnitExists(unit) then return nil end
    if not UnitCanAttack("player", unit) then return nil end
    local cls = UnitClassification(unit)
    if cls ~= "elite" then return nil end  -- only elites matter for our priority set
    local family_type = type((UnitCreatureFamily(unit)))
    return cls .. "/" .. family_type
end

local function refreshFingerprints()
    -- Rebuild from scratch every event. Cheap (≤40 nameplates) and
    -- guarantees stale fingerprints (from killed mobs) don't linger.
    active_fingerprints = {}
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and type(GetRaidTargetIndex(u)) == "number" then
            local fp = getFingerprint(u)
            if fp then
                active_fingerprints[fp] = (active_fingerprints[fp] or 0) + 1
            end
        end
    end
end

local function isPriority(unit)
    -- Marked → priority (most common case)
    if type(GetRaidTargetIndex(unit)) == "number" then return true end
    -- Fingerprint match against a marked mob → also priority
    local fp = getFingerprint(unit)
    if fp and active_fingerprints[fp] then return true end
    return false
end

local function fireAlert(unit)
    local gt = GetTime()
    if (last_alert[unit] or 0) + ALERT_COOLDOWN > gt then return end
    last_alert[unit] = gt
    -- Visual flash + RaidWarning sound. The hearable component is the
    -- whole point — DPS knows the cast they were ignoring is now the
    -- one to kick.
    local kr = VRT and VRT.modules and VRT.modules.kickrotation
    if kr and kr.FlashAlert then
        kr:FlashAlert(3.0)
    end
    pcall(PlaySoundFile, "Sound/Interface/RaidWarning.ogg", "Master")
end

local function onCastStart(unit)
    if type(unit) ~= "string" then return end
    if not unit:find("^nameplate") then return end
    if not UnitExists(unit) then return end
    if not UnitCanAttack("player", unit) then return end
    if not isPriority(unit) then return end

    -- Record the cast but DON'T alert. The escalation ticker decides
    -- whether this cast is the one to call out.
    active_casts[unit] = { start = GetTime(), fired = false }
end

local function onCastEnd(unit)
    if type(unit) ~= "string" then return end
    active_casts[unit] = nil
end

----------------------------------------------------------------------
-- Escalation ticker — checks active casts every ~0.1s for the
-- "survived past Bolt's max" condition.
----------------------------------------------------------------------
local function checkEscalations()
    local now = GetTime()
    for unit, cast in pairs(active_casts) do
        if not cast.fired and (now - cast.start) >= BOLT_MAX_DURATION then
            cast.fired = true
            fireAlert(unit)
        end
    end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local frame
local ticker

local function OnEvent(_, event, unit)
    if event == "UNIT_SPELLCAST_START"
       or event == "UNIT_SPELLCAST_CHANNEL_START" then
        onCastStart(unit)
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_FAILED" then
        onCastEnd(unit)
    elseif event == "RAID_TARGET_UPDATE"
        or event == "NAME_PLATE_UNIT_ADDED"
        or event == "NAME_PLATE_UNIT_REMOVED" then
        refreshFingerprints()
    elseif event == "PLAYER_REGEN_ENABLED" then
        active_casts        = {}
        last_alert          = {}
        active_fingerprints = {}
    end
end

function M:OnInit()
    if frame then return end
    frame = CreateFrame("Frame", "VRT_MarkerKickAlertFrame")
    for _, ev in ipairs({
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_STOP",  "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED",
        "UNIT_SPELLCAST_FAILED", "PLAYER_REGEN_ENABLED",
        "RAID_TARGET_UPDATE", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
    }) do
        frame:RegisterEvent(ev)
    end
    frame:SetScript("OnEvent", OnEvent)

    -- Escalation ticker — 100ms cadence is plenty (Bolt is 2.5s).
    ticker = C_Timer.NewTicker(0.1, checkEscalations)
end

function M:OnUnitAura(unit) end -- noop, kept for Core dispatch compat

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
