----------------------------------------------------------------------
-- VoidRaidTools — Vorasius (Voidspire 3177) — kick alerts
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. Tank-swap state
-- still lives in VorasiusTanks.lua.
--
-- ⚠ All overrides below are UNVERIFIED — sourced from BigWigs/Wowhead
-- research, never seen in a live ETEA capture. The engine's
-- IsSpellImportant fallback will fire generic alerts for the real IDs.
----------------------------------------------------------------------

local M = {
    id   = "vorasius_alerts",
    name = "Vorasius — Kick + Utility Alerts",
    description = "Role-filtered alerts for Vorasius: DPS get add-kicks, healers get dispels. The Smashing Frenzy tank cycle is in VorasiusTanks.",
    state = { active = false },
}

M.encounter_id = 3177

M.overrides = {
    -- UNVERIFIED
    [1265131] = { priority = "CRITICAL", label = "OOZING SLAM — KICK",        sound = "raid_warning" },
    [1266897] = { priority = "CRITICAL", label = "OVERLOAD — KICK",            sound = "raid_warning" },
    [1266003] = { priority = "MEDIUM",   label = "BACKLASH — KNOCKBACK",       sound = "alarm" },
    [1266001] = { priority = "HIGH",     label = "RIFT MADNESS — SOAK",        sound = "raid_warning" },
    [1268916] = { priority = "MEDIUM",   label = "LIGHT SIPHON — HEAL DEBUFF", sound = "alarm" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
