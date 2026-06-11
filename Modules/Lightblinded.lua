----------------------------------------------------------------------
-- VoidRaidTools — Lightblinded Vanguard (Voidspire boss 3, 3180)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. Tank-swap state
-- still lives in LightblindedTanks.lua. All 14 overrides below were
-- verified against LIVE ETEA captures from Heroic Lightblinded
-- (2026-06-08 raid night).
----------------------------------------------------------------------

local M = {
    id   = "lightblinded_alerts",
    name = "Lightblinded Vanguard — Kick + Utility Alerts",
    description = "Role-filtered alerts for Lightblinded Vanguard: DPS get kicks + soak assignments, healers get external-CD requests + Mass Dispel calls. Tank-swap routing is handled by LightblindedTanks.",
    state = { active = false },
}

M.encounter_id = 3180

-- VERIFIED 2026-06-08 against live ETEA captures.
M.overrides = {
    -- KICKS
    [1241992] = { priority = "CRITICAL", label = "LIGHT QUILL — KICK",          sound = "raid_warning" },
    [1242091] = { priority = "CRITICAL", label = "VOID QUILL — KICK",           sound = "raid_warning" },
    -- TANK
    [1227367] = { priority = "HIGH",     label = "SHOCKWAVE SLAM — TANK",       sound = "raid_warning" },
    [1256351] = { priority = "HIGH",     label = "SHATTERING BACKHAND — TANK",  sound = "raid_warning" },
    [1256355] = { priority = "HIGH",     label = "SHATTERING BACKHAND — TANK",  sound = "raid_warning" },
    [1256358] = { priority = "HIGH",     label = "SHATTERING BACKHAND — TANK",  sound = "raid_warning" },
    -- DISPEL (Devouring Essence N/H/M)
    [1280086] = { priority = "HIGH",     label = "DEVOURING ESSENCE — DISPEL",  sound = "raid_warning" },
    [1280087] = { priority = "HIGH",     label = "DEVOURING ESSENCE — DISPEL",  sound = "raid_warning" },
    [1280088] = { priority = "HIGH",     label = "DEVOURING ESSENCE — DISPEL",  sound = "raid_warning" },
    -- SOAK
    [1248847] = { priority = "HIGH",     label = "RADIANT BARRIER — SOAK",      sound = "raid_warning" },
    -- EXTERNALS / AOE
    [1276639] = { priority = "HIGH",     label = "SEARING RADIANCE — HEALERS",  sound = "raid_warning" },
    [1220394] = { priority = "HIGH",     label = "SHATTERSHELL — EXTERNALS",    sound = "raid_warning" },
    [1272310] = { priority = "MEDIUM",   label = "DIVINE STORM — RAID AOE",     sound = "alarm" },
    [1231871] = { priority = "MEDIUM",   label = "CRYSTALLINE SHOCKWAVE",       sound = "alarm" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
