# VoidRaidTools

Per-boss raid mechanic alerts for World of Warcraft Midnight (12.0.5). Kick priority filtering, tank-swap routing, ETEA-driven boss schedule alerts.

## What it does

**Kick rotation, simplified.** One macro key marks priority mobs (Magister, Void Infuser, etc.) via `/targetexact` + `/tm`. The addon stays SILENT on unmarked mob casts, then fires a RaidWarning sound only when a marked mob's cast survives past 2.7s (= confirmed Polymorph / Terror Wave / similar important spell, not Arcane Bolt).

**Per-boss alerts for the full Midnight raid lineup.** All 9 Midnight S1 encounters wired with ETEA-driven priority spell lists:

- Voidspire: Imperator Averzian, Vorasius, Vaelgor & Ezzorak, Lightblinded Vanguard, Fallen-King Salhadaar, Crown of the Cosmos
- Dreamrift: Chimaerus, the Undreamt God
- March on Quel'Danas: Belo'ren, Midnight Falls (L'ura)

Alerts route through a single KickRotation panel — kicks, dispels, externals, tank swaps, soaks each get a distinct flash + sound.

**Tank-swap routers.** Opt-in via "I go first" / "I go second" — popups fire at the right moment for whoever claimed each role.

**L'ura Memory Game.** Oracle bar + radial symbol map for Heroic Midnight Falls Dark Rune. One Oracle clicks the called sequence; everyone with the addon sees the map populate live and knows their position when Dark Rune lands on them.

**Focus Kick Bar.** Clean cast bar for your focus that auto-hides non-interruptible casts via the C-side `SetAlphaFromBoolean` method — never waste a kick on something you can't kick.

## Install

1. Download from CurseForge
2. Restart WoW
3. `/vrt` for the master panel
4. `/vrtmark bind F` to bind the marker scan macro (or any key)

## Slash commands

| Command | What it does |
|---|---|
| `/vrt` | Master panel with module list + settings |
| `/vrt edit` | Toggle edit mode — drag any frame to reposition |
| `/vrt resetpos` | Reset all frame positions to defaults |
| `/vrtmark` | MarkerScan status — current zone + priority list |
| `/vrtmark bind <KEY>` | Bind the marker macro to a key |
| `/vrt lura test 5` | Simulate Heroic L'ura memory game |
| `/vrt lura oracle` | Toggle Oracle role |

## Theory of operation

VRT solves three problems specific to 12.0.5 raid content:

1. **Secret-value gate.** Hostile mob spell IDs are tainted when read via Lua in instances. VRT routes around this via `C_EncounterEvents.GetEventInfo()` (clean spell IDs for boss events) and `type(GetRaidTargetIndex(unit)) == "number"` (clean marker detection).

2. **Marker discipline.** Leader marks priority mobs once; the addon respects the leader's intent and ignores casts from unmarked mobs.

3. **Cast duration filter.** A 2.7s threshold on cast time distinguishes the dangerous important spells (Polymorph 3.5s, Terror Wave 4.0s, Shadow Fracture 3.5s) from the safe-to-ignore ones (Arcane Bolt 2.5s) — without needing to read the spell ID.

## Dependencies

- VoidLib (shared utility library, bundled)

## Roadmap

- v1.1: Auto-detect tank role on encounter start (skip the manual "I go first" claim)
- v1.1: More raid alert modules as new Midnight content lands
- v1.2: Per-class kick rotation hints (per-spec interrupt cooldowns)

## License

Apache 2.0 — see LICENSE file.

## Author

Vede ([VoidScout](https://voidscout.io))
