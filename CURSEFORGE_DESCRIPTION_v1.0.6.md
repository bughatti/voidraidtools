# VoidRaidTools — CurseForge Project Description (v1.0.6)

Paste the section below into the **Description** field on the CurseForge project page.
The text is plain Markdown; CurseForge supports it natively.

---

## VoidRaidTools is a complement to DBM/BigWigs, not a replacement.

DBM and BigWigs already announce when a boss is about to cast something. **VoidRaidTools doesn't repeat their alerts** — it solves the things they leave to you.

Every per-boss module ships with the same idea: **you should only be alerted for the things you can actually do**.

- **DPS** see kicks + soak assignments
- **Healers** see dispels + external-cooldown requests
- **Tanks** see swap callouts + a one-click TAUNT button

That filtering happens automatically based on your spec, no setup required.

---

## What's actually different

### Kick Rotation
A floating board that lists every kicker in your group, ordered by who's **UP NEXT** based on actual cooldown tracking. When another VoidRaidTools user fires an interrupt, the board updates over the addon channel — so the whole group sees the same rotation in real-time.

> *DBM announces "boss casting X" — you still have to remember whose Mind Freeze is up.*
> *VoidRaidTools tells you whose kick is up.*

### Tank Swap Routers (Lightblinded, Vorasius, Vaelgor & Ezzorak, Imperator, Salhadaar)
A one-click **TAUNT** popup that decides which tank should swap based on the actual fight state — debuff stacks, last swap, dragon assignments, whatever the boss needs.

> *DBM says "swap now" — you have to figure out who and target manually.*
> *VoidRaidTools pops a button on the right tank's screen — click it.*

### L'ura Memory Game (LuraMemory)
The Dark Rune phase on Midnight Falls. Each player with the rune sees their **personal color/shape pattern** on screen plus a directional arrow to their assigned spot. Group-coordinated via raid markers.

> *DBM has no per-player memory tracking. Everyone gets the same generic "remember the pattern" text.*

### Class Sequences — DK Grip / Grip / Kick on Chimaerus
A single keybind that launches a 3-step castsequence (Death Grip → Death Grip → Mind Freeze) and **auto-targets the next un-gripped Haunting Essence** each time you press it. Built specifically for the Chimaerus spirit-realm adds.

> *DBM tells you to kick. VoidRaidTools kicks for you.*

### Marker-Driven Kick Alert
Critical alerts that fire **only when a raid-marked mob** starts an interruptible cast. Filters out the noise of DBM's "everyone gets every kickable cast" model — you only get pinged for your assigned target.

### Focus Kick Bar
Dedicated cast bar for **your focus target only**. Auto-hides on non-interruptible casts. Doesn't get drowned out by raid-wide spam.

### Marker Scan
One keybind — auto-marks priority kick / dispel / CC mobs in the current dungeon. Saves the leader from manually assigning markers each pull.

---

## Per-boss modules (Midnight raid lineup)

| Boss | Module | What it does |
|---|---|---|
| Imperator Averzian | `ImperatorAverzian` + `StackTankSwap` | Kicks, dispels, soaks + Blackening Wounds swap |
| Vorasius | `Vorasius` + `VorasiusTanks` | Add-kicks, dispels + Smashing Frenzy cycle |
| Vaelgor & Ezzorak | `VaelgorEzzorak` + `VaelgorEzzorakTanks` | Kicks, fear dispels, tether warnings + dragon swap |
| Lightblinded Vanguard | `Lightblinded` + `LightblindedTanks` | Kicks, soaks, externals + Bellamy/Venel router |
| Fallen-King Salhadaar | `Salhadaar` + `StackTankSwap` | Kicks, Void Convergence orbs + Cleave-stack swap |
| Crown of the Cosmos | `CrownOfCosmos` | Add-kicks, tethers, dispels |
| Chimaerus | `Chimaerus` + `ClassSequences` | Kicks, dispels, soaks + DK Grip sequence |
| Belo'ren | `Beloren` | Radiant Echoes orbs, color soaks, externals |
| Midnight Falls (L'ura) | `MidnightFalls` + `LuraMemory` | Safeguard Prism + Dark Rune memory game |

---

## Required companion

You also need to install **VoidRaidToolsReader** alongside this addon. The Reader silently records boss events so cross-class alerts have the data they need to fire correctly. First-time install will show a one-click consent dialog explaining what's collected — **opt-out keeps it local-only**.

---

## Setup

1. Install **VoidRaidTools** + **VoidRaidToolsReader** from CurseForge
2. `/reload` after install
3. Open the panel with the minimap button or `/vrt panel`
4. (Optional) **Disable All** at the bottom, then re-enable only the modules you want
5. Bind keys for `VoidRaidTools — TAUNT` and `VoidRaidTools — Sequence` in **Keybindings → VoidRaidTools** so the TAUNT and Grip popups have a key to listen for

---

## Slash commands

- `/vrt panel` — opens the main panel
- `/vrt edit` — moves frames around the screen
- `/vrt resetpos` — resets all movable frames to defaults
