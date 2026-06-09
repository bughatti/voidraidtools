----------------------------------------------------------------------
-- VoidRaidTools — L'ura Memory Game module (Midnight Falls Heroic)
--
-- Mechanic:
--   L'ura flashes 5 shapes in sequence on the floor. Dark Rune (spell
--   1249609) is then applied to 5 players simultaneously. Each player
--   privately sees ONE shape — addons can't read which shape it is
--   (private aura system). The selected players must each run to the
--   position number matching their shape's order in the flash sequence.
--
-- This module:
--   - Oracle clicks the 5 shapes in flash order → addon broadcasts.
--   - Other players' addons receive the sequence.
--   - When Dark Rune lands on you, a 5-shape input bar pops up.
--   - You click your shape → addon instantly computes your spot via
--     index lookup and shows a huge "GO TO SPOT N" popup.
--
-- Position convention (raid-wide, hardcoded):
--   1 = FAR RIGHT  (facing boss)
--   2 = RIGHT MID
--   3 = CENTER
--   4 = LEFT MID
--   5 = FAR LEFT
----------------------------------------------------------------------

-- Forward-declared module table so helper functions defined below can
-- read/write M.state (otherwise the closures capture _G.M = nil because
-- the local declaration hadn't happened yet at function-definition time).
local M = {
    state = {
        encounter_active     = false,
        is_oracle            = false,    -- derived from current_oracle_name
        current_oracle_name  = nil,      -- "Name-Realm" of who currently claims it
        oracle_clicks        = {},
        flash_sequence       = nil,
        has_dark_rune        = false,
        my_assigned_spot     = nil,
    },
}

local function MyFullName()
    local n = UnitName("player")
    if not n then return "?" end
    local r = GetRealmName and GetRealmName() or ""
    r = r:gsub("%s+", "")
    if r == "" then return n end
    return n .. "-" .. r
end

local DARK_RUNE_SPELL = 1249609
-- MQD wing instance map id (Belo'ren + Midnight Falls). Confirmed from
-- ENCOUNTER_START records in our tonight's log: instanceID 2913.
local MIDNIGHT_WING_INSTANCE_MAP = 2913

local function IsInMidnightArea()
    if not IsInInstance or not GetInstanceInfo then return false end
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "raid" then return false end
    local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
    return instanceMapID == MIDNIGHT_WING_INSTANCE_MAP
end

-- Difficulty-scaled mechanic size + label. Source: raid guides + tonight's
-- combat log.
--   LFR    (17): mechanic likely skipped — default to 3-shape so the bar
--                still works if Blizz ships it as a watered-down version.
--   Normal (14): 3-shape sequence, 3 players hit
--   Heroic (15): 5-shape sequence, 5 players hit
--   Mythic (16): 5-shape sequence, 5 players hit (no extra positions —
--                Mythic tunes timing/damage rather than adding shapes)
--
-- Test override: when set (via `/vrt lura test 3` or `test 5`), this
-- returns that value instead of probing the instance. Cleared on
-- ENCOUNTER_START and on entering the MQD wing so real raid pulls
-- always honor the actual difficulty.
local DIFFICULTY_MAP = {
    [14] = { n = 3, name = "Normal" },
    [15] = { n = 5, name = "Heroic" },
    [16] = { n = 5, name = "Mythic" },
    [17] = { n = 3, name = "LFR"    },
}

local function GetMechanicConfig()
    if M.state and M.state.test_n_override then
        return M.state.test_n_override, "TEST"
    end
    if not GetInstanceInfo then return 5, "Unknown" end
    local _, _, difficultyID = GetInstanceInfo()
    local cfg = DIFFICULTY_MAP[difficultyID or 0]
    if cfg then return cfg.n, cfg.name end
    return 5, ("Difficulty %s"):format(tostring(difficultyID))
end

local function GetMemoryN()
    local n = GetMechanicConfig()
    return n
end

-- 5-spot mapping (Heroic+) — full "far right ... far left" gradient
local POSITION_NAMES_5 = {
    [1] = "FAR RIGHT",
    [2] = "RIGHT MID",
    [3] = "CENTER",
    [4] = "LEFT MID",
    [5] = "FAR LEFT",
}
-- 3-spot mapping (Normal) — gaps collapsed so spot numbers match
-- positions actually used during the encounter
local POSITION_NAMES_3 = {
    [1] = "RIGHT",
    [2] = "CENTER",
    [3] = "LEFT",
}
local POSITION_COLORS = {
    [1] = {1.0, 0.4, 0.4},
    [2] = {1.0, 0.7, 0.4},
    [3] = {1.0, 1.0, 0.4},
    [4] = {0.4, 1.0, 0.7},
    [5] = {0.4, 0.7, 1.0},
}

local function GetPositionName(spot, n)
    if (n or GetMemoryN()) == 3 then
        return POSITION_NAMES_3[spot] or "?"
    end
    return POSITION_NAMES_5[spot] or "?"
end

-- The 5 in-game shapes are: Circle, Diamond, Triangle, X, T.
-- Four map cleanly to Blizzard raid target icon textures (same shape
-- vocabulary the game uses for {rt1}…{rt8} markers — no font-glyph
-- rendering issues, available in every install).
-- T has no raid-icon equivalent — use plain Latin letter (Latin DOES
-- render in WoW's default font, only symbol Unicode does not).
local ICON_PATH = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local SHAPES = {
    { id = "circle",   label = "Circle",   tex = ICON_PATH:format(2), color = {1.0, 0.6, 0.2} },
    { id = "diamond",  label = "Diamond",  tex = ICON_PATH:format(3), color = {0.7, 0.4, 1.0} },
    { id = "triangle", label = "Triangle", tex = ICON_PATH:format(4), color = {0.4, 1.0, 0.4} },
    { id = "x",        label = "X",        tex = ICON_PATH:format(7), color = {1.0, 0.4, 0.4} },
    { id = "t",        label = "T",        text = "T",                color = {1.0, 0.9, 0.3} },
}

-- Module metadata (state was forward-declared at top of file)
M.id             = "lura"
M.name           = "L'ura Memory Game"
M.encounter_id   = 3183
M.encounter_name = "Midnight Falls (Heroic Midnight Falls)"
M.description    = "Oracle calls flash order, addon tells each Dark Rune'd player which spot to run to."

local OracleFrame, LegendFrame
-- Local shadow of `PlayerFrame` so any stray reference in this module
-- cannot touch Blizzard's global PlayerFrame (which is the player's
-- unit frame). The standalone L'ura "Player Bar" was retired in favor
-- of merging everything into LegendFrame; this declaration keeps any
-- leftover `PlayerFrame:Show/Hide()` from clobbering the real one.
local PlayerFrame  ---@type Frame|nil  (always nil; intentional)

local function chime()
    if PlaySound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
end

----------------------------------------------------------------------
-- Private Aura integration — Blizzard official APIs (the same ones
-- NSRT uses). Two pieces:
--   1. AddPrivateAuraAppliedSound — guarantees zero-latency audio cue
--      the instant Dark Rune attaches. Beats UNIT_AURA polling.
--   2. AddPrivateAuraAnchor — renders an additional copy of the private
--      aura icon at our custom anchor. We anchor it right next to the
--      Player input bar so the shape symbol appears AT the click target.
-- Both register at zone entry, cleanup on leave to keep Blizz's anchor
-- table tidy.
----------------------------------------------------------------------
local registered_pa_sound  = nil
local registered_pa_anchor = nil

local function RegisterPrivateAuraHooks()
    if not C_UnitAuras then return end
    -- Sound on private-aura apply: same path NSRT uses for instant cue.
    if C_UnitAuras.AddPrivateAuraAppliedSound and not registered_pa_sound then
        local ok, soundID = pcall(C_UnitAuras.AddPrivateAuraAppliedSound, {
            spellID       = DARK_RUNE_SPELL,
            unitToken     = "player",
            soundFileName = "Sound\\Interface\\RaidWarning.ogg",
        })
        if ok and soundID then
            registered_pa_sound = soundID
        end
    end
    -- Anchor: render an additional aura icon next to our Legend frame so
    -- the player's assigned-shape symbol appears adjacent to the map.
    -- Cross-reference: see the shape on yourself, find it on the map.
    if C_UnitAuras.AddPrivateAuraAnchor and LegendFrame and not registered_pa_anchor then
        local ok, anchorID = pcall(C_UnitAuras.AddPrivateAuraAnchor, {
            unitToken             = "player",
            auraIndex             = 1,
            parent                = LegendFrame,
            showCountdownFrame    = false,
            showCountdownNumbers  = false,
            iconInfo = {
                iconWidth  = 44,
                iconHeight = 44,
                iconAnchor = {
                    point         = "LEFT",
                    relativeTo    = LegendFrame,
                    relativePoint = "RIGHT",
                    offsetX       = 6,
                    offsetY       = 0,
                },
            },
        })
        if ok and anchorID then
            registered_pa_anchor = anchorID
        end
    end
end

local function UnregisterPrivateAuraHooks()
    if not C_UnitAuras then return end
    if registered_pa_sound and C_UnitAuras.RemovePrivateAuraAppliedSound then
        pcall(C_UnitAuras.RemovePrivateAuraAppliedSound, registered_pa_sound)
        registered_pa_sound = nil
    end
    if registered_pa_anchor and C_UnitAuras.RemovePrivateAuraAnchor then
        pcall(C_UnitAuras.RemovePrivateAuraAnchor, registered_pa_anchor)
        registered_pa_anchor = nil
    end
end

-- Boss-timer pre-warnings intentionally NOT implemented here. DBM /
-- BigWigs already cover ENCOUNTER timers + countdowns with their own
-- (better) UI. Stacking another chime + chat line on top would compete
-- with theirs and add noise rather than info. The Private Aura sound
-- (above) IS the reactive cue we add — it fires the instant Dark Rune
-- attaches, before any of the timer-based addons could.

----------------------------------------------------------------------
-- Oracle role: any player in the raid can claim the role by clicking
-- the Be Oracle button. The claim is broadcast via INSTANCE_CHAT so
-- every other VoidRaidTools user knows who's currently calling.
-- Last claim wins (simple race resolution — if two people click, the
-- later broadcast overrides the earlier).
----------------------------------------------------------------------
local function UpdatePlayerFrameForOracleState()
    -- Targets LegendFrame now (Player bar was removed). Same function
    -- name kept so existing callers don't need to change.
    if not LegendFrame then return end
    local PlayerFrame = LegendFrame  -- local alias so the existing
                                     -- references below resolve cleanly
    local cur = M.state.current_oracle_name
    if cur and cur ~= "" then
        if M.state.is_oracle then
            PlayerFrame.status:SetText("|cff20ff20Oracle: YOU|r")
            if PlayerFrame.claim then
                PlayerFrame.claim:SetText("Release")
            end
        else
            PlayerFrame.status:SetText(("Oracle: |cffffd700%s|r"):format(cur))
            if PlayerFrame.claim then
                PlayerFrame.claim:SetText("Take Over")
            end
        end
    else
        PlayerFrame.status:SetText("|cffff8080No Oracle.|r Someone with addon click |cffffd700Be Oracle|r.")
        if PlayerFrame.claim then
            PlayerFrame.claim:SetText("Be Oracle")
        end
    end
end

local function ApplyOracleClaim(name, is_self_initiated)
    M.state.current_oracle_name = name and name ~= "" and name or nil
    local me = MyFullName()
    M.state.is_oracle = (M.state.current_oracle_name == me)
    if OracleFrame then
        if M.state.is_oracle then OracleFrame:Show() else OracleFrame:Hide() end
    end
    UpdatePlayerFrameForOracleState()
    if is_self_initiated and M.state.is_oracle then
        print(("|cff00c7ff[VRT/Lura]|r You are now |cff20ff20ORACLE|r."):format())
    end
end

local function ClaimOracle()
    local me = MyFullName()
    ApplyOracleClaim(me, true)
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "ORACLE", me, "INSTANCE_CHAT")
    end
    -- Broadcast trace gated behind VoidRaidToolsDB.settings.lura.debug
end

local function ReleaseOracle()
    if VRT and VRT.SendModuleMessage then
        -- Broadcast empty name = no one is Oracle anymore
        VRT:SendModuleMessage(M.id, "ORACLE", "", "INSTANCE_CHAT")
    end
    ApplyOracleClaim(nil, true)
    print("|cff00c7ff[VRT/Lura]|r Oracle role released.")
end

-- (ShowResultPopup removed — Player bar is gone, so the popup it
-- confirmed is no longer needed. The legend map is the single source
-- of truth for "your shape → your position.")

----------------------------------------------------------------------
-- Symbol → Number Legend
--   Renders a horizontal strip: [Symbol] → [Number] [Position Name].
--   Visible to EVERYONE in the raid, not just the 5 Dark Rune targets.
--   When you see your private aura (the symbol Blizzard shows), look at
--   this legend and walk to the matching number. No clicking needed.
--
--   Each cell color-matched to POSITION_COLORS so the strip doubles as
--   a visual "5 colored spots" map.
----------------------------------------------------------------------
-- Polar position offsets (x, y from center) for each numbered slot,
-- matching the boss room layout. Players see L'ura in the middle with
-- 5 spots radiating out. We mirror that on the addon map.
--
-- The 5-spot ring goes (numbered clockwise from upper-left):
-- Layout: half-circle below L'ura. Position 1 is on HER RIGHT (= screen
-- right), 5 is on HER LEFT (= screen left). This matches the raid's
-- in-game facing convention — players standing in front of L'ura
-- looking at her see position 1 on the right side of her body.
--   1 at  3 o'clock (HER RIGHT / screen right)
--   2 at  4-5 o'clock
--   3 at  6 o'clock (BOTTOM)
--   4 at  7-8 o'clock
--   5 at  9 o'clock (HER LEFT / screen left)
local RADIUS_5 = 84
local RADIAL_OFFSETS_5 = {
    [1] = { x =  RADIUS_5,                              y = 0 },
    [2] = { x =  math.cos(math.rad(45)) * RADIUS_5,     y = -math.sin(math.rad(45)) * RADIUS_5 },
    [3] = { x =                                     0,  y = -RADIUS_5 },
    [4] = { x = -math.cos(math.rad(45)) * RADIUS_5,     y = -math.sin(math.rad(45)) * RADIUS_5 },
    [5] = { x = -RADIUS_5,                              y = 0 },
}
local RADIUS_3 = 48
local RADIAL_OFFSETS_3 = {
    [1] = { x = -RADIUS_3, y = 0 },
    [2] = { x =        0, y = -RADIUS_3 },
    [3] = { x =  RADIUS_3, y = 0 },
}

