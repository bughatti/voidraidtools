----------------------------------------------------------------------
-- VoidRaidTools — Crown of the Cosmos (Voidspire end-boss, 3181)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. Alleria +
-- Morium/Demiar/Vorelus.
--
-- ⚠ Overrides below are UNVERIFIED — promote/demote after first pull.
----------------------------------------------------------------------

local M = {
    id   = "crown_alerts",
    name = "Crown of the Cosmos — Alerts",
    description = "Role-filtered alerts for Crown of the Cosmos (Alleria phase): DPS get add kicks + Aspect-of-the-End tethers, healers get dispels, tanks get external requests.",
    state = { active = false },
}

M.encounter_id = 3181

M.overrides = {
    [1243743] = { priority = "CRITICAL", label = "INTERRUPTING TREMOR — KICK", sound = "raid_warning" },
    [1255368] = { priority = "HIGH",     label = "VOID EXPULSION — KICK",       sound = "raid_warning" },
    [1246918] = { priority = "HIGH",     label = "COSMIC BARRIER — BURN PHASE", sound = "raid_warning" },
    [1233865] = { priority = "HIGH",     label = "NULL CORONA — DISPEL",        sound = "raid_warning" },
    [1233787] = { priority = "HIGH",     label = "DARK HAND — TANK",            sound = "raid_warning" },
    [1246461] = { priority = "HIGH",     label = "RIFT SLASH — TANK",           sound = "raid_warning" },
    [1232467] = { priority = "MEDIUM",   label = "OBELISK ADD SPAWN",           sound = "alarm" },
    [1243753] = { priority = "MEDIUM",   label = "RAVENOUS ABYSS — MOVE",       sound = "alarm" },
    [1238843] = { priority = "MEDIUM",   label = "DEVOURING COSMOS — KNOCKBACK",sound = "alarm" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
