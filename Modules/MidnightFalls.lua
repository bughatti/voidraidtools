----------------------------------------------------------------------
-- VoidRaidTools — Midnight Falls / L'ura (MQD, 3183)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. The Dark Rune
-- memory game stays in LuraMemory.lua.
-- ⚠ Overrides UNVERIFIED — promote/demote after first pull.
----------------------------------------------------------------------

local M = {
    id   = "midnightfalls_alerts",
    name = "Midnight Falls — Kick + Utility",
    description = "Role-filtered alerts for Midnight Falls (L'ura): DPS get Safeguard Prism kicks + Galvanize beam dodges, healers get dispels, tanks get swaps. The Dark Rune memory game UI is in LuraMemory.",
    state = { active = false },
}

M.encounter_id = 3183

M.overrides = {
    [1251386] = { priority = "CRITICAL", label = "SAFEGUARD PRISM — KICK",      sound = "raid_warning" },
    [1284931] = { priority = "CRITICAL", label = "TERMINATION PRISM — KICK",    sound = "raid_warning" },
    [1267049] = { priority = "HIGH",     label = "HEAVEN'S LANCE — TANK",       sound = "raid_warning" },
    [1253915] = { priority = "HIGH",     label = "HEAVEN'S GLAIVES — EXTERNALS",sound = "raid_warning" },
    [1282441] = { priority = "HIGH",     label = "STARSPLINTER — EXTERNALS",    sound = "raid_warning" },
    [1281194] = { priority = "MEDIUM",   label = "DARK MELTDOWN — KNOCKBACK",   sound = "alarm" },
    [1250898] = { priority = "HIGH",     label = "DARK ARCHANGEL — EXTERNALS",  sound = "raid_warning" },
    [1266897] = { priority = "HIGH",     label = "LIGHT SIPHON — SOAK",         sound = "raid_warning" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
