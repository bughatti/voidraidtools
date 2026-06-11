----------------------------------------------------------------------
-- VoidRaidTools — Chimaerus, the Undreamt God (Dreamrift, 3306)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. DK Grip/Grip/Kick
-- sequence on Haunting Essences stays in ClassSequences.lua.
-- ⚠ Overrides UNVERIFIED — promote/demote after first pull.
----------------------------------------------------------------------

local M = {
    id   = "chimaerus_alerts",
    name = "Chimaerus — Kick + Utility Alerts",
    description = "Role-filtered alerts for Chimaerus: DPS see Fearsome Cry kicks, healers see Consuming Miasma dispels, tanks see Caustic Phlegm external requests + Rift Madness on Mythic. DBM alerts everyone for everything — this filters by YOUR role so it's not noise.",
    state = { active = false },
}

M.encounter_id = 3306

M.overrides = {
    [1249017] = { priority = "CRITICAL", label = "FEARSOME CRY — KICK",          sound = "raid_warning" },
    [1257087] = { priority = "HIGH",     label = "CONSUMING MIASMA — DISPEL",    sound = "raid_warning" },
    [1257085] = { priority = "HIGH",     label = "CONSUMING MIASMA — DISPEL",    sound = "raid_warning" },
    [1262289] = { priority = "HIGH",     label = "ALNDUST UPHEAVAL — SOAK",      sound = "raid_warning" },
    [1246653] = { priority = "HIGH",     label = "CAUSTIC PHLEGM — EXTERNALS",   sound = "raid_warning" },
    [1246621] = { priority = "HIGH",     label = "CAUSTIC PHLEGM — EXTERNALS",   sound = "raid_warning" },
    [1272726] = { priority = "MEDIUM",   label = "RENDING TEAR — FRONTAL",       sound = "alarm" },
    [1245486] = { priority = "MEDIUM",   label = "CORRUPTED DEVASTATION — DODGE",sound = "alarm" },
    [1245406] = { priority = "MEDIUM",   label = "RAVENOUS DIVE — KNOCKBACK",    sound = "alarm" },
    [1264756] = { priority = "HIGH",     label = "RIFT MADNESS — DISPEL (M)",    sound = "raid_warning" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
