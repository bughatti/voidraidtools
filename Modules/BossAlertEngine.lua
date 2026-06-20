----------------------------------------------------------------------
-- VoidRaidTools — shared ETEA-driven boss alert engine.
--
-- Every per-boss alert module (Salhadaar.lua, VaelgorEzzorak.lua, etc.)
-- has the same shape: register for ETEA on a specific encounter_id,
-- pull the clean spell_id from C_EncounterEvents, fire an alert. The
-- only difference between modules is the priority overrides table.
--
-- This helper centralizes the wire-up so each boss module is ~20 lines:
--
--   local M = { id="salhadaar", name="Fallen-King Salhadaar", state={} }
--   M.encounter_id = 3179
--   M.overrides = {
--       [1249796] = { priority="HIGH", label="SHATTERED SKY — EXTERNALS",
--                     sound="raid_warning" },
--   }
--   VRT.BossAlertEngine:Attach(M)
--   VRT:RegisterModule(M); return M
--
-- For any cast NOT in the overrides table we still fire a generic alert,
-- gated by C_Spell.IsSpellImportant (Blizzard's curated importance flag),
-- with the spell name resolved at runtime via C_Spell.GetSpellName.
-- That means a boss module ships with zero overrides and will still fire
-- correct alerts the first time we see the boss — it just won't have
-- specific priority labels until we add them.
----------------------------------------------------------------------

local Engine = {}
Engine.attached = {}

local ALERT_COOLDOWN = 2.0

local function fireAlert(module, spell_id)
    local now = GetTime()
    module._last_alert = module._last_alert or {}
    if (module._last_alert[spell_id] or 0) + ALERT_COOLDOWN > now then return end
    module._last_alert[spell_id] = now

    local cfg = module.overrides and module.overrides[spell_id]
    if not cfg then
        -- Generic path: skip if Blizzard doesn't flag this spell as
        -- important. Filters out the dozens of cosmetic / stat-buff
        -- casts that pour through ETEA for every boss.
        if C_Spell and C_Spell.IsSpellImportant then
            local ok, important = pcall(C_Spell.IsSpellImportant, spell_id)
            if not ok or not important then return end
        end
        local name = "Boss cast"
        if C_Spell and C_Spell.GetSpellName then
            local ok, n = pcall(C_Spell.GetSpellName, spell_id)
            if ok and n then name = n end
        end
        cfg = {
            priority = "MEDIUM",
            label    = name:upper(),
            sound    = "alarm",
        }
    end

    -- Route the visible alert through KickRotation's FlashAlert panel —
    -- raid users already have this on-screen during pulls, so it's the
    -- natural canvas for raid-wide alerts.
    local kr = VRT and VRT.modules and VRT.modules.kickrotation
    if kr and kr.FlashAlert then
        kr:FlashAlert(cfg.priority == "CRITICAL" and 4.0 or 3.0, cfg.label)
    else
        -- Fallback: RaidNotice if KickRotation panel isn't loaded.
        if RaidNotice_AddMessage and RaidBossEmoteFrame then
            RaidNotice_AddMessage(RaidBossEmoteFrame, cfg.label,
                ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or {r=1, g=0.5, b=0.5})
        end
    end

    if cfg.sound == "raid_warning" then
        pcall(PlaySoundFile, "Sound/Interface/RaidWarning.ogg", "Master")
    elseif cfg.sound == "alarm" then
        pcall(PlaySoundFile, "Sound/Interface/AlarmClockWarning3.ogg", "Master")
    end
end

local function resolveCleanSpellID(eventInfo)
    if type(eventInfo) ~= "table" then return nil end
    if not eventInfo.id then return nil end
    if not (C_EncounterEvents and C_EncounterEvents.GetEventInfo) then return nil end
    local info = C_EncounterEvents.GetEventInfo(eventInfo.id)
    if info and info.spellID then return info.spellID end
    return nil
end

local function OnEvent(self, event, ...)
    local module = self._vrtModule
    if not module then return end
    if event == "ENCOUNTER_START" then
        local encounterID = ...
        if encounterID == module.encounter_id then
            module.state.active = true
            module._last_alert = {}
        end
    elseif event == "ENCOUNTER_END" then
        local encounterID = ...
        if encounterID == module.encounter_id then
            module.state.active = false
            module._last_alert = {}
        end
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        if not module.state.active then return end
        local sid = resolveCleanSpellID((...))
        if sid then fireAlert(module, sid) end
    end
end

function Engine:Attach(module)
    if Engine.attached[module.id] then return end
    Engine.attached[module.id] = module
    module.state = module.state or {}
    module._frame = CreateFrame("Frame", "VRT_Alert_" .. module.id .. "_Frame")
    module._frame._vrtModule = module
    module._frame:RegisterEvent("ENCOUNTER_START")
    module._frame:RegisterEvent("ENCOUNTER_END")
    module._frame:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED")
    module._frame:SetScript("OnEvent", OnEvent)
end

-- Expose on the global VRT table. Modules pick it up via VRT.BossAlertEngine.
if VRT then
    VRT.BossAlertEngine = Engine
else
    -- Core.lua may not have run yet at module file order time. Create the
    -- VRT table early; Core.lua's later assignment of VRT.modules is
    -- additive, not destructive.
    _G.VRT = _G.VRT or {}
    _G.VRT.BossAlertEngine = Engine
end

return Engine
