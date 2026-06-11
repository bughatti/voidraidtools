----------------------------------------------------------------------
-- VoidRaidTools — Imperator Averzian (Voidspire 3176)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine.
--
-- ⚠ All overrides below are UNVERIFIED — sourced from BigWigs/Wowhead
-- research, never seen in a live ETEA capture. The engine's
-- IsSpellImportant fallback will fire generic alerts for the real
-- IDs; promote / demote here after the first real pull captures data.
----------------------------------------------------------------------

local M = {
    id   = "averzian_alerts",
    name = "Imperator Averzian — Alerts",
    description = "Role-filtered alerts for Imperator Averzian: DPS get add-cast kicks, healers get Void Marked dispels (Mythic), everyone gets soak warnings. Pairs with StackTankSwap for the Blackening Wounds swap.",
    state = { active = false },
}

M.encounter_id = 3176

M.overrides = {
    -- UNVERIFIED — promote/remove after first real pull
    [1262036] = { priority = "CRITICAL", label = "VOID RUPTURE — KICK",          sound = "raid_warning" },
    [1280015] = { priority = "HIGH",     label = "VOID MARKED — DISPEL",         sound = "raid_warning" },
    [1249262] = { priority = "CRITICAL", label = "UMBRAL COLLAPSE — SOAK",       sound = "raid_warning" },
    [1258883] = { priority = "MEDIUM",   label = "VOID FALL — KNOCKBACK",        sound = "alarm" },
    [1260712] = { priority = "HIGH",     label = "OBLIVION'S WRATH — EXTERNALS", sound = "raid_warning" },
    [1249251] = { priority = "HIGH",     label = "DARK UPHEAVAL — EXTERNALS",    sound = "raid_warning" },
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