local function GetRadialOffsets(n)
    if n == 3 then return RADIAL_OFFSETS_3 end
    return RADIAL_OFFSETS_5
end

local function BuildLegendFrame()
    -- L'ura sigil at center + 5 shape cells orbiting around her. NO gray
    -- box backdrop — just the boss icon floating with the shapes around.
    -- Visually distinct from NSRT's panel-with-box treatment.
    local f = CreateFrame("Frame", "VRT_Lura_LegendFrame", UIParent)
    -- Default to top-RIGHT of the screen so the legend doesn't block
    -- the boss arena. User can drag wherever; their drag is persisted.
    f:SetSize(224, 176)
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -120)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)

    -- L'ura's portrait at center. Priority:
    --   1. Custom user image at Interface\AddOns\VoidRaidTools\Media\lura.tga
    --      (or .blp) — drop a 128×128 (or 256×256) file there.
    --   2. EJ creature icon if the API returns one.
    --   3. Shadow-themed spell icon fallback.
    local center = f:CreateTexture(nil, "ARTWORK")
    center:SetSize(77, 77)
    center:SetPoint("CENTER", 0, 0)
    local custom_path = "Interface\\AddOns\\VoidRaidTools\\Media\\lura"
    local got_portrait = center:SetTexture(custom_path) and true or false
    if not got_portrait and EJ_GetCreatureInfo then
        local _, _, _, _, displayInfo, iconImage = pcall(function()
            return EJ_GetCreatureInfo(1, 3183)
        end)
        if iconImage then
            center:SetTexture(iconImage)
            got_portrait = true
        end
    end
    if not got_portrait then
        -- Fallback: shadow-themed spell icon that reads "void boss"
        -- (Mind Blast looks like a purple shadow burst — close enough
        -- to L'ura's thematic feel).
        center:SetTexture("Interface\\Icons\\Spell_Shadow_PsychicScream")
    end
    -- Round the corners of the icon by masking with a soft circular
    -- texture. (Optional polish — can skip if the square icon looks fine.)
    local glow = f:CreateTexture(nil, "BACKGROUND")
    glow:SetTexture("Interface\\GuildFrame\\GuildLogo-NoLogoSm")  -- soft round glow
    glow:SetBlendMode("ADD")
    glow:SetSize(112, 112)
    glow:SetPoint("CENTER", center, "CENTER", 0, 0)
    glow:SetVertexColor(0.6, 0.3, 1.0, 0.45)
    f.center = center

    -- L'ura is the drag handle now (no frame border to grab anymore).
    -- We make the center icon click-and-drag the whole legend.
    center:SetParent(f)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Status + claim live ABOVE the boss icon. The radial cell positions
    -- only occupy the bottom semicircle (right → down → left), so the
    -- top half of the frame is empty and can hold UI. Putting status
    -- below the icon collided with the cell at the 6-o'clock position
    -- (and its number label).
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.status:SetPoint("TOP", 0, -4)
    f.status:SetText("|cffff8080No Oracle.|r Click |cffffd700Be Oracle|r below.")

    local claim = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    claim:SetSize(64, 16)
    claim:SetPoint("TOP", f.status, "BOTTOM", 0, -2)
    claim:SetText("Be Oracle")
    claim:SetScript("OnClick", function()
        if M.state.is_oracle then
            ReleaseOracle()
        else
            ClaimOracle()
        end
    end)
    f.claim = claim

    f:Hide()

    f.cells = {}
    LegendFrame = f
    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "lura.legend",
            frame = f,
            label = "L'ura — Symbol Map",
            default_point = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -40, y = -120 },
        })
    end
