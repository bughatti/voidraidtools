# VoidRaidTools Changelog

## 1.0.5 — 2026-06-10

### Fixed
- **Panel enable/disable checkboxes now take effect immediately for every module.** Previously the checkbox just flipped the persistent `VoidRaidToolsDB.modules[id]` flag, which gated future event dispatches but did nothing to the visible UI the module had already created. Result: unchecking Kick Rotation (or any other module with a visible frame) kept the box on-screen until `/reload`. Now `VRT:SetModuleEnabled` hides every registered movable that belongs to the toggled module, and fires `OnDisable`/`OnEnable` lifecycle callbacks for any module that wants custom logic. Works for all 13 modules with visible frames without touching their files individually — frames are matched via the existing `VRT.movables` registry (id is `<module_id>` or `<module_id>.<subid>`).
- **Kick Rotation** specifically: implements `OnDisable` (hides the floating frame) and `OnEnable` (re-runs visibility check). So unchecking the box hides the rotation immediately, re-checking brings it back if you're in a dungeon and haven't separately user-hidden it.

## 1.0.4 — 2026-06-10

### Fixed
- **Kick Rotation "Hide Kick Frame" now sticks across /reload, zone change, and ENCOUNTER_START.** Previously the panel button hid the frame for the current session only — any reload or boss pull silently re-showed it. Now persisted as `settings.kickrotation.user_hidden` in `VoidRaidToolsDB`. Click "Show Kick Frame" to bring it back.

## 1.0.3 — 2026-06-10

### Fixed
- **TankSwapDiagnostic** ring buffer no longer O(n²). The naive `while #t > cap do table.remove(t, 1) end` pattern was tripping WoW's script-time-limit watchdog during sustained 20-man raid pulls (~50+ events/sec). Replaced with a single O(n) bulk drop of the oldest 10% so the next 10% of appends are free.

### Cleanup
- **Panel.lua**: removed dead legacy `VRT_MinimapButton` block — it was duplicating with `Minimap.lua`'s hub-discoverable `VoidRaidToolsMinimapBtn`. No user-facing change; the hub button is the only minimap UI now.

## 1.0.2 — 2026-06-09 (pre-raid push)

### Fixed
- **Lura Memory** layout: box 20% smaller, status text moved above L'ura icon so the 6 o'clock shape cell no longer collides with "Oracle: YOU".
- **Lura Memory** no longer clobbers Blizzard's global `PlayerFrame` — added a local shadow declaration so the player's unit frame stays put when the Oracle legend is hidden.
- **Lura Memory** custom L'ura portrait (Darkwell scene) now loads from `Media/lura.tga` with PNG fallback.
- **Salhadaar / Vaelgor & Ezzorak / all bosses**: replaced brittle BigWigs-sourced spell IDs with a runtime-resolved engine. Configured overrides stay for known criticals; everything else gates on `C_Spell.IsSpellImportant` with the spell name resolved live via `C_Spell.GetSpellName`. Modules can no longer ship silent.

### Added
- `BossAlertEngine` shared helper — every per-boss alert module is now ~20 lines of overrides table + Attach call.
- `KickRotation:FlashAlert(duration, label)` accepts a custom label so the alert panel shows the actual spell name.
- Required-companion banner at login if `VoidRaidToolsReader` is missing.

### Hidden
- `TankSwapDiagnostic` now opt-in via `VoidRaidToolsDB.settings.debug = true` + reload. Default install no longer loads its 1k-line capture path.

## 1.0.0 — 2026-06-09

First public release.

### Modules shipped

**Raid alert modules** (ETEA-driven priority alerts per encounter):
- Imperator Averzian (3176) — Void Rupture kick, Umbral Collapse soak
- Vorasius (3177) — Blistercreep add kicks (Oozing Slam, Overload) + Backlash + Rift Madness
- Vaelgor & Ezzorak (3178) — Nullbeam + Void Howl kicks + Dread Breath dodge
- Salhadaar (3179) — Shadow Fracture kick (CRITICAL), Despotic Command dispel, Shattered Sky burn window
- Lightblinded Vanguard (3180) — Light/Void Quill kicks + Devouring Essence dispel + Sacred Shield indicator
- Crown of the Cosmos (3181) — Interrupting Tremor kick, Cosmic Barrier burn window
- Belo'ren (3182) — Color-soak alerts, Guardian's Edict tank, Eternal Burns heal absorb
- Midnight Falls / L'ura (3183) — Safeguard Prism kick (CRITICAL), Heaven's Glaives raid CD
- Chimaerus (3306) — Fearsome Cry kick, Consuming Miasma dispel

**Tank-swap router modules** (opt-in via "I go first" / "I go second"):
- Lightblinded Vanguard — Bellamy + Venel Judgement routing
- Vorasius — Smashing Frenzy 6-cycle routing
- Vaelgor & Ezzorak — dual-target tank cleave
- StackTankSwap — generic stacking-debuff router

**Mechanic helpers**:
- L'ura Memory Game — Oracle bar + radial symbol map for Heroic Midnight Falls Dark Rune
- Class Sequences — DK Grip/Grip/Kick castsequence on Chimaerus Haunting Essences

**Kick-priority pipeline**:
- KickRotation — raid-aware kick rotation tracker (party + raid units)
- MarkerScan — one-key macro to mark priority mobs via `/targetexact` + `/tm`
- MarkerKickAlert — silent until 2.7s into a marked mob's cast, then RaidWarning sound (filters Bolt from Poly via cast duration)
- MarkerOverlay — big pulsing skull above any marked nameplate (Plater-compatible)
- FocusKickBar — clean focus cast bar that auto-hides non-interruptible casts via C-side `SetAlphaFromBoolean` (the X-Wind discovery)

### Technical highlights

- All boss alert modules use the `C_EncounterEvents.GetEventInfo()` bridge to read clean spell IDs from ETEA events — works around the 12.0.5 secret-value gate on hostile cast IDs
- MarkerKickAlert uses `type(GetRaidTargetIndex(unit)) == "number"` for clean marker detection (the one comparison the secret-value system permits)
- Fingerprint matching covers the "2nd Magister" case where `/targetexact` can only mark one of a same-named pair
- Combined alert system silences unmarked mob casts so the rotation panel only fires on leader-flagged priorities

### Known limitations

- Spell IDs for some boss modules sourced from BigWigs; live ETEA captures may produce different IDs. The 2nd raid pull per boss validates this — alerts that don't fire mean the priority list needs the captured IDs swapped in.
- Crown of the Cosmos spell IDs particularly limited — only verified after Mythic kill captures.
- Tank-swap routers require explicit role claim ("I go first" / "I go second") — auto-detection of tank role on encounter start is a v1.1 goal.
