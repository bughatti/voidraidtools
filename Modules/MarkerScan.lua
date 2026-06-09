----------------------------------------------------------------------
-- VoidRaidTools — MarkerScan
--
-- ONE keybind. Tank presses it when approaching any pull. The bound
-- SecureActionButton runs a macro that tries to /targetexact each
-- priority mob in the current dungeon, and if the engine finds a
-- match in nameplate range, places a raid-target marker via
-- SetRaidTarget. Already-marked mobs are skipped (so you can press
-- it repeatedly across positions to mark multiple).
--
-- DESIGN INVARIANTS (don't change without thinking through):
--   - The macrotext is updated ONLY on ZONE_CHANGED_NEW_AREA, which
--     fires out of combat. SetAttribute is combat-locked, so we
--     can't dynamically swap mid-pull — but we don't need to,
--     since each dungeon ships its full priority list and unused
--     /target calls silently no-op.
--   - GetRaidTargetIndex on hostile mobs returns SECRET in
--     instances — but `== nil` is the one Lua operation always
--     allowed on secret values, so `GetRaidTargetIndex(unit) == nil`
--     is the clean "is this mob unmarked?" check inside the macro.
--   - SetRaidTarget on a hostile mob in instance from a slash
--     command gets taint-blocked (we confirmed this). But the same
--     call from a SAB-driven macro keypress works — the hardware
--     event provides the clean context Blizzard wants.
----------------------------------------------------------------------

local M = {
    id   = "markerscan",
    name = "Marker Scan",
    description = "One key — auto-marks priority kick/dispel/CC mobs in the current dungeon.",
}

----------------------------------------------------------------------
-- Per-dungeon priority lists.
--
-- Seed with MT for first-pass testing. Each entry: { name, marker }
-- where marker is 1..8 (skull=8, X=7, square=6, triangle=5, ...).
-- Order matters — engine targets the first matching name with
-- /targetexact, so put the highest-priority mob first.
--
-- Phase 2 will load these from the route DB / server bundle.
----------------------------------------------------------------------
local PRIORITY_LISTS = {
    ["Magisters' Terrace"] = {
        -- Arcane Magister 232369: Arcane Bolt (468962, 2.5s) + Polymorph
        -- (468966, 3.5s). Mark up to 3 with skull → X → square so the
        -- kick rotation can split coverage: kicker A takes skull, kicker
        -- B takes X. Two-tier alert (2.7s) handles Bolt vs Poly.
        { name = "Arcane Magister", markers = {8, 7, 6} },
        -- Void Infuser 249086: Terror Wave (1264693, 4.0s, interruptible).
        -- Only castable spell on this mob — instants for the rest. So
        -- ANY cast event = Terror Wave = guaranteed HARD alert at 2.7s
        -- (1.3s remaining kick window). Group-wiping AoE fear + root.
        -- Mark up to 3 with triangle → moon → diamond — distinct from
        -- Magister markers so the visual stays unambiguous.
        { name = "Void Infuser",    markers = {5, 4, 3} },
    },
    -- Add other dungeons as we test them
}

local MARKER_NAMES = {
    [1] = "Star", [2] = "Circle", [3] = "Diamond", [4] = "Triangle",
    [5] = "Moon", [6] = "Square", [7] = "X",       [8] = "Skull",
}

----------------------------------------------------------------------
-- Build the macrotext for a priority list.
--
-- For each entry, the macro:
--   /targetexact <name>             - engine targets closest match by name
--   /run conditional SetRaidTarget  - mark with the planned index, but
--                                     ONLY if target is hostile + unmarked
-- After all entries: /targetlasttarget - restore tank's previous focus.
--
-- Total per-entry size: ~135 chars. WoW's SAB macrotext caps at
-- ~1023 chars, so we can fit ~7 priorities per dungeon. Plenty.
----------------------------------------------------------------------
-- Per-priority candidate finder. Returns a one-line Lua /run that walks
-- the nameplate list, finds the FIRST UNMARKED hostile that matches the
-- filter, and targets it. Then /tm places the marker.
--
-- Walking nameplates (not /targetexact NAME) is the only way to mark
-- the SECOND copy of a same-name mob in a pull — /targetexact always
-- picks the closest match, even when you press twice. The walk picks
-- the closest UNMARKED match, so subsequent presses pick subsequent
-- mobs.
--
-- Per-priority filter uses clean fields confirmed in identity_probes:
--   UnitClassification(unit) == "elite"        (always clean)
--   UnitCreatureFamily(unit) is nil OR string  (clean: type() check)
--     - nil    = humanoid (Magisters)
--     - string = has creature family (Sentries, Void Infusers, etc.)
--   GetRaidTargetIndex(unit) == nil            (clean: == nil is allowed)
--
-- Single line so it fits in macro size limits. Uses [[long-strings]]
-- so the WoW macro parser doesn't choke on embedded quotes.
-- /targetexact is the only safe target-by-name path inside a SAB macro
-- chain that also wants /tm to fire afterward. Here's why:
--
--   /targetexact NAME → resolves name in C-side engine code, Lua never
--                       reads the hostile mob's secret-tainted data.
--                       Calling chain stays clean → /tm can mark.
--
--   Lua-side walker that reads UnitCreatureFamily(u) on a hostile mob
--   to filter humanoid vs aberration → propagates secret-value taint
--   through the call chain, even though type() launders the return.
--   /tm afterward then fails with "blocked from action" popup because
--   SetRaidTarget (called internally by /tm) refuses to run on a
--   tainted chain. We verified this empirically — the walker tripped
--   the popup, /targetexact NAME does not.
--
-- Tradeoff: /targetexact picks closest match, can't easily target
-- multiple same-name mobs in one macro press. For now we accept the
-- "one priority marker per mob type" limit and let users press F
-- multiple times (after the first mob dies or repositioning) to
-- mark subsequent same-name mobs.
local function buildFinderLine(name)
    return "/targetexact " .. name
end

-- Legacy compatibility shim; no longer used after revert to /targetexact.
local function familyFor(name)
    -- Arcane Magister: humanoid → nil
    -- Void Infuser:    aberration → string
    -- Arcane Sentry:   elemental → string (if added later)
    if name == "Arcane Magister" then return "nil" end
    return "string"  -- default to non-humanoid for everything else
end

local function buildMacroText(priorities)
    if not priorities or #priorities == 0 then
        return "/targetlasttarget"  -- no-op fallback
    end
    -- For each priority, we expand a finder+/tm pair per marker in the
    -- markers list. The finder walks nameplates looking for unmarked
    -- matches, so each iteration grabs the NEXT unmarked mob of that
    -- kind. One press of the key marks up to N mobs of each type with
    -- distinct raid markers.
    --
    --   Press 1, pull has 2 Magisters + 1 Void Infuser:
    --     finder → Magister A (closest unmarked humanoid) → /tm 8 skull
    --     finder → Magister B (A marked, skip)            → /tm 7 X
    --     finder → no unmarked Magister                   → /tm 6 no-op
    --     finder → Void Infuser X                         → /tm 5 triangle
    --     finder → no unmarked aberration                 → /tm 4 no-op
    --     finder → no unmarked aberration                 → /tm 3 no-op
    --     restore tank's previous target
    --
    --   Press 2 (after Magister A dies):
    --     A's nameplate is gone, so finder counts only B (marked) +
    --     any new spawns. Next-press picks up any newly-alive Magister.
    --
    -- The /tm on no target is a silent no-op — Blizzard handles it
    -- cleanly when target was cleared after a failed finder pass.
    -- Each priority resolves to ONE /targetexact (engine picks closest
    -- match) + ONE /tm. We take the FIRST marker from each priority's
    -- list — multi-marker per mob-type is on hold pending a non-tainting
    -- way to mark multiple same-name mobs in one press.
    local lines = {}
    for _, p in ipairs(priorities) do
        local marker = (p.markers and p.markers[1]) or p.marker
        if marker then
            lines[#lines + 1] = buildFinderLine(p.name)
            lines[#lines + 1] = "/tm " .. tostring(marker)
        end
    end
    lines[#lines + 1] = "/targetlasttarget"
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- The SecureActionButton itself.
----------------------------------------------------------------------
local sab

local function ensureSAB()
    if sab then return sab end
    sab = CreateFrame("Button", "VRT_MarkerScanButton", UIParent,
                      "SecureActionButtonTemplate")
    sab:RegisterForClicks("AnyDown", "AnyUp")
    sab:SetAttribute("type", "macro")
    sab:SetAttribute("macrotext", "/targetlasttarget")  -- safe default
    return sab
end

----------------------------------------------------------------------
-- Refresh macrotext based on current zone.
----------------------------------------------------------------------
local current_dungeon = nil
local last_macro_set  = nil

local function refreshMacrotext(reason)
    local b = ensureSAB()
    if InCombatLockdown() then
        -- Defer until combat ends. RegisterEvent for PLAYER_REGEN_ENABLED
        -- handles the deferred update below.
        return false, "combat lockdown"
    end
    local _, instanceType, _, _, _, _, _, _, _ = GetInstanceInfo()
    local zone = GetRealZoneText() or GetZoneText() or ""
    local priorities = PRIORITY_LISTS[zone]
    current_dungeon = priorities and zone or nil
    local macroText = buildMacroText(priorities)
    if macroText ~= last_macro_set then
        b:SetAttribute("macrotext", macroText)
        last_macro_set = macroText
        -- Silent. /vrtmark status will tell the user what's loaded if they
        -- want to check. Zone-change announcements were noisy in chat.
    end
    return true
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_VRTMARK1 = "/vrtmark"
SlashCmdList["VRTMARK"] = function(arg)
    local b = ensureSAB()
    arg = (arg or ""):lower():match("^%s*(.-)%s*$")
    if arg == "" or arg == "status" then
        print("|cff00c7ff[VRT MarkerScan]|r")
        print("  Current zone: " .. (GetRealZoneText() or "?"))
        local pri = current_dungeon and PRIORITY_LISTS[current_dungeon]
        if pri then
            print("  Loaded priorities for " .. current_dungeon .. ":")
            for _, p in ipairs(pri) do
                print(("    %s -> %s"):format(p.name, MARKER_NAMES[p.marker] or ("idx " .. p.marker)))
            end
        else
            print("  No priorities for this zone yet.")
        end
        print("  Macrotext length: " .. #(last_macro_set or "") .. " chars")
        print("  To bind: type /vrtmark bind <KEY> (or use Keybindings UI)")
        return
    end
    if arg == "test" then
        -- Print the current macrotext so the user can read it.
        print("|cff00c7ff[VRT MarkerScan]|r macrotext currently:")
        print(last_macro_set or "(empty)")
        return
    end
    if arg == "refresh" then
        refreshMacrotext("manual")
        return
    end
    local key = arg:match("^bind%s+(.+)$")
    if key then
        if InCombatLockdown() then
            print("|cffff8040[VRT MarkerScan]|r can't bind during combat — try after pull.")
            return
        end
        local upper_key = key:upper()
        SetBindingClick(upper_key, "VRT_MarkerScanButton")
        SaveBindings(GetCurrentBindingSet())
        print(("|cff00c7ff[VRT MarkerScan]|r bound to %s. Press it in a dungeon to mark priorities."):format(upper_key))
        return
    end
    print("|cff00c7ff[VRT MarkerScan]|r usage: /vrtmark [status|test|refresh|bind <KEY>]")
end

----------------------------------------------------------------------
-- Module lifecycle
----------------------------------------------------------------------
function M:OnInit()
    ensureSAB()

    local frame = CreateFrame("Frame", "VRT_MarkerScanEventFrame")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- combat ended — retry deferred update
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            -- If a refresh was deferred during combat, redo it now.
            refreshMacrotext("combat-ended")
        else
            refreshMacrotext(event)
        end
    end)

    -- Initial refresh
    refreshMacrotext("OnInit")
end

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