end

-- Show/update legend. Renders the gray boss-map disc with L'ura at
-- center and 5 (or 3) numbered slots radiating around her. As Oracle
-- clicks shapes, the corresponding numbered slot fills with the symbol.
--
-- Sources, in priority order:
--   1. M.state.flash_sequence (locked sequence or received via wire)
--   2. M.state.oracle_clicks  (Oracle's partial click order, live)
local function ShowLegend()
    if not LegendFrame then return end
    local n = GetMemoryN()
    local seq = M.state.flash_sequence or M.state.oracle_clicks or {}
    local offsets = GetRadialOffsets(n)

    for _, c in ipairs(LegendFrame.cells) do c:Hide(); c:SetParent(nil) end
    LegendFrame.cells = {}

    for i = 1, n do
        local shape_id = seq[i]
        local shape
        if shape_id then
            for _, s in ipairs(SHAPES) do
                if s.id == shape_id then shape = s; break end
            end
        end
        local off = offsets[i]
        if not off then break end

        local cell = CreateFrame("Frame", nil, LegendFrame, "BackdropTemplate")
        cell:SetSize(34, 34)
        cell:SetPoint("CENTER", off.x, off.y)
        cell:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        local col = POSITION_COLORS[i] or {1, 1, 1}
        if shape then
            cell:SetBackdropColor(col[1] * 0.20, col[2] * 0.20, col[3] * 0.20, 0.95)
            cell:SetBackdropBorderColor(col[1], col[2], col[3], 1)
        else
            cell:SetBackdropColor(0.10, 0.10, 0.12, 0.85)
            cell:SetBackdropBorderColor(0.40, 0.40, 0.48, 0.9)
        end

        -- Symbol icon (or nothing — slot stays empty until Oracle clicks)
        if shape and shape.tex then
            local icon = cell:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(shape.tex)
            icon:SetSize(24, 24)
            icon:SetPoint("CENTER", 0, 2)
        elseif shape then
            local fs = cell:CreateFontString(nil, "OVERLAY")
            fs:SetFont(STANDARD_TEXT_FONT, 22, "OUTLINE")
            fs:SetText(shape.text or shape.label)
            fs:SetTextColor(unpack(shape.color))
            fs:SetPoint("CENTER", 0, 2)
        end

        -- Numbered slot label below the cell — matches the screenshot
        -- where the 1-5 numbers sit just outside each slot.
        local num = cell:CreateFontString(nil, "OVERLAY")
        num:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        num:SetText(tostring(i))
        if shape then
            num:SetTextColor(col[1], col[2], col[3])
        else
            num:SetTextColor(col[1] * 0.7, col[2] * 0.7, col[3] * 0.7)
        end
        num:SetPoint("BOTTOM", 0, -11)

        LegendFrame.cells[i] = cell
    end
    LegendFrame:Show()
end

local function HideLegend()
    if LegendFrame then LegendFrame:Hide() end
end

-- (BuildResultFrame removed — see ShowResultPopup comment above.)

----------------------------------------------------------------------
-- Oracle bar
----------------------------------------------------------------------
local function ResetOracle()
    M.state.oracle_clicks  = {}
    M.state.flash_sequence = nil   -- clear locked sequence too — otherwise
                                   -- the legend stays drawn because
                                   -- ShowLegend reads flash_sequence first
    if OracleFrame then
        for _, b in ipairs(OracleFrame.buttons) do
            b.slot:SetText("")
        end
        local n, diffname = GetMechanicConfig()
        OracleFrame.status:SetText(
            ("|cffffd700%s: click %d shapes in flash order.|r"):format(diffname, n))
    end
    -- Clear the radial map cells AND hide it. Re-draws empty on next
    -- Oracle click.
    if LegendFrame then
        for _, c in ipairs(LegendFrame.cells or {}) do
            c:Hide()
            c:SetParent(nil)
        end
        LegendFrame.cells = {}
        LegendFrame:Hide()
    end
end

local function BroadcastFlash()
    local n = GetMemoryN()
    if #M.state.oracle_clicks ~= n then return end
    local payload = table.concat(M.state.oracle_clicks, ",")
    if VRT and VRT.SendModuleMessage then
        VRT:SendModuleMessage(M.id, "FLASH", payload, "INSTANCE_CHAT")
    end
    M.state.flash_sequence = { unpack(M.state.oracle_clicks) }
    if M.state.has_dark_rune and not M.state.my_assigned_spot then chime() end
    print(("|cff00c7ff[VRT/Lura]|r Sequence locked: |cffffd700%s|r"):format(
        table.concat(M.state.oracle_clicks, " > ")))
    -- Broadcast trace gated; see LuraMemory debug toggle
end

local function OracleClick(shape_id)
    local n = GetMemoryN()
    -- Tap same shape that was just added → undo it
    if #M.state.oracle_clicks > 0
       and M.state.oracle_clicks[#M.state.oracle_clicks] == shape_id then
        M.state.oracle_clicks[#M.state.oracle_clicks] = nil
    elseif #M.state.oracle_clicks < n then
        for _, s in ipairs(M.state.oracle_clicks) do
            if s == shape_id then return end
        end
        M.state.oracle_clicks[#M.state.oracle_clicks + 1] = shape_id
    else
        return
    end

    local pos_by_shape = {}
    for i, s in ipairs(M.state.oracle_clicks) do pos_by_shape[s] = i end
    for _, b in ipairs(OracleFrame.buttons) do
        local pos = pos_by_shape[b.shape.id]
        if pos then
            b.slot:SetText(tostring(pos))
            local c = POSITION_COLORS[pos]
            b.slot:SetTextColor(c[1], c[2], c[3])
        else
            b.slot:SetText("")
        end
    end

    -- LIVE UPDATE: refresh the symbol map (locally + broadcast).
    -- Everyone sees the icons populate the gray boss-map circle as the
    -- Oracle clicks. When Dark Rune lands, players just look at the map
    -- and walk to whichever numbered slot has their symbol.
    ShowLegend()
    if VRT and VRT.SendModuleMessage then
        local partial = table.concat(M.state.oracle_clicks, ",")
        VRT:SendModuleMessage(M.id, "CLICKS", partial, "INSTANCE_CHAT")
    end

    if #M.state.oracle_clicks == n then
        OracleFrame.status:SetText("|cff20ff20Locked. Broadcasting...|r")
        BroadcastFlash()
    else
        OracleFrame.status:SetText(
            ("|cffffd700%d / %d clicked. Tap same shape to undo.|r")
            :format(#M.state.oracle_clicks, n))
    end
end

-- Persist a frame's position to module settings on drag stop.
local function HookPositionSave(frame, key)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        local s = VRT:ModuleSettings("lura")
        s[key] = { point = point, relPoint = relPoint, x = x, y = y }
    end)
end

-- Restore a frame's saved position (or fall back to a default anchor).
local function RestorePosition(frame, key, default_y)
    local s = VRT:ModuleSettings("lura")
    local p = s and s[key]
    frame:ClearAllPoints()
    if p and p.point and p.x and p.y then
        frame:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x, p.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, default_y or 0)
    end
end

local function BuildOracleFrame()
    local f = CreateFrame("Frame", "VRT_Lura_OracleFrame", UIParent, "BackdropTemplate")
    f:SetSize(290, 86)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    HookPositionSave(f, "oracle_pos")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    -- Transparent fill so players can still see boss / floor through
    -- the bar. Border stays visible as a thin frame outline.
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0.4, 0.7, 1.0, 0.7)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -4)
    title:SetText("|cff00c7ffORACLE|r — click in flash order")

    -- Reset button in the top-right corner. Wipes the click sequence
    -- mid-phase if the Oracle realizes they miscalled (much safer than
    -- the "tap-same-shape-to-undo" undo for fast cascading mistakes).
    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(56, 18)
    reset:SetPoint("TOPRIGHT", -4, -4)
    reset:SetText("Reset")
    reset:SetScript("OnClick", function() ResetOracle() end)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOM", 0, 4)
    f.status:SetText("|cffffd700Click 5 shapes in flash order.|r")

    f.buttons = {}
    for i, shape in ipairs(SHAPES) do
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetSize(40, 40)
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 54, 20)
        b:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        b:SetBackdropColor(0.10, 0.12, 0.18, 1)
        b:SetBackdropBorderColor(0.6, 0.7, 0.9, 0.8)
        b.shape = shape
        if shape.tex then
            local icon = b:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(shape.tex)
            icon:SetSize(28, 28)
            icon:SetPoint("CENTER", 0, 3)
            b.icon = icon
        else
            local fs = b:CreateFontString(nil, "OVERLAY")
            fs:SetFont(STANDARD_TEXT_FONT, 28, "OUTLINE")
            fs:SetText(shape.text or shape.label)
            fs:SetTextColor(unpack(shape.color))
            fs:SetPoint("CENTER", 0, 3)
            b.icon = fs
        end
        b.slot = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.slot:SetPoint("BOTTOM", 0, 1)
        b.slot:SetText("")
        b:SetScript("OnClick", function() OracleClick(shape.id) end)
        b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(1, 1, 1, 1) end)
        b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.6, 0.7, 0.9, 0.8) end)
        f.buttons[i] = b
    end
    OracleFrame = f
    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "lura.oracle",
            frame = f,
            label = "L'ura — Oracle Bar",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = -40 },
        })
    end
