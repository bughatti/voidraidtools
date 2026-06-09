----------------------------------------------------------------------
-- VoidRaidTools — Kick Rotation
--
-- Coordinates interrupts across the group. Auto-detects who's in the
-- party, maps each member to their class interrupt + base CD, and
-- displays a "Kick Order" frame showing who's UP NEXT.
--
-- Selection logic ("auto by CD availability" — user choice 2026-06-05):
--   - Track each kicker's last interrupt use
--   - "Ready" = (time_since_last_use >= base_cd)
--   - "Next" = first ready kicker in the user's priority order
--   - If everyone is on CD, show whoever is closest to ready
--
-- Detection:
--   - UNIT_SPELLCAST_SUCCEEDED on party members with spellID matching
--     our INTERRUPT table → mark them as just-used + start CD timer
--   - UNIT_SPELLCAST_INTERRUPTED on bossN / nameplateN as confirmation
--
-- Sync (cross-VRT-user):
--   - When ANY client detects a party member's interrupt land, it
--     broadcasts "KICKED|<player>|<spell_id>" via INSTANCE_CHAT
--   - All clients update the same rotation pointer
--   - No double-kicks, no missed-kicks
--
-- Boss + trash cast alerts (Phase 2):
--   - UNIT_SPELLCAST_START on boss1..3 and nameplate1..40
--   - If hostile + interruptible (notInterruptible == false): flash
--     the floating frame red and show "KICK NEXT: <player> kick now"
--   - Phase 3 will add a curated DB of priority casts (from DBM); for
--     now we trust the game's "interruptible" flag
----------------------------------------------------------------------

