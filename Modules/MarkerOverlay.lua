----------------------------------------------------------------------
-- VoidRaidTools — MarkerOverlay
--
-- Renders a big, addon-controlled "KICK" indicator above every
-- hostile nameplate that carries a raid-target marker. Works with
-- BOTH default Blizzard nameplates AND Plater (parents the overlay
-- to the base nameplate frame, which both stacks share).
--
-- Why not just scale the built-in marker icon?
--   We can detect THAT a mob is marked (clean: type() trick) but we
--   CANNOT read WHICH marker it has (the index is secret-tainted in
--   12.0.5 instances). So we render ONE generic icon that means
--   "the kick rotation cares about this mob" — same visual regardless
--   of whether it's skull, X, or square underneath.
--
-- Design:
--   - One overlay per nameplate, pooled and reused.
--   - Parented to the BASE nameplate frame from C_NamePlate so it
--     follows the mob smoothly (no per-frame position math needed).
--   - SetFrameStrata("TOOLTIP") so it draws on top of Plater's own
--     widgets without us having to fight Plater's layering.
----------------------------------------------------------------------

local M = {
    id   = "markeroverlay",
    name = "Marker Overlay",
    description = "Adds a large custom icon above any nameplate with a raid-target marker (star, circle, etc.). Makes assigned kick / focus targets impossible to miss in a 20-man fight. DBM has no nameplate-marker overlay.",
}

-- Visual config (tweakable later)
local ICON_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"  -- skull
local ICON_SIZE    = 56          -- pixels (default raid target = ~16)
local OFFSET_Y     = 18          -- pixels above the nameplate top
local PULSE_PERIOD = 0.8         -- seconds per pulse

----------------------------------------------------------------------
-- Overlay pool: one Frame per nameplate token, reused across mobs.
----------------------------------------------------------------------
local pool = {}

local function createOverlay(parent_nameplate)
    local f = CreateFrame("Frame", nil, parent_nameplate)
    f:SetSize(ICON_SIZE, ICON_SIZE)
    f:ClearAllPoints()
    f:SetPoint("BOTTOM", parent_nameplate, "TOP", 0, OFFSET_Y)
    f:SetFrameStrata("TOOLTIP")
    f:Hide()

    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(ICON_TEXTURE)
    f.tex = tex

    -- Subtle alpha pulse — way cheaper than scale animations,
    -- and visually clear without being seizure-inducing.
    local ag = f:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local a1 = ag:CreateAnimation("Alpha")
    a1:SetFromAlpha(1.0)
    a1:SetToAlpha(0.55)
    a1:SetDuration(PULSE_PERIOD / 2)
    a1:SetOrder(1)
    local a2 = ag:CreateAnimation("Alpha")
    a2:SetFromAlpha(0.55)
    a2:SetToAlpha(1.0)
    a2:SetDuration(PULSE_PERIOD / 2)
    a2:SetOrder(2)
    f.ag = ag
    return f
end

local function getOverlay(nameplate_token)
    local np = C_NamePlate.GetNamePlateForUnit(nameplate_token)
    if not np then return nil end
    if pool[nameplate_token] and pool[nameplate_token]:GetParent() == np then
        return pool[nameplate_token]
    end
    -- Stale entry or first time — rebuild parented to the current frame.
    pool[nameplate_token] = createOverlay(np)
    return pool[nameplate_token]
end

----------------------------------------------------------------------
-- The clean "is this mob marked?" predicate.
-- type() doesn't trip the secret-value gate.
----------------------------------------------------------------------
----------------------------------------------------------------------
-- Fingerprint-based "is priority" — same approach as MarkerKickAlert.
--
-- /tm can only mark ONE mob per priority (engine-side /targetexact
-- picks closest). For the SECOND alive same-name mob, we don't get a
-- physical marker — but we can still SHOW the overlay by matching its
-- fingerprint (UnitClassification + creature-family kind) against
-- whatever's currently marked in the pull.
--
-- Reading hostile-mob data here propagates secret-value taint into
-- this module's chain. That's fine because MarkerOverlay has no
-- secure actions — nothing protected to break.
----------------------------------------------------------------------
local active_fingerprints = {}

local function getFingerprint(unit)
    if not UnitExists(unit) then return nil end
    if not UnitCanAttack("player", unit) then return nil end
    local cls = UnitClassification(unit)
    if cls ~= "elite" then return nil end
    local family_type = type((UnitCreatureFamily(unit)))
    return cls .. "/" .. family_type
end

local function refreshFingerprints()
    active_fingerprints = {}
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and type(GetRaidTargetIndex(u)) == "number" then
            local fp = getFingerprint(u)
            if fp then
                active_fingerprints[fp] = (active_fingerprints[fp] or 0) + 1
            end
        end
    end
end

local function isPriority(unit)
    -- Overlay only on MARKED mobs. Fingerprint matching is too coarse for
    -- visual rendering (MT pull 1 has 4 humanoid elites — 4 skull overlays
    -- is noise). The ALERT layer keeps fingerprint matching because the
    -- 2.7s threshold filters short casts and only fires on the actual
    -- important spells, so its false-positive rate is naturally low.
    return type(GetRaidTargetIndex(unit)) == "number"
end

----------------------------------------------------------------------
-- Apply / clear the overlay for a single nameplate.
----------------------------------------------------------------------
local function refreshFor(unit)
    if type(unit) ~= "string" then return end
    if not unit:find("^nameplate") then return end
    local overlay = getOverlay(unit)
    if not overlay then return end
    if UnitExists(unit) and UnitCanAttack("player", unit) and isPriority(unit) then
        overlay:Show()
        overlay.ag:Play()
    else
        overlay.ag:Stop()
        overlay:Hide()
    end
end

local function refreshAll()
    -- Rebuild fingerprints FIRST, then re-evaluate every nameplate.
    refreshFingerprints()
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) then refreshFor(u) end
    end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local frame  -- lifecycle-scoped

local function OnEvent(_, event, arg1)
    if event == "NAME_PLATE_UNIT_ADDED" then
        refreshFor(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local overlay = pool[arg1]
        if overlay then
            overlay.ag:Stop()
            overlay:Hide()
        end
    elseif event == "RAID_TARGET_UPDATE" then
        -- A marker was set/cleared somewhere — re-evaluate every nameplate.
        refreshAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended — markers may have decayed on dead mobs.
        refreshAll()
    end
end

function M:OnInit()
    if frame then return end
    frame = CreateFrame("Frame", "VRT_MarkerOverlayEventFrame")
    frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    frame:RegisterEvent("RAID_TARGET_UPDATE")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:SetScript("OnEvent", OnEvent)
end

function M:OnUnitAura(unit) end -- noop, kept for Core dispatch compat

if VRT and VRT.RegisterModule then
    VRT:RegisterModule(M)
end

return M