end

----------------------------------------------------------------------
-- Player bar
----------------------------------------------------------------------
local function PlayerClick(shape_id)
    if not M.state.flash_sequence then
        if PlayerFrame then
            PlayerFrame.status:SetText("|cffff8080Oracle hasn't called the sequence yet — held.|r")
        end
        M.state.pending_player_shape = shape_id
        return
    end
    local n = #M.state.flash_sequence
    for i, shape in ipairs(M.state.flash_sequence) do
        if shape == shape_id then
            M.state.my_assigned_spot = i
            ShowResultPopup(i, n)
            return
        end
    end
    print("|cffff8080[VRT/Lura]|r Your shape wasn't in Oracle's sequence — oracle may have miscalled.")
end

local function BuildPlayerFrame()
    local f = CreateFrame("Frame", "VRT_Lura_PlayerFrame", UIParent, "BackdropTemplate")
    f:SetSize(290, 86)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    HookPositionSave(f, "player_pos")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    -- Transparent fill so the player can still see the boss / floor
    -- through the bar during the (panicked) Dark Rune react window.
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(1.0, 0.3, 0.3, 0.7)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -4)
    title:SetText("|cffff5050PLAYER|r — click YOUR shape")

    -- "Be Oracle" button: top-right corner. Clicking claims the Oracle
    -- role and broadcasts to every other VoidRaidTools user in the raid
    -- so they all switch to "Oracle: <name>" display. Same button
    -- text-cycles to "Release" / "Take Over" depending on current state.
    local claim = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    claim:SetSize(72, 18)
    claim:SetPoint("TOPRIGHT", -4, -4)
    claim:SetText("Be Oracle")
    claim:SetScript("OnClick", function()
        if M.state.is_oracle then
            ReleaseOracle()
        else
            ClaimOracle()
        end
    end)
    f.claim = claim

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOM", 0, 4)
    f.status:SetText("|cffff8080No Oracle.|r Someone with addon click |cffffd700Be Oracle|r.")

    for i, shape in ipairs(SHAPES) do
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetSize(40, 40)
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 54, 20)
        b:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        b:SetBackdropColor(0.10, 0.12, 0.18, 1)
        b:SetBackdropBorderColor(0.9, 0.7, 0.6, 0.8)
        if shape.tex then
            local icon = b:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(shape.tex)
            icon:SetSize(30, 30)
            icon:SetPoint("CENTER")
        else
            local fs = b:CreateFontString(nil, "OVERLAY")
            fs:SetFont(STANDARD_TEXT_FONT, 30, "OUTLINE")
            fs:SetText(shape.text or shape.label)
            fs:SetTextColor(unpack(shape.color))
            fs:SetPoint("CENTER")
        end
        b:SetScript("OnClick", function() PlayerClick(shape.id) end)
        b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(1, 1, 1, 1) end)
        b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.9, 0.7, 0.6, 0.8) end)
    end
    PlayerFrame = f
    if VRT and VRT.RegisterMovable then
        VRT:RegisterMovable({
            id    = "lura.player",
            frame = f,
            label = "L'ura — Player Bar",
            default_point = { point = "CENTER", relPoint = "CENTER", x = 0, y = 60 },
        })
    end
