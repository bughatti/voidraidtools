----------------------------------------------------------------------
-- VoidRaidTools — Fallen-King Salhadaar (Voidspire H/M)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. Any boss cast
-- that Blizzard flags as important via C_Spell.IsSpellImportant will
-- fire a generic MEDIUM-priority alert with the live spell name.
-- Overrides below promote specific spell IDs to higher priorities + a
-- known label.
--
-- Verified (live ETEA capture, 2026-06-08 raid night):
--   1249796 Shattered Sky  — boss-name-confirmed in combat log
--
-- The original module shipped 5 hand-curated BigWigs IDs (Shadow
-- Fracture, Despotic Command, Shattering Twilight, Destabilizing
-- Strikes). 4 of those 5 NEVER fired during tonight's pulls and have
-- been removed pending real ETEA verification.
----------------------------------------------------------------------

local M = {
    id   = "salhadaar",
    name = "Fallen-King Salhadaar",
    description = "Role-filtered alerts for Fallen-King Salhadaar: DPS get kicks + Void Convergence orb assignments, healers get dispels. The Cleave-stack tank swap is in StackTankSwap.",
    state = { active = false },
}

M.encounter_id = 3179

M.overrides = {
    [1249796] = { priority = "HIGH", label = "SHATTERED SKY — EXTERNALS", sound = "raid_warning" },
}

----------------------------------------------------------------------
-- Wire-up via shared engine
----------------------------------------------------------------------
if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end -- noop, kept for Core dispatch compat

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
