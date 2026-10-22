# VoidRaidTools

**A complement to DBM and BigWigs — it handles the parts they leave to you.**

DBM and BigWigs announce what the boss is about to do. VoidRaidTools doesn't repeat those alerts — it tells *you* what to do about them, and only the things you can actually act on: **DPS** see kicks and soak assignments, **healers** see dispels and external-cooldown requests, **tanks** see swap callouts with a one-click TAUNT button. It filters by your spec automatically — no setup.

**Requires the free companion addon [VoidRaidToolsReader](https://www.curseforge.com/wow/addons/voidraidtoolsreader).**

---

## Features

### Kick Rotation
- A floating board of every kicker in your group, ordered by **who's up next** from real cooldown tracking
- Syncs between VoidRaidTools users, so the whole group sees the same rotation live

> *DBM says "boss casting X" — you still have to remember whose Mind Freeze is up. VoidRaidTools tells you whose kick is up.*

### Tank Swap Routers
- A one-click **TAUNT** popup on the right tank's screen, decided from the actual fight state — debuff stacks, last swap, dragon assignments, whatever the boss needs

> *DBM says "swap now" — you still have to work out who and target manually.*

### Focus Kick Bar
- A big cast bar for **your focus — or your target if you have no focus**: spell name, icon and time left, green when you can kick it, grey (dimmed) on casts you can't interrupt so you don't waste the kick

### Marker Kick Alert
- Alerts **only when a raid-marked mob** starts an interruptible cast — so you're pinged for your assigned target, not every kickable cast in the room

### Marker Scan
- One keybind marks the priority kick, dispel, and CC mobs as you approach a pull
- Currently has a priority list for **Magisters' Terrace**; more dungeons will follow

### Boss-specific helpers
- **L'ura memory game** (Midnight Falls) — each player with the Dark Rune sees their personal pattern plus an arrow to their spot
- **DK Grip / Grip / Kick** (Chimaerus) — one keybind runs Death Grip → Death Grip → Mind Freeze and auto-targets the next un-gripped Haunting Essence

---

## Per-Boss Modules

Boss modules currently cover the **Season 1 raids**. Season 2 (**The Venomous Abyss**) boss modules aren't in yet — the general tools above (kick rotation, focus kick bar, marker kick alerts) work in any content.

| Boss | What it does |
|---|---|
| Imperator Averzian | Kicks, dispels, soaks + Blackening Wounds tank swap |
| Vorasius | Add kicks, dispels + Smashing Frenzy swap cycle |
| Vaelgor & Ezzorak | Kicks, fear dispels, tether warnings + dragon swap |
| Lightblinded Vanguard | Kicks, soaks, externals + Bellamy/Venel swap router |
| Fallen-King Salhadaar | Kicks, Void Convergence orbs + cleave-stack swap |
| Crown of the Cosmos | Add kicks, tethers, dispels |
| Chimaerus | Kicks, dispels, soaks + DK Grip sequence |
| Belo'ren | Radiant Echoes orbs, color soaks, externals |
| Midnight Falls (L'ura) | Safeguard Prism + Dark Rune memory game |

---

## Slash Commands

| Command | What it does |
|---|---|
| `/vrt panel` | Open the main panel (also `/vrtp`) |
| `/vrt edit` | Unlock frames so you can move them |
| `/vrt resetpos` | Reset all frames to their default positions |
| `/vrtmark` | Show Marker Scan status for your current zone |

---

## Getting Started

1. Install **VoidRaidTools** and **VoidRaidToolsReader** with the CurseForge app (or copy both folders into `World of Warcraft/_retail_/Interface/AddOns/`).
2. Restart WoW or `/reload`.
3. Open the panel with the minimap button or `/vrt panel`.
4. Optional: click **Disable All**, then turn on only the modules you want.
5. In **Keybindings → VoidRaidTools**, bind keys for **TAUNT** and **Sequence** so those popups have a key to listen for.

---

## Good to Know

- **Why the Reader is required:** VoidRaidToolsReader records boss events so the cross-class alerts have the data they need. It asks for your consent on first login, and local-only mode keeps everything on your computer.
- Contributing that data to the shared model is optional and uses the small companion app at [voidscout.io/install](https://voidscout.io/install).

---

## Compatibility

- **WoW 12.1.5** (Midnight Season 2)
- Requires **VoidRaidToolsReader**
- Designed to run alongside DBM or BigWigs

---

*Part of the Void addon family by Vede · MIT licensed · free M+ & raid player lookups at [voidscout.io](https://voidscout.io) · more addons & apps at [tinkerline.io](https://tinkerline.io) · [Discord](https://discord.gg/7ZHmx7zMDh)*