end

----------------------------------------------------------------------
-- Aura scan: is Dark Rune on me right now?
----------------------------------------------------------------------
local function CheckPlayerForDarkRune()
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, DARK_RUNE_SPELL)
        if ok and aura then return true end
    end
    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetDebuffDataByIndex, "player", i, "HARMFUL")
            if not ok or not aura then break end
            local sid = aura.spellId
            if sid ~= nil and not (issecretvalue and issecretvalue(sid))
               and sid == DARK_RUNE_SPELL then
                return true
            end
        end
    end
    return false
end

----------------------------------------------------------------------
-- Module lifecycle hooks (called by Core)
----------------------------------------------------------------------
function M:OnInit()
    BuildOracleFrame()
    BuildLegendFrame()
    self.state.is_oracle = false
    self.state.current_oracle_name = nil
    -- NOTE: do NOT call the legacy RestorePosition() here. Each frame
    -- registers with VRT:RegisterMovable, which both saves position
    -- on drag AND restores it on next load — so RestorePosition would
    -- just overwrite the user's drag with the original default.
    -- (That was the "positions go back to default after /reload" bug.)
end

-- ZONE-DRIVEN VISIBILITY:
-- Bars show when you enter the MQD wing (Belo'ren + Midnight Falls) so
-- you can position them BEFORE the pull. They stay visible the entire
-- time you're in the wing, including between attempts. Leave the zone
-- and they hide. This avoids the historical pain of UI-driven-by-event
-- not firing when expected (combat lockdown races, etc.) — the player
-- has full control and can drag the bar out of the way once and forget.
function M:OnZoneChanged()
    local in_area = IsInMidnightArea()
    if not in_area then
        -- Cleanup: pull our hooks out of Blizz's private-aura tables so
        -- we don't pollute them while not in the wing.
        UnregisterPrivateAuraHooks()
    end
    if in_area then
        -- Entering a real instance — leftover test override from an
        -- earlier /vrt lura test N must NOT bleed into real mechanic
        -- detection. Always honor the instance's actual difficulty.
        if self.state.test_n_override then
            self.state.test_n_override = nil
            local n, diffname = GetMechanicConfig()
            print(("|cff00c7ff[VRT/Lura]|r Clearing test override; detected |cffffd700%s|r (%d-shape)."):format(diffname, n))
        end
        -- Oracle claim is RAID-SCOPED, not persisted. Reset on each
        -- zone entry; raid re-claims fresh each session.
        self.state.current_oracle_name = nil
        self.state.is_oracle = false
        if OracleFrame then OracleFrame:Hide() end
        if PlayerFrame then PlayerFrame:Show() end
        UpdatePlayerFrameForOracleState()
        -- Hook into Blizz's private-aura system: instant sound on apply
        -- + render an additional copy of the shape icon at our anchor
        -- next to the Player bar.
        RegisterPrivateAuraHooks()
        local n, diffname = GetMechanicConfig()
        if not self.state._zone_msg_shown then
            self.state._zone_msg_shown = true
            print(("|cff00c7ff[VRT/Lura]|r Detected: |cffffd700%s|r (%d-shape). Click |cffffd700Be Oracle|r on the player bar to claim the role for your raid."):format(diffname, n))
        end
    else
        if OracleFrame then OracleFrame:Hide() end
        if PlayerFrame then PlayerFrame:Hide() end
        if ResultFrame then ResultFrame:Hide() end
        self.state._zone_msg_shown = nil
    end
end

function M:OnEncounterStart()
    -- UI is already shown via zone detection — this hook just cleans
    -- state for a fresh attempt and clears any test override.
    self.state.encounter_active     = true
    self.state.flash_sequence       = nil
    self.state.has_dark_rune        = false
    self.state.my_assigned_spot     = nil
    self.state.pending_player_shape = nil
    self.state.test_n_override      = nil
    ResetOracle()
    -- Show the empty boss map immediately so the raid sees the slots
    -- (with "?" placeholders) ready to be filled by the Oracle's clicks.
    ShowLegend()
    local n, diffname = GetMechanicConfig()
    print(("|cff00c7ff[VRT/Lura]|r Midnight Falls engaged. Oracle: %s. |cffffd700%s|r (%d-shape)."):format(
        self.state.is_oracle and "|cff20ff20YOU|r" or "(designated player)",
        diffname, n))
end

function M:OnEncounterEnd()
    -- Don't hide the bars — we're still in the zone, group will re-pull.
    -- Just clean transient state.
    self.state.encounter_active     = false
    self.state.flash_sequence       = nil
    self.state.has_dark_rune        = false
    self.state.my_assigned_spot     = nil
    self.state.pending_player_shape = nil
    ResetOracle()
    if ResultFrame then ResultFrame:Hide() end
    if PlayerFrame then PlayerFrame.status:SetText("Waiting for next pull...") end
end

function M:OnUnitAura(unit)
    if unit ~= "player" or not self.state.encounter_active then return end
    local has = CheckPlayerForDarkRune()
    if has and not self.state.has_dark_rune then
        self.state.has_dark_rune        = true
        self.state.my_assigned_spot     = nil
        self.state.pending_player_shape = nil
        if PlayerFrame then
            PlayerFrame:Show()
            PlayerFrame.status:SetText(self.state.flash_sequence
                and "Click the shape you see above your character."
                or "|cffffd700Waiting for Oracle...|r You can pre-click your shape.")
        end
        chime()
        print("|cffff5050[VRT/Lura]|r DARK RUNE on you — find your shape on the legend map.")
    elseif (not has) and self.state.has_dark_rune then
        self.state.has_dark_rune = false
        if PlayerFrame then PlayerFrame:Hide() end
    end
end

function M:OnAddonMessage(kind, data, sender)
    if VRT:ModuleSettings("lura").debug then
        print(("|cff00c7ff[VRT/Lura recv]|r |cff8c8c9ekind=%s data=%s from=%s|r"):format(
            tostring(kind), tostring(data), tostring(sender)))
    end
    if kind == "ORACLE" then
        -- Someone in the raid claimed (or released) Oracle. Last write
        -- wins by design — keeps the protocol stateless and resilient
        -- to dropped messages.
        local claimer = data and data ~= "" and data or nil
        ApplyOracleClaim(claimer, false)
        if claimer then
            print(("|cff00c7ff[VRT/Lura]|r |cff20ff20%s|r is now the Oracle."):format(claimer))
        else
            print("|cff00c7ff[VRT/Lura]|r Oracle role released.")
        end
        return
    end
    -- Live partial-click updates from the Oracle. Update flash_sequence
    -- to whatever they have so far and refresh the legend so everyone
    -- sees the icons populate the gray map in real time.
    if kind == "CLICKS" then
        local partial = {}
        if data and data ~= "" then
            for word in data:gmatch("([^,]+)") do partial[#partial + 1] = word end
        end
        self.state.flash_sequence = partial
        ShowLegend()
        return
    end
    if kind ~= "FLASH" then return end
    local seq = {}
    for word in data:gmatch("([^,]+)") do seq[#seq + 1] = word end
    -- Accept 3-shape (Normal) or 5-shape (Heroic+) sequences.
    if #seq < 1 or #seq > 5 then
        print("|cffff8080[VRT/Lura]|r received invalid sequence length, ignoring.")
        return
    end
    self.state.flash_sequence = seq
    ShowLegend()
    print(("|cff00c7ff[VRT/Lura]|r Oracle (%s) called: |cffffd700%s|r"):format(
        sender or "?", table.concat(seq, " > ")))
    -- (Pre-click resolver removed with Player bar / ResultFrame. The
    -- legend renders Oracle's full sequence on receive; the player
    -- visually finds their assigned shape on the map.)
end

function M:OnSlash(args)
    args = (args or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if args == "" or args == "help" then
        print("|cff00c7ff[VRT/Lura]|r commands:")
        print("  |cffffd700/vrt lura oracle|r              — toggle Oracle role (persisted)")
        print("  |cffffd700/vrt lura show|r                — show UI (positioning)")
        print("  |cffffd700/vrt lura hide|r                — hide UI")
        print("  |cffffd700/vrt lura reset|r               — clear Oracle clicks + state")
        print("  |cffffd700/vrt lura test|r                — simulate (uses current difficulty)")
        print("  |cffffd700/vrt lura test 3|r              — simulate Normal-mode (3-shape)")
        print("  |cffffd700/vrt lura test 5|r              — simulate Heroic-mode (5-shape)")
        print("  |cffffd700/vrt lura simrecv tri,cir,dia|r — fake an incoming Oracle broadcast")
        return
    end
    if args == "oracle" then
        -- Slash alias for the in-UI "Be Oracle" / "Release" button.
        -- Same broadcast flow, same last-write-wins semantics.
        if self.state.is_oracle then
            ReleaseOracle()
        else
            ClaimOracle()
        end
        return
    end
    if args == "show" then
        if OracleFrame then OracleFrame:Show() end
        if PlayerFrame then PlayerFrame:Show() end
        return
    end
    if args == "hide" then
        if OracleFrame then OracleFrame:Hide() end
        if PlayerFrame then PlayerFrame:Hide() end
        if ResultFrame then ResultFrame:Hide() end
        return
    end
    if args == "reset" then
        ResetOracle()
        self.state.flash_sequence       = nil
        self.state.has_dark_rune        = false
        self.state.my_assigned_spot     = nil
        self.state.pending_player_shape = nil
        if PlayerFrame then PlayerFrame:Hide() end
        if ResultFrame then ResultFrame:Hide() end
        print("|cff00c7ff[VRT/Lura]|r Reset.")
        return
    end
    if args:match("^simrecv") then
        -- Fake an incoming FLASH message from a pretend Oracle so the
        -- receive path can be exercised solo without another addon user.
        -- Usage: /vrt lura simrecv triangle,circle,diamond
        local data = args:match("^simrecv%s+(.+)$") or "circle,diamond,triangle"
        print(("|cff00c7ff[VRT/Lura]|r Faking incoming Oracle broadcast: |cffffd700%s|r"):format(data))
        -- Also turn on the player UI + has_dark_rune so the test loop is
        -- complete: tester sees the sequence arrive, clicks a shape on
        -- the player bar, gets a spot.
        self.state.encounter_active = true
        self.state.has_dark_rune    = true
        if PlayerFrame then
            PlayerFrame:Show()
            PlayerFrame.status:SetText("|cffffd700simrecv: click any shape from the sequence to see your spot.|r")
        end
        -- Route through the actual addon-message dispatcher so we exercise
        -- the same code path a real broadcast would take.
        self:OnAddonMessage("FLASH", data, "FakeOracle-SimRealm")
        return
    end
    if args:match("^test") then
        -- Parse optional N argument: "test", "test 3", "test 5"
        local n_arg = tonumber(args:match("^test%s+(%d+)$"))
        if n_arg == 3 or n_arg == 5 then
            self.state.test_n_override = n_arg
            print(("|cff00c7ff[VRT/Lura]|r TEST: forcing |cffffd700%d-shape|r mode (%s)."):format(
                n_arg, n_arg == 3 and "Normal" or "Heroic"))
        else
            self.state.test_n_override = nil
            print(("|cff00c7ff[VRT/Lura]|r TEST: using current difficulty (|cffffd700%d-shape|r)."):format(GetMemoryN()))
        end
        local n = GetMemoryN()
        print(("|cff00c7ff[VRT/Lura]|r Click %d shapes on the blue Oracle bar, then one on the red Player bar."):format(n))
        self.state.encounter_active = true
        ResetOracle()
        if OracleFrame then OracleFrame:Show() end
        self.state.has_dark_rune = true
        if PlayerFrame then
            PlayerFrame:Show()
            PlayerFrame.status:SetText(("|cffffd700TEST (%d-shape): fill Oracle bar first, then click your shape.|r"):format(n))
        end
        return
    end
    print("|cff00c7ff[VRT/Lura]|r unknown subcommand: " .. args)
end

----------------------------------------------------------------------
-- Panel actions
----------------------------------------------------------------------
M.actions = {
    { label = "Show UI",          action = function() M:OnSlash("show") end },
    { label = "Hide UI",          action = function() M:OnSlash("hide") end },
    { label = "Be Oracle / Release", action = function() M:OnSlash("oracle") end },
    { label = "Test 3-shape (Normal)", action = function() M:OnSlash("test 3") end },
    { label = "Test 5-shape (Heroic)", action = function() M:OnSlash("test 5") end },
    { label = "Reset",            action = function() M:OnSlash("reset") end },
}

----------------------------------------------------------------------
-- Self-register with Core
----------------------------------------------------------------------
VRT = VRT or { modules = {} }
VRT.modules = VRT.modules or {}
if VRT.RegisterModule then
    VRT:RegisterModule(M)
else
    VRT.modules[M.id] = M  -- early load order safety
end
