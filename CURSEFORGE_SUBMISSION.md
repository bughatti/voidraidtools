# VoidRaidTools — CurseForge Submission

Copy each field below into the matching CurseForge form input when creating the project.

## Basic info

**Project name**: VoidRaidTools

**Slug**: `voidraidtools`

**Categories**:
- Raid Frames
- Combat
- Boss Encounters

**Game version compatibility**: 12.0.5, 12.0.7

**Project URL**: https://www.curseforge.com/wow/addons/voidraidtools

## Description

(Paste into the description rich-text editor — strip the markdown if needed.)

---

**Per-boss raid mechanic alerts for the full Midnight raid lineup. Kick priority filtering, tank-swap routing, ETEA-driven boss schedule alerts.**

## What it does

**Kick rotation, simplified.** One macro key marks priority mobs (Magister, Void Infuser, etc.) via `/targetexact` + `/tm`. The addon stays SILENT on unmarked mob casts, then fires a RaidWarning sound only when a marked mob's cast survives past 2.7s (= confirmed Polymorph / Terror Wave / similar important spell, not Arcane Bolt).

**Per-boss alerts for the full Midnight raid lineup.** All 9 Midnight S1 encounters wired with ETEA-driven priority spell lists:

- **Voidspire**: Imperator Averzian, Vorasius, Vaelgor & Ezzorak, Lightblinded Vanguard, Fallen-King Salhadaar, Crown of the Cosmos
- **Dreamrift**: Chimaerus, the Undreamt God
- **March on Quel'Danas**: Belo'ren, Midnight Falls (L'ura)

Alerts route through a single KickRotation panel — kicks, dispels, externals, tank swaps, soaks each get a distinct flash + sound.

**Tank-swap routers.** Opt-in via "I go first" / "I go second" — popups fire at the right moment for whoever claimed each role. Available for Lightblinded Vanguard, Vorasius, Vaelgor & Ezzorak.

**L'ura Memory Game.** Oracle bar + radial symbol map for Heroic Midnight Falls Dark Rune. One Oracle clicks the called sequence; everyone with the addon sees the map populate live and knows their position when Dark Rune lands on them.

**Focus Kick Bar.** Clean cast bar for your focus that auto-hides non-interruptible casts — never waste a kick on something you can't kick.

## Slash commands

- `/vrt` — Master panel
- `/vrt edit` — Toggle edit mode (drag any frame to reposition)
- `/vrtmark bind <KEY>` — Bind the marker scan macro

## Theory

Hostile mob spell IDs are tainted by the 12.0.5 secret-value system, so we can't read which spell is being cast in Lua. VRT works around this:

1. **Boss casts** — Uses `C_EncounterEvents.GetEventInfo()` to get clean spell IDs via the ETEA event timeline (bypasses the Lua secret-value gate for boss-scheduled events)
2. **Marker presence** — Uses `type(GetRaidTargetIndex(unit)) == "number"` to detect marked mobs cleanly (the one comparison the secret-value system permits)
3. **Cast duration filter** — A 2.7s threshold distinguishes important spells (Polymorph 3.5s, Terror Wave 4.0s) from safe-to-ignore short casts (Arcane Bolt 2.5s) without needing to read the spell ID

## Dependencies

- **VoidLib** (shared library, bundled in the addon)

---

## Tags (for searchability)

`raid`, `kick`, `interrupt`, `dispel`, `tank-swap`, `midnight`, `voidspire`, `dreamrift`, `quel-danas`, `salhadaar`, `chimaerus`, `lura`, `midnight-falls`, `marker`, `priority`, `boss-alerts`

## Upload checklist

- [ ] Source code zipped (exclude `.git`, `.DS_Store`)
  - `VoidRaidTools/`
    - `VoidRaidTools.toc`
    - `Core.lua`
    - `Panel.lua`
    - `Modules/`
    - `Libs/VoidLib/`
    - `README.md`
    - `CHANGELOG.md`
    - `LICENSE`
- [ ] Version field matches TOC `## Version: 1.0.2`
- [ ] Game version selected: 12.0.5
- [ ] Release type: Beta (first public release, gather feedback before stable)
- [ ] Changelog: paste the v1.0.2 section from CHANGELOG.md
- [ ] **REQUIRED COMPANION dependency**: link to VoidRaidToolsReader project page in the description. Without Reader, cross-class boss data doesn't flow and the alert engine's IsSpellImportant fallback is the only thing keeping unverified bosses from firing silent.
- [ ] Screenshots: 3-5 in-game shots of:
  - The KickRotation panel during a raid pull
  - MarkerOverlay showing the big skull above a marked mob
  - L'ura radial symbol map with shapes populated
  - Tank swap popup mid-pull
  - The minimap icon menu

## Post-upload

- [ ] Add the CurseForge URL to README.md install section
- [ ] Tweet/discord announcement linking to the listing
- [ ] Watch the first 24h for bug reports — likely first issue will be missing spell IDs for bosses we haven't validated yet (see "Known limitations" in CHANGELOG)
- [ ] Plan v1.0.1 hotfix scope for any blocker bugs surfaced