local M = {
    state = {
        members         = {},          -- { name → { class, spec, interrupts=[{spell_id,name,cd,last_used,...}], unit, has_vrt } }
        priority_order  = {},          -- { name1, name2, ... } — user-orderable
        floating_frame  = nil,
        active_casts    = {},          -- { [guid] = { unit, mob_name, spell_name, end_time } }
        -- VRT-presence tracking. We can only meaningfully include party
        -- members in the rotation if they ALSO run VRT — otherwise we
        -- never see their kicks (we don't read their cast events) and
        -- they'd appear "perpetually ready." HELLO broadcast/receive
        -- below populates this map.
        vrt_seen        = {},          -- { player_name → last_hello_GetTime() }
    },
}

-- HELLO handshake parameters
local HELLO_PERIOD       = 60   -- re-broadcast my presence every N sec
local HELLO_STALE_AFTER  = 150  -- forget a peer if no HELLO in this many sec (2.5 periods)

M.id          = "kickrotation"
M.name        = "Kick Rotation"
M.description = "Auto-detects group's interrupts, shows who's UP NEXT, syncs via broadcast. Phase 1: persistent rotation. Phase 2: cast-detection alerts."

----------------------------------------------------------------------
-- Interrupt + interrupt-equivalent CC database — 62 entries.
--
-- Includes every spell that produces a SPELL_INTERRUPT-equivalent effect:
--   - Dedicated kicks (Mind Freeze, Counterspell, etc.)
--   - Silences (Solar Beam, Sigil of Silence, Avenger's Shield, etc.)
--   - Stuns that interrupt on apply (Hammer of Justice, Shockwave, etc.)
--   - Displacements that interrupt by moving target (Death Grip, Typhoon)
--   - Fears that interrupt on cast (Psychic Scream, Howl of Terror)
--   - Pet abilities (Spell Lock, Optical Blast, Shambling Rush, etc.)
--
-- Filtered to reliability >= 0.7 from the 80-spell research set. Excluded
-- entries (Polymorph, Sap, Cyclone, Frost Nova, etc.) almost never
-- produce SPELL_INTERRUPT events in M+ logs, so tracking them would
-- give false "kick used" signals.
--
-- Source: voidscout-data/interrupts_120_5.json (researched 2026-06-06).
----------------------------------------------------------------------
local INTERRUPTS_BY_SPELL_ID = {
    -- DEATHKNIGHT
    [47476]  = { class = "DEATHKNIGHT", name = "Strangulate",     cd = 60, type = "silence",      spec = nil,                aoe = false, is_pet = false },
    [47528]  = { class = "DEATHKNIGHT", name = "Mind Freeze",     cd = 15, type = "interrupt",    spec = nil,                aoe = false, is_pet = false },
    [49576]  = { class = "DEATHKNIGHT", name = "Death Grip",      cd = 25, type = "displacement", spec = nil,                aoe = false, is_pet = false },
    [91800]  = { class = "DEATHKNIGHT", name = "Gnaw",            cd = 60, type = "stun",         spec = {"Unholy"},         aoe = false, is_pet = true },
    [91807]  = { class = "DEATHKNIGHT", name = "Shambling Rush",  cd = 30, type = "interrupt",    spec = {"Unholy"},         aoe = false, is_pet = true },
    [108194] = { class = "DEATHKNIGHT", name = "Asphyxiate",      cd = 45, type = "stun",         spec = {"Unholy"},         aoe = false, is_pet = false },
    [221562] = { class = "DEATHKNIGHT", name = "Asphyxiate",      cd = 45, type = "stun",         spec = {"Blood"},          aoe = false, is_pet = false },
    -- DEMONHUNTER
    [179057] = { class = "DEMONHUNTER", name = "Chaos Nova",       cd = 45, type = "stun",         spec = {"Havoc"},         aoe = true,  is_pet = false },
    [183752] = { class = "DEMONHUNTER", name = "Disrupt",          cd = 15, type = "interrupt",    spec = nil,               aoe = false, is_pet = false },
    [202137] = { class = "DEMONHUNTER", name = "Sigil of Silence", cd = 60, type = "silence",      spec = {"Vengeance"},     aoe = true,  is_pet = false },
    [207684] = { class = "DEMONHUNTER", name = "Sigil of Misery",  cd = 90, type = "disorient",    spec = {"Vengeance"},     aoe = true,  is_pet = false },
    [211881] = { class = "DEMONHUNTER", name = "Fel Eruption",     cd = 30, type = "stun",         spec = nil,               aoe = false, is_pet = false },
    [217832] = { class = "DEMONHUNTER", name = "Imprison",         cd = 45, type = "disorient",    spec = nil,               aoe = false, is_pet = false },
    -- DRUID
    [99]     = { class = "DRUID", name = "Incapacitating Roar", cd = 30, type = "disorient",    spec = nil,                  aoe = true,  is_pet = false },
    [5211]   = { class = "DRUID", name = "Mighty Bash",         cd = 60, type = "stun",         spec = nil,                  aoe = false, is_pet = false },
    [22570]  = { class = "DRUID", name = "Maim",                cd = 30, type = "stun",         spec = {"Feral"},            aoe = false, is_pet = false },
    [78675]  = { class = "DRUID", name = "Solar Beam",          cd = 60, type = "silence",      spec = {"Balance"},          aoe = true,  is_pet = false },
    [106839] = { class = "DRUID", name = "Skull Bash",          cd = 15, type = "interrupt",    spec = {"Feral", "Guardian"}, aoe = false, is_pet = false },
    [132469] = { class = "DRUID", name = "Typhoon",             cd = 30, type = "displacement", spec = nil,                  aoe = true,  is_pet = false },
    -- EVOKER
    [351338] = { class = "EVOKER", name = "Quell",       cd = 20,  type = "interrupt",    spec = nil, aoe = false, is_pet = false },
    [357214] = { class = "EVOKER", name = "Wing Buffet", cd = 180, type = "displacement", spec = nil, aoe = true,  is_pet = false },
    [368970] = { class = "EVOKER", name = "Tail Swipe",  cd = 180, type = "displacement", spec = nil, aoe = true,  is_pet = false },
    -- HUNTER
    [19577]  = { class = "HUNTER", name = "Intimidation",        cd = 60, type = "stun",      spec = {"Beast Mastery"},                aoe = false, is_pet = true },
    [117526] = { class = "HUNTER", name = "Binding Shot (Stun)", cd = 0,  type = "stun",      spec = nil,                               aoe = true,  is_pet = false },
    [147362] = { class = "HUNTER", name = "Counter Shot",        cd = 24, type = "interrupt", spec = {"Beast Mastery", "Marksmanship"}, aoe = false, is_pet = false },
    [187707] = { class = "HUNTER", name = "Muzzle",              cd = 15, type = "interrupt", spec = {"Survival"},                      aoe = false, is_pet = false },
    -- MAGE
    [2139]  = { class = "MAGE", name = "Counterspell",    cd = 24, type = "interrupt", spec = nil,       aoe = false, is_pet = false },
    [31661] = { class = "MAGE", name = "Dragon's Breath", cd = 45, type = "disorient", spec = {"Fire"},  aoe = true,  is_pet = false },
    -- MONK
    [115078] = { class = "MONK", name = "Paralysis",         cd = 45, type = "disorient", spec = nil,             aoe = false, is_pet = false },
    [116705] = { class = "MONK", name = "Spear Hand Strike", cd = 15, type = "interrupt", spec = nil,             aoe = false, is_pet = false },
    [119381] = { class = "MONK", name = "Leg Sweep",         cd = 60, type = "stun",      spec = nil,             aoe = true,  is_pet = false },
    [198909] = { class = "MONK", name = "Song of Chi-Ji",    cd = 30, type = "disorient", spec = {"Mistweaver"},  aoe = true,  is_pet = false },
    -- PALADIN
    [853]    = { class = "PALADIN", name = "Hammer of Justice", cd = 60, type = "stun",      spec = nil,               aoe = false, is_pet = false },
    [20066]  = { class = "PALADIN", name = "Repentance",        cd = 15, type = "disorient", spec = {"Retribution"},   aoe = false, is_pet = false },
    [31935]  = { class = "PALADIN", name = "Avenger's Shield",  cd = 15, type = "silence",   spec = {"Protection"},    aoe = true,  is_pet = false },
    [96231]  = { class = "PALADIN", name = "Rebuke",            cd = 15, type = "interrupt", spec = nil,               aoe = false, is_pet = false },
    [105421] = { class = "PALADIN", name = "Blinding Light",    cd = 90, type = "disorient", spec = nil,               aoe = true,  is_pet = false },
    -- PRIEST
    [8122]  = { class = "PRIEST", name = "Psychic Scream",     cd = 60, type = "fear",    spec = nil,         aoe = true,  is_pet = false },
    [15487] = { class = "PRIEST", name = "Silence",            cd = 45, type = "silence", spec = {"Shadow"},  aoe = false, is_pet = false },
    [64044] = { class = "PRIEST", name = "Psychic Horror",     cd = 45, type = "stun",    spec = {"Shadow"},  aoe = false, is_pet = false },
    [88625] = { class = "PRIEST", name = "Holy Word: Chastise",cd = 60, type = "stun",    spec = {"Holy"},    aoe = false, is_pet = false },
    -- ROGUE
    [408]    = { class = "ROGUE", name = "Kidney Shot",       cd = 20,  type = "stun",      spec = nil,         aoe = false, is_pet = false },
    [1766]   = { class = "ROGUE", name = "Kick",              cd = 15,  type = "interrupt", spec = nil,         aoe = false, is_pet = false },
    [2094]   = { class = "ROGUE", name = "Blind",             cd = 120, type = "disorient", spec = nil,         aoe = false, is_pet = false },
    [315341] = { class = "ROGUE", name = "Between the Eyes",  cd = 45,  type = "stun",      spec = {"Outlaw"},  aoe = false, is_pet = false },
    -- SHAMAN
    [51490]  = { class = "SHAMAN", name = "Thunderstorm",     cd = 30, type = "displacement", spec = {"Elemental"},     aoe = true,  is_pet = false },
    [51514]  = { class = "SHAMAN", name = "Hex",              cd = 30, type = "disorient",    spec = nil,                aoe = false, is_pet = false },
    [57994]  = { class = "SHAMAN", name = "Wind Shear",       cd = 12, type = "interrupt",    spec = nil,                aoe = false, is_pet = false },
    [192058] = { class = "SHAMAN", name = "Capacitor Totem",  cd = 60, type = "stun",         spec = nil,                aoe = true,  is_pet = false },
    [197214] = { class = "SHAMAN", name = "Sundering",        cd = 30, type = "stun",         spec = {"Enhancement"},   aoe = true,  is_pet = false },
    [305483] = { class = "SHAMAN", name = "Lightning Lasso",  cd = 45, type = "stun",         spec = {"Elemental"},     aoe = false, is_pet = false },
    -- WARLOCK
    [5484]   = { class = "WARLOCK", name = "Howl of Terror",  cd = 40, type = "fear",      spec = nil,             aoe = true,  is_pet = false },
    [6789]   = { class = "WARLOCK", name = "Mortal Coil",     cd = 45, type = "fear",      spec = nil,             aoe = false, is_pet = false },
    [30283]  = { class = "WARLOCK", name = "Shadowfury",      cd = 60, type = "stun",      spec = nil,             aoe = true,  is_pet = false },
    [89766]  = { class = "WARLOCK", name = "Axe Toss",        cd = 30, type = "stun",      spec = {"Demonology"},  aoe = false, is_pet = true },
    [115781] = { class = "WARLOCK", name = "Optical Blast",   cd = 24, type = "interrupt", spec = {"Demonology"},  aoe = false, is_pet = true },
    [132409] = { class = "WARLOCK", name = "Spell Lock",      cd = 24, type = "interrupt", spec = nil,             aoe = false, is_pet = true },
    [212619] = { class = "WARLOCK", name = "Call Felhunter",  cd = 60, type = "interrupt", spec = nil,             aoe = false, is_pet = true },
    -- WARRIOR
    [5246]   = { class = "WARRIOR", name = "Intimidating Shout", cd = 90, type = "fear",      spec = nil,              aoe = true,  is_pet = false },
    [6552]   = { class = "WARRIOR", name = "Pummel",             cd = 15, type = "interrupt", spec = nil,              aoe = false, is_pet = false },
    [46968]  = { class = "WARRIOR", name = "Shockwave",          cd = 40, type = "stun",      spec = {"Protection"},   aoe = true,  is_pet = false },
    [107570] = { class = "WARRIOR", name = "Storm Bolt",         cd = 30, type = "stun",      spec = nil,              aoe = false, is_pet = false },
}

-- Build per-class index of interrupt entries (built lazily on first use)
local INTERRUPTS_BY_CLASS
local function BuildClassIndex()
    if INTERRUPTS_BY_CLASS then return end
    INTERRUPTS_BY_CLASS = {}
    for sid, info in pairs(INTERRUPTS_BY_SPELL_ID) do
        local list = INTERRUPTS_BY_CLASS[info.class]
        if not list then list = {}; INTERRUPTS_BY_CLASS[info.class] = list end
        list[#list + 1] = { spell_id = sid, info = info }
    end
end

-- Return the interrupt list available to (class, spec_name). spec_name
-- can be nil if unknown — in that case, we include all non-spec-restricted
-- spells (the safe lower-bound view).
local function GetInterruptsForClassSpec(class, spec_name)
    BuildClassIndex()
    local pool = INTERRUPTS_BY_CLASS[class]
    if not pool then return {} end
    local result = {}
    for _, item in ipairs(pool) do
        local spec_list = item.info.spec
        local include = false
        if not spec_list then
            include = true
        elseif spec_name then
            for _, allowed in ipairs(spec_list) do
                if allowed == spec_name then include = true; break end
            end
        end
        if include then
            result[#result + 1] = {
                spell_id  = item.spell_id,
                name      = item.info.name,
                cd        = item.info.cd,
                type      = item.info.type,
                aoe       = item.info.aoe,
                is_pet    = item.info.is_pet,
                last_used = 0,
            }
        end
    end
    return result
end

-- Get the player's current spec name, e.g. "Protection", "Retribution"
local function GetMySpecName()
    if not GetSpecialization or not GetSpecializationInfo then return nil end
    local idx = GetSpecialization()
    if not idx then return nil end
    local _, name = GetSpecializationInfo(idx)
    return name
end

local CLASS_COLOR = {
    DEATHKNIGHT  = "c41f3b",
    DEMONHUNTER  = "a330c9",
    DRUID        = "ff7d0a",
    EVOKER       = "33937f",
    HUNTER       = "abd473",
    MAGE         = "69ccf0",
    MONK         = "00ff96",
    PALADIN      = "f58cba",
    PRIEST       = "ffffff",
    ROGUE        = "fff569",
    SHAMAN       = "0070de",
    WARLOCK      = "9482c9",
    WARRIOR      = "c79c6e",
}

local ALERT_DURATION = 4

----------------------------------------------------------------------
-- Priority interrupts table — 70 entries covering ALL Midnight 12.0.5
-- content: 3 raids (16 casts) + 8 M+ dungeons (54 casts).
--
-- Sources (in order of authority):
--  1. VoidScout MechanicConfigs.lua — DBC-extracted boss casts with
--     `critical` flag, generated from Wago.tools JournalEncounter +
--     SpellName at build 12.0.5.67602. All 29 M+ bosses + 9 raid bosses
--     covered (or marked "no required interrupts"). critical=true → CRIT.
--  2. Local combat-log mining — fills in trash + raid adds that the JES
--     doesn't cover. Ratio: 50%+ interrupted = HIGH, <25% = ignored.
--  3. WCL community data — cross-checks raid casts against top-10 logs
--     per encounter. Confirmed 1284934 / 1243852 / 1243854 (Belo'ren +
--     Midnight Falls). M+ WCL endpoint returns HTTP 400, so M+ relies on
--     pipelines 1 and 2.
--
-- Re-run pipelines:
--   wow-addons/voidscout-data/interrupt_priority_analysis.py [N]
--   wow-addons/voidscout-data/wcl_interrupt_aggregator.py --top 10
--
-- Bosses with zero priority casts (Vorasius, Vaelgor & Ezzorak, Crown of
-- the Cosmos lowest casts) are positional/avoidance fights — verified by
-- both DBC and WCL community kick rate < 25%. Not a coverage gap.
----------------------------------------------------------------------
local PRIORITY_INTERRUPTS = {
    -- RAID: Dreamrift
    [1245406] = { name = "Fearsome Cry",        priority = "CRITICAL" },  -- Chimaerus, the Undreamt God
    [1262020] = { name = "Essence Bolt V1",     priority = "HIGH" },      -- Chimaerus, the Undreamt God
    [1262053] = { name = "Essence Bolt V2",     priority = "HIGH" },      -- Chimaerus, the Undreamt God
    [1262059] = { name = "Essence Bolt V3",     priority = "HIGH" },      -- Chimaerus, the Undreamt God
    [1249017] = { name = "Fearsome Cry",        priority = "HIGH" },      -- Haunting Essence (Chim adds)

    -- RAID: March on Quel'Danas
    [1243852] = { name = "Light Eruption",      priority = "CRITICAL" },  -- Belo'ren, Child of Al'ar
    [1282412] = { name = "Core Harvest",        priority = "CRITICAL" },  -- Midnight Falls
    [1284934] = { name = "Midnight Phase",      priority = "CRITICAL" },  -- Midnight Falls/L'ura (WCL 100%)
    [1243854] = { name = "Void Eruption",       priority = "HIGH" },      -- Belo'ren (WCL 72%)

    -- RAID: Voidspire
    [1260000] = { name = "Void Barrage",        priority = "CRITICAL" },  -- Crown of the Cosmos
    [1254088] = { name = "Shadow Fracture",     priority = "CRITICAL" },  -- Fallen-King Salhadaar
    [1255702] = { name = "Pitch Bulwark",       priority = "CRITICAL" },  -- Imperator Averzian
    [1258514] = { name = "Blinding Light",      priority = "CRITICAL" },  -- Lightblinded Vanguard
    [1245175] = { name = "Voidbolt",            priority = "CRITICAL" },  -- Vaelgor & Ezzorak
    [1275059] = { name = "Black Miasma",        priority = "HIGH" },      -- Abyssal Malus (Imperator adds)
    [1217610] = { name = "Devour",              priority = "HIGH" },      -- Crown of the Cosmos

    -- M+: Algeth'ar Academy
    [376467]  = { name = "Gale Force",          priority = "HIGH" },      -- Crawth
    [389481]  = { name = "Searing Blaze",       priority = "HIGH" },      -- Crawth
    [1282251] = { name = "Astral Blast",        priority = "HIGH" },      -- Echo of Doragosa

    -- M+: Magisters' Terrace
    [474407]  = { name = "Arcane Empowerment",  priority = "CRITICAL" },  -- Arcanotron Custos
    [1215897] = { name = "Devouring Entropy",   priority = "CRITICAL" },  -- Degentrius
    [248831]  = { name = "Dread Screech",       priority = "CRITICAL" },  -- Shadewing (trash)
    [468966]  = { name = "Polymorph",           priority = "HIGH" },      -- Arcane Magister (trash)
    [474496]  = { name = "Repulsing Slam",      priority = "HIGH" },      -- Arcanotron Custos
    [473794]  = { name = "Poison Blades",       priority = "HIGH" },      -- Ardent Cutthroat (trash)
    [1254294] = { name = "Pyroblast",           priority = "HIGH" },      -- Blazing Pyromancer (trash)
    [1262510] = { name = "Umbral Bolt",         priority = "HIGH" },      -- Dark Conjurer (trash)
    [1271066] = { name = "Entropy Blast",       priority = "HIGH" },      -- Degentrius
    [1216592] = { name = "Chain Lightning",     priority = "HIGH" },      -- Phantasmal Mystic (trash)

    -- M+: Maisara Caverns
    [1251554] = { name = "Drain Soul",          priority = "CRITICAL" },  -- Vordaza
    [1216819] = { name = "Fungal Bolt",         priority = "HIGH" },      -- Bloated Lasher (trash)
    [1262526] = { name = "Abyssal Enhancement", priority = "HIGH" },      -- Dire Voidbender (trash)
    [1260643] = { name = "Barrage",             priority = "HIGH" },      -- Muro'jin and Nekraxx
    [1252676] = { name = "Crush Souls",         priority = "HIGH" },      -- Rak'tul, Vessel of Souls

    -- M+: Nexus-Point Xenas
    [1252883] = { name = "Devour the Unworthy", priority = "CRITICAL" },  -- Corewarden Nysarra
    [1247976] = { name = "Lightscar Flare",     priority = "HIGH" },      -- Corewarden Nysarra
    [1251392] = { name = "Safeguard",           priority = "HIGH" },      -- Safeguard Matrix (trash)

    -- M+: Pit of Saron
    [1276648] = { name = "Bone Infusion",       priority = "CRITICAL" },  -- Scourgelord Tyrannus
    [1276391] = { name = "Infused Bone Piles",  priority = "CRITICAL" },  -- Scourgelord Tyrannus
    [1278893] = { name = "Death Bolt",          priority = "HIGH" },      -- Ick and Krick
    [1264287] = { name = "Blight Smash",        priority = "HIGH" },      -- Ick and Krick
    [1262941] = { name = "Plague Bolt",         priority = "HIGH" },      -- Scourgelord Tyrannus
    [1262745] = { name = "Rime Blast",          priority = "HIGH" },      -- Scourgelord Tyrannus
    [1276948] = { name = "Ice Barrage",         priority = "HIGH" },      -- Scourgelord Tyrannus

    -- M+: Seat of the Triumvirate
    [1254928] = { name = "Entropic Bolt",       priority = "CRITICAL" },  -- Cosmic Ascendant (trash)
    [1263508] = { name = "Umbral Nova",         priority = "CRITICAL" },  -- Saprish
    [1263542] = { name = "Mass Void Infusion",  priority = "CRITICAL" },  -- Viceroy Nezhar
    [1265030] = { name = "Void Storm",          priority = "CRITICAL" },  -- Viceroy Nezhar
    [1264693] = { name = "Terror Wave",         priority = "CRITICAL" },  -- Void Terror (trash)
    [1265464] = { name = "Discordant Beam",     priority = "HIGH" },      -- L'ura
    [244750]  = { name = "Mind Blast",          priority = "HIGH" },      -- Viceroy Nezhar
    [1263399] = { name = "Oozing Slam",         priority = "HIGH" },      -- Zuraal the Ascended

    -- M+: Skyreach
    [1252877] = { name = "Solar Infusion",      priority = "CRITICAL" },  -- Araknath
    [156793]  = { name = "Chakram Vortex",      priority = "CRITICAL" },  -- Ranjit
    [154132]  = { name = "Fiery Smash",         priority = "HIGH" },      -- Araknath
    [154150]  = { name = "Light Ray",           priority = "HIGH" },      -- Araknath
    [1279002] = { name = "Blast Wave",          priority = "HIGH" },      -- Araknath
    [153954]  = { name = "Cast Down",           priority = "HIGH" },      -- High Sage Viryx
    [154044]  = { name = "Lens Flare",          priority = "HIGH" },      -- High Sage Viryx
    [154396]  = { name = "Solar Blast",         priority = "HIGH" },      -- High Sage Viryx
    [1253543] = { name = "Scorching Ray",       priority = "HIGH" },      -- High Sage Viryx
    [1252691] = { name = "Gale Surge",          priority = "HIGH" },      -- Ranjit
    [1253416] = { name = "Blaze of Glory",      priority = "HIGH" },      -- Rukhran

    -- M+: Windrunner Spire
    [1270620] = { name = "Flame Nova",          priority = "CRITICAL" },  -- Commander Kroluk
    [472662]  = { name = "Tempest Slash",       priority = "CRITICAL" },  -- Restless Heart
    [472724]  = { name = "Shadow Bolt",         priority = "HIGH" },      -- Derelict Duo
    [465904]  = { name = "Burning Gale",        priority = "HIGH" },      -- Emberdawn
    [1253986] = { name = "Gust Shot",           priority = "HIGH" },      -- Restless Heart
    [472556]  = { name = "Arrow Rain",          priority = "HIGH" },      -- Restless Heart
    [474528]  = { name = "Bolt Gale",           priority = "HIGH" },      -- Restless Heart
}

local function IsPrioritySpell(spell_id)
    if not spell_id then return false end
    if issecretvalue and issecretvalue(spell_id) then return false end
    return PRIORITY_INTERRUPTS[spell_id] ~= nil
end

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function dbg(fmt, ...)
    if not (VRT and VRT:ModuleSettings(M.id).debug) then return end
    VRT:Print(("[Kick] " .. fmt):format(...))
end

local function NormalizeName(n) return n and n:match("^([^-]+)") or n end

----------------------------------------------------------------------
-- Group detection
----------------------------------------------------------------------
local function FreshHello(name)
    local seen = M.state.vrt_seen[name]
    if not seen then return false end
    return (GetTime() - (seen.t or 0)) < HELLO_STALE_AFTER
end

local function DetectGroup()
    local members = {}
    local order   = {}
    BuildClassIndex()
    -- Add self (always has VRT, that's us)
    do
        local n = UnitName("player")
        local _, c = UnitClass("player")
        local spec = GetMySpecName()
        if n and c and INTERRUPTS_BY_CLASS[c] then
            members[n] = {
                class      = c,
                spec       = spec,
                interrupts = GetInterruptsForClassSpec(c, spec),
                unit       = "player",
                has_vrt    = true,
            }
            table.insert(order, n)
        end
    end
    -- Group members. Use raidN units when in a raid (covers up to 40
    -- members), partyN otherwise. In a raid, raid1 maps to the player
    -- themselves — we skip any unit that IsUnit("player") to avoid
    -- double-adding self.
    local me_name = UnitName("player")
    local in_raid = IsInRaid and IsInRaid()
    local prefix, count
    if in_raid then
        prefix, count = "raid", 40
    else
        prefix, count = "party", 4
    end
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local n = UnitName(unit)
            local _, c = UnitClass(unit)
            if n and n ~= me_name and c and INTERRUPTS_BY_CLASS[c] then
                local seen = M.state.vrt_seen[n]
                local fresh = seen and (GetTime() - (seen.t or 0)) < HELLO_STALE_AFTER
                local their_class = (fresh and seen.class) or c
                local their_spec  = fresh and seen.spec or nil
                members[n] = {
                    class      = their_class,
                    spec       = their_spec,
                    interrupts = GetInterruptsForClassSpec(their_class, their_spec),
                    unit       = unit,
                    has_vrt    = fresh and true or false,
                }
                table.insert(order, n)
            end
        end
    end
    M.state.members = members
    M.state.priority_order = order
end

----------------------------------------------------------------------
-- Rotation logic
----------------------------------------------------------------------
-- A member is "ready to kick" if ANY of their interrupts is off cooldown.
-- A Paladin with Rebuke off CD AND Avenger's Shield off CD can kick twice,
-- but for rotation purposes they're "ready" if either is ready.
local function IsReady(member)
    if not member or not member.interrupts then return false end
    local now = GetTime()
    for _, ip in ipairs(member.interrupts) do
        if (now - (ip.last_used or 0)) >= (ip.cd or 30) then return true end
    end
    return false
end

-- Soonest a member's next interrupt comes ready (0 if any is ready now).
local function SoonestReadyIn(member)
    if not member or not member.interrupts or #member.interrupts == 0 then return 0 end
    local now = GetTime()
    local soonest = math.huge
    for _, ip in ipairs(member.interrupts) do
        local remaining = (ip.cd or 30) - (now - (ip.last_used or 0))
        if remaining < 0 then remaining = 0 end
        if remaining < soonest then soonest = remaining end
    end
    if soonest == math.huge then return 0 end
    return soonest
end

local function GetNextKicker()
    local s = M.state
    local soonest_ready, soonest_name
    for _, name in ipairs(s.priority_order) do
        local m = s.members[name]
        if m and m.has_vrt then
            if IsReady(m) then return name, m end
            local remaining = SoonestReadyIn(m)
            if not soonest_ready or remaining < soonest_ready then
                soonest_ready = remaining
                soonest_name  = name
            end
        end
    end
    return soonest_name, soonest_name and s.members[soonest_name] or nil
end

----------------------------------------------------------------------
-- Floating display
----------------------------------------------------------------------
local function BuildFrame()
    if M.state.floating_frame then return end
    if InCombatLockdown() then return end

    local f = CreateFrame("Frame", "VRT_KickRotation", UIParent, "BackdropTemplate")
    f:SetSize(260, 100)
    f:SetPoint("CENTER", UIParent, "CENTER", -300, -80)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.55)
    f:SetBackdropBorderColor(0.3, 0.6, 1, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", 0, -6)
    title:SetTextColor(0.6, 0.9, 1)
    title:SetText("|cff60d0ffKick Rotation|r")
    f.title = title

    local next_text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    next_text:SetPoint("TOP", title, "BOTTOM", 0, -6)
    next_text:SetTextColor(1, 1, 1)
    f.next_text = next_text

    local list_text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    list_text:SetPoint("TOP", next_text, "BOTTOM", 0, -4)
    list_text:SetPoint("LEFT", 8, 0)
    list_text:SetPoint("RIGHT", -8, 0)
    list_text:SetJustifyH("CENTER")
    list_text:SetTextColor(0.7, 0.7, 0.75)
    f.list_text = list_text

    f:Hide()
    M.state.floating_frame = f

    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "kickrotation.frame",
            frame = f,
            label = "Kick Rotation",
            default_point = { point = "CENTER", relPoint = "CENTER", x = -300, y = -80 },
        })
    end
end

local function RenderFrame()
    local f = M.state.floating_frame
    if not f then return end
    local s = M.state
    if #s.priority_order == 0 then
        f.next_text:SetText("|cff808080(no kickers)|r")
        f.list_text:SetText(" ")
        return
    end
    local next_name, next_member = GetNextKicker()
    if next_name and next_member then
        local color = CLASS_COLOR[next_member.class] or "ffffff"
        local ready = IsReady(next_member)
        local prefix = ready and "|cff80ff80UP NEXT|r" or "|cffffff40SOON|r"
        f.next_text:SetText(("%s: |cff%s%s|r"):format(prefix, color, next_name))
    end
    -- Render the on-deck list. Tracked = class color + CD timer.
    -- Untracked (no VRT) = grey + "(?)" — we can't see their kicks.
    --
    -- Cap to MAX_ON_DECK names so a 20-man raid doesn't push the list
    -- out of the bottom of the box. Anything beyond gets a "+N more"
    -- suffix so the count is still visible.
    local MAX_ON_DECK = 4
    local pieces = {}
    local skipped = 0
    for _, name in ipairs(s.priority_order) do
        local m = s.members[name]
        if m and name ~= next_name then
            if #pieces < MAX_ON_DECK then
                if m.has_vrt then
                    local color = CLASS_COLOR[m.class] or "ffffff"
                    local remaining = SoonestReadyIn(m)
                    local status
                    if remaining <= 0 then status = "rdy"
                    else status = ("%.0fs"):format(remaining) end
                    table.insert(pieces, ("|cff%s%s|r(%s)"):format(color, name, status))
                else
                    table.insert(pieces, ("|cff707075%s(?)|r"):format(name))
                end
            else
                skipped = skipped + 1
            end
        end
    end
    if skipped > 0 then
        table.insert(pieces, ("|cff8c8c9e+%d more|r"):format(skipped))
    end
    f.list_text:SetText(table.concat(pieces, " . "))
end

----------------------------------------------------------------------
-- Active-cast tracking (Phase 2): multiple hostile casts can be in
-- flight at once during a chain pull. Track each by GUID; render the
-- most urgent (lowest time remaining) + a "+N more" indicator.
--
-- Pruning happens in the frame's OnUpdate tick — anything whose
-- end_time has passed is dropped. We also drop entries on
-- UNIT_SPELLCAST_STOP / SUCCEEDED / INTERRUPTED / FAILED for that unit.
----------------------------------------------------------------------
local function HasAnyActiveCast()
    for _ in pairs(M.state.active_casts) do return true end
    return false
end

local function PruneExpiredCasts()
    local now = GetTime()
    local removed = false
    for guid, cast in pairs(M.state.active_casts) do
        if cast.end_time <= now then
            M.state.active_casts[guid] = nil
            removed = true
        end
    end
    return removed
end

local function GetMostUrgentCast()
    local best, count = nil, 0
    for _, cast in pairs(M.state.active_casts) do
        count = count + 1
        if not best or cast.end_time < best.end_time then best = cast end
    end
    return best, count
end

local function RenderAlertOverlay()
    local f = M.state.floating_frame
    if not f then return false end
    PruneExpiredCasts()
    local urgent, count = GetMostUrgentCast()
    if not urgent then
        -- No active casts — back to normal rotation render
        f:SetBackdropColor(0.04, 0.04, 0.06, 0.55)
        f:SetBackdropBorderColor(0.3, 0.6, 1, 0.85)
        return false
    end
    local next_name, next_member = GetNextKicker()
    if not next_name then return false end
    -- Alert appearance
    f:SetBackdropColor(0.20, 0.05, 0.05, 0.65)
    f:SetBackdropBorderColor(1, 0.3, 0.1, 1)
    local color = CLASS_COLOR[next_member.class] or "ffffff"
    f.next_text:SetText(("|cffff4040KICK NOW:|r |cff%s%s|r"):format(color, next_name))
    local time_left = math.max(0, urgent.end_time - GetTime())
    local extra = ""
    if count > 1 then extra = (" |cff8c8c9e+%d more|r"):format(count - 1) end
    f.list_text:SetText(("on |cffffd700%s|r (%s, %.1fs)%s"):format(
        urgent.mob_name or "?", urgent.spell_name or "?", time_left, extra))
    return true
end

----------------------------------------------------------------------
-- FlashAlert — pulses the panel's next_text + border for ~3 seconds.
-- Called by the poly-detector path to draw the eye without spamming
-- center-screen warnings.
----------------------------------------------------------------------
function M:FlashAlert(duration, label)
    duration = duration or 3.0
    label    = label or "marked cast — KICK"
    local f = M.state.floating_frame
    if not f or not f.next_text then return end
    local started = GetTime()
    if f.flash_ticker then f.flash_ticker:Cancel() end
    f.flash_ticker = C_Timer.NewTicker(0.15, function(ticker)
        local elapsed = GetTime() - started
        if elapsed >= duration then
            ticker:Cancel()
            f.flash_ticker = nil
            f:SetBackdropBorderColor(0.3, 0.6, 1, 0.85)
            return
        end
        local phase = math.floor(elapsed * 6) % 2
        if phase == 0 then
            f.next_text:SetText("|cffffcc00>> " .. label .. " <<|r")
            f:SetBackdropBorderColor(1, 0.8, 0.2, 1)
        else
            f.next_text:SetText("|cffffffff>> " .. label .. " <<|r")
            f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        end
    end)
end

----------------------------------------------------------------------
-- Event handlers
----------------------------------------------------------------------
function M:OnUnitAura(unit) end  -- not used; kept for Core dispatch compat

-- Self-only kick detection. Each VRT user detects THEIR OWN cast of any
-- interrupt-capable spell (Mind Freeze, Death Grip on a caster, Avenger's
-- Shield, etc.) and broadcasts on the addon channel. Other clients update
-- via the broadcast. We never listen to party1-4 UNIT_SPELLCAST_* events.
--
-- Match path: spell_id → INTERRUPTS_BY_SPELL_ID lookup → find the
-- matching entry in our own member.interrupts list → mark that specific
-- interrupt as used. A Paladin Prot using AS marks AS; a later Rebuke
-- marks Rebuke independently.
local function HandleSelfCastSucceeded(unit, spell_id)
    if unit ~= "player" then return end
    if not spell_id then return end
    local info = INTERRUPTS_BY_SPELL_ID[spell_id]
    if not info then return end
    local n = UnitName("player")
    if not n then return end
    local m = M.state.members[n]
    if not m or not m.interrupts then return end
    for _, ip in ipairs(m.interrupts) do
        if ip.spell_id == spell_id then
            ip.last_used = GetTime()
            if VRT and VRT.SendModuleMessage then
                VRT:SendModuleMessage(M.id, "KICKED", n .. "|" .. tostring(spell_id))
            end
            RenderFrame()
            return
        end
    end
end

----------------------------------------------------------------------
-- Phase 2 (priority-cast alerts) is DISABLED.
--
-- UnitCastingInfo on hostile units is secret-tainted in 12.0.5 M+ — any
-- access to spell_id / name / notInterruptible / endTimeMS propagates
-- taint and breaks our SecureActionButton chain (taunt/sequence buttons
-- stop firing, "addon blocked from action" pop-up appears).
--
-- CLEU is the read-only path DBM uses, but the multiple-assignment from
-- CombatLogGetCurrentEventInfo() captures secret-tainted srcGUID/srcName/
-- dstGUID/dstName into local variables in our scope — enough to taint
-- the addon execution context even if we never USE those locals by name.
-- Confirmed in-game 2026-06-06: enabling CLEU triggered the "blocked"
-- pop-up on next button press.
--
-- A proper CLEU implementation would need to live in a SEPARATE addon
-- (taint is per-addon, not per-frame), or to use a wrapper that strips
-- secret values before returning them. Until then, KickRotation runs
-- Phase 1 only: rotation display + friendly cast tracking.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- HELLO handshake
--
-- Each VRT client broadcasts a HELLO on group join and every HELLO_PERIOD
-- seconds. Recipients note the timestamp. DetectGroup uses recent HELLOs
-- to mark members has_vrt = true. Members without recent HELLO render
-- as greyed "(?)" and are skipped by GetNextKicker (we can't see their
-- kicks, so they'd never advance).
----------------------------------------------------------------------
-- HELLO includes class+spec so receivers can build the right interrupt
-- list for each VRT-running party member. Format: "<name>|<class>|<spec>"
local function BroadcastHello()
    local n = UnitName("player")
    if not n then return end
    local _, c = UnitClass("player")
    local spec = GetMySpecName() or ""
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "HELLO", n .. "|" .. (c or "") .. "|" .. spec)
    end
end

function M:OnAddonMessage(kind, data, sender)
    if kind == "KICKED" then
        local who, sid = data:match("^(.+)|(%d+)$")
        if not who then return end
        sid = tonumber(sid)
        local m = M.state.members[who]
        if not m or not m.interrupts then return end
        for _, ip in ipairs(m.interrupts) do
            if ip.spell_id == sid then
                -- Avoid double-counting our own broadcast (we already
                -- marked this interrupt in HandleSelfCastSucceeded)
                if (GetTime() - (ip.last_used or 0)) < 1 then return end
                ip.last_used = GetTime()
                RenderFrame()
                return
            end
        end
    elseif kind == "HELLO" then
        local who, cls, spec = data:match("^([^|]+)|([^|]*)|([^|]*)$")
        if not who then
            -- Backward-compat: old HELLO format was just "<name>"
            who = data:match("^([^|]+)$")
            cls, spec = nil, nil
        end
        if not who then return end
        if spec == "" then spec = nil end
        if cls == "" then cls = nil end
        M.state.vrt_seen[who] = { t = GetTime(), class = cls, spec = spec }
        -- If they're in our roster and we just learned their class/spec,
        -- rebuild their interrupt list and flip them tracked.
        local m = M.state.members[who]
        if m then
            local class_changed = cls and m.class ~= cls
            local spec_changed = (spec or "") ~= (m.spec or "")
            if class_changed or spec_changed or not m.has_vrt then
                m.has_vrt = true
                if cls then m.class = cls end
                if spec then m.spec = spec end
                m.interrupts = GetInterruptsForClassSpec(m.class, m.spec)
                RenderFrame()
            end
        end
    end
end

----------------------------------------------------------------------
-- Wire up native events that Core doesn't already dispatch
----------------------------------------------------------------------
local event_frame
local function SetupEventFrame()
    if event_frame then return end
    event_frame = CreateFrame("Frame")
    event_frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    event_frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    event_frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    -- Self-only: detect MY OWN kick, broadcast, let other VRT clients
    -- update via the addon channel. Listening to party1-4 cast events
    -- directly is the taint vector (their spell_id can be secret when
    -- their target is a hidden-identity enemy).
    event_frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    event_frame:SetScript("OnEvent", function(_, event, unit, _, spell_id)
        if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            DetectGroup()
            M:UpdateInstanceVisibility()
            C_Timer.After(math.random() * 2, BroadcastHello)
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            -- My spec changed; rebuild my own interrupt list AND tell peers
            -- so theirs reflect it too.
            DetectGroup()
            RenderFrame()
            BroadcastHello()
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            HandleSelfCastSucceeded(unit, spell_id)
        end
    end)
end

----------------------------------------------------------------------
-- Auto-visibility: show the rotation frame whenever the player is in
-- a dungeon or raid instance (so it covers trash kicks too, not just
-- boss encounters). Hidden in cities, open world, scenarios.
----------------------------------------------------------------------
function M:UpdateInstanceVisibility()
    if not self.state.floating_frame then return end
    if not IsInInstance then return end
    local inInstance, instType = IsInInstance()
    if inInstance and (instType == "party" or instType == "raid") then
        self.state.floating_frame:Show()
        RenderFrame()
    else
        self.state.floating_frame:Hide()
    end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
function M:OnInit()
    -- Seed math.random so HELLO jitter actually jitters per-client.
    -- Without this, every client's first math.random() returns the same
    -- value and HELLOs collide on every group entry.
    if math.randomseed then math.randomseed((GetTime and GetTime() or 0) * 1000) end
    BuildFrame()
    SetupEventFrame()
    DetectGroup()
    -- Frame OnUpdate ticker: 5x/sec for snappy alert countdown,
    -- 1x/sec for the on-deck rotation CD display.
    if M.state.floating_frame then
        local fast_elapsed = 0
        local slow_elapsed = 0
        local hello_elapsed = 0
        M.state.floating_frame:HookScript("OnUpdate", function(_, dt)
            fast_elapsed = fast_elapsed + dt
            slow_elapsed = slow_elapsed + dt
            hello_elapsed = hello_elapsed + dt
            if fast_elapsed >= 0.2 then
                fast_elapsed = 0
                if HasAnyActiveCast() then
                    if PruneExpiredCasts() and not HasAnyActiveCast() then
                        RenderFrame()
                    elseif HasAnyActiveCast() then
                        RenderAlertOverlay()
                    end
                end
            end
            if slow_elapsed >= 1 then
                slow_elapsed = 0
                -- Detect peers who fell off (no HELLO within HELLO_STALE_AFTER)
                -- and re-render so they grey out without waiting for a roster
                -- update.
                local dirty = false
                for name, m in pairs(M.state.members) do
                    if name ~= UnitName("player") then
                        local fresh = FreshHello(name)
                        if m.has_vrt ~= fresh then
                            m.has_vrt = fresh
                            dirty = true
                        end
                    end
                end
                if not HasAnyActiveCast() or dirty then RenderFrame() end
            end
            if hello_elapsed >= HELLO_PERIOD then
                hello_elapsed = 0
                BroadcastHello()
            end
        end)
        RenderFrame()
    end
    -- If we're already in a dungeon/raid at addon load (e.g. /reload
    -- mid-key), show the frame immediately.
    self:UpdateInstanceVisibility()
end

function M:OnEncounterStart(eid)
    -- Make sure frame is showing for boss pulls too (in case visibility
    -- check missed; e.g. user manually hid it earlier in the dungeon)
    if M.state.floating_frame then M.state.floating_frame:Show() end
    DetectGroup()
    RenderFrame()
end

function M:OnEncounterEnd(eid)
    -- Stay visible for trash too; only hide on explicit user action
end

----------------------------------------------------------------------
-- Panel actions
----------------------------------------------------------------------
M.actions = {
    { label = "Show Kick Frame", action = function()
        if not M.state.floating_frame then BuildFrame() end
        if M.state.floating_frame then M.state.floating_frame:Show() end
        DetectGroup()
        RenderFrame()
    end },
    { label = "Hide Kick Frame", action = function()
        if M.state.floating_frame then M.state.floating_frame:Hide() end
    end },
    { label = "Re-detect Group", action = function()
        DetectGroup()
        RenderFrame()
        VRT:Print(("Kick Rotation: detected %d kickers."):format(#M.state.priority_order))
    end },
    { label = "Toggle Debug", action = function()
        local s = VRT:ModuleSettings(M.id)
        s.debug = not s.debug
        VRT:Print("KickRotation debug: " .. (s.debug and "ON" or "OFF"))
    end },
}

----------------------------------------------------------------------
-- Register
----------------------------------------------------------------------
if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end
