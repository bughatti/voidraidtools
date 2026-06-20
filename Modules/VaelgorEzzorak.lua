----------------------------------------------------------------------
-- VoidRaidTools — Vaelgor & Ezzorak (Voidspire 3178)
--
-- ETEA-driven priority alerts via VRT.BossAlertEngine. Tank-swap state
-- still lives in VaelgorEzzorakTanks.lua.
--
-- Verified (live ETEA capture, 2026-06-08 raid night):
--   78 distinct event IDs fired across one Heroic pull. None of the
--   original BigWigs IDs (Nullbeam/Void Howl/Dread Breath/etc.) appeared
--   — they were wrong. The engine's IsSpellImportant fallback will fire
--   alerts for the real boss casts; promote specific IDs to overrides
--   here as we learn which ones matter from raid play.
----------------------------------------------------------------------

local M = {
    id   = "vaelezz_alerts",
    name = "Vaelgor & Ezzorak — Kick + Utility",
    description = "Role-filtered alerts for Vaelgor & Ezzorak: DPS get kicks + Nullzone tether warnings, healers get fear dispels, everyone gets Midnight Flames intermission callouts. The tank-swap routing is in VaelgorEzzorakTanks.",
    state = { active = false },
}

M.encounter_id = 3178

M.overrides = {
    -- Empty for now: 2026-06-08's pull showed 0/7 of the original IDs
    -- firing. We rely on C_Spell.IsSpellImportant for now; promote here
    -- once a tomorrow-night ETEA capture confirms which IDs are the
    -- real kick / dispel / tank-swap calls.
}

if VRT and VRT.BossAlertEngine then
    VRT.BossAlertEngine:Attach(M)
end

function M:OnUnitAura(unit) end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
