----------------------------------------------------------------------
-- VoidRaidTools — Belo'ren, Child of Al'ar (MQD, 3182)
-- No interruptible casts (soak/polarity fight). Tank + soak + external alerts.
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine.
-- ⚠ Overrides UNVERIFIED — promote/demote after first pull.
----------------------------------------------------------------------

local M = {
    id   = "beloren_alerts",
    name = "Belo'ren — Alerts",
    description = "Tank swap, color-soak warnings, external CDs.",
    state = { active = false },
}

M.encounter_id = 3182

M.overrides = {
    [1260763] = { priority = "HIGH",     label = "GUARDIAN'S EDICT — TANK COMBO", sound = "raid_warning" },
    [1242981] = { priority = "HIGH",     label = "RADIANT ECHOES — COLOR SOAK",   sound = "raid_warning" },
    [1241292] = { priority = "MEDIUM",   label = "LIGHT DIVE — SOAK",             sound = "alarm" },
    [1241339] = { priority = "MEDIUM",   label = "VOID DIVE — SOAK",              sound = "alarm" },
    [1244344] = { priority = "HIGH",     label = "ETERNAL BURNS — HEAL ABSORB",   sound = "raid_warning" },
    [1242260] = { priority = "MEDIUM",   label = "INFUSED QUILLS — SOAK",         sound = "alarm" },
    [1246709] = { priority = "MEDIUM",   label = "DEATH DROP — KNOCKBACK P2",     sound = "alarm" },
    [1242515] = { priority = "MEDIUM",   label = "VOIDLIGHT CONVERGENCE — SWAP",  sound = "alarm" },
    [1241313] = { priority = "MEDIUM",   label = "REBIRTH — P2 BURN",             sound = "alarm" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
