----------------------------------------------------------------------
-- VoidMove (shared; one identical copy per addon, like CharSettings):
-- every Void box and window can be dragged, and comes back where the
-- player left it after a /reload or a restart.
--
-- The user, 2026-11-12: "all boxes on all the addons that pop up need the
-- ability to be moved and then stay where it was moved to even after a
-- restart". So one rule everywhere: a plain left-drag moves it (no hidden
-- Shift), it stays on screen, and the spot is saved account-wide in the
-- addon's own SavedVariables (CharSettings keeps positions account-wide).
--
-- Usage, once the addon's SavedVariables exist (ADDON_LOADED or later; a
-- box made earlier is placed again when it first shows):
--   ns.Move(frame, { db = function() return VoidXDB end, key = "alert" })
-- Options:
--   db       function returning the addon's SavedVariables table (required);
--            the spot goes in db.positions[key]
--   key      name of this box (required)
--   handle   what to grab (a title bar); default the frame itself; false = nothing
--            yet (a holder that lets the mouse through: add its children with
--            ns.MoveHandle(frame, child))
--   modifier "shift" / "alt" / "ctrl": only drag while that key is down
--            (for boxes whose own clicks do something); default none
--   clickThrough  with a modifier: the box lets the mouse through except
--            while that key is held (a marker in the middle of the screen
--            mustn't eat clicks in a fight)
--   onMoved  function(frame) after a drag ends
-- ns.MoveReset(frame) puts it back where the addon first put it.
-- Protected (secure) frames move and are placed only out of combat.
----------------------------------------------------------------------
local _, ns = ...

local pending = {}   -- protected frames waiting for combat to end
local waiter

local function canTouch(f)
    return not (InCombatLockdown() and f:IsProtected())
end

local function later(f)
    pending[f] = true
    if not waiter then
        waiter = CreateFrame("Frame")
        waiter:SetScript("OnEvent", function()
            for g in pairs(pending) do
                pending[g] = nil
                if g.voidMove then g.voidMove.place(g) end
            end
        end)
    end
    waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local function store(m)
    local db = m.db()
    if type(db) ~= "table" then return nil end
    if type(db.positions) ~= "table" then db.positions = {} end
    return db.positions
end

local function modifierDown(mod)
    if mod == "shift" then return IsShiftKeyDown() end
    if mod == "alt" then return IsAltKeyDown() end
    if mod == "ctrl" then return IsControlKeyDown() end
    return true
end

-- The frame's anchors, to put it back on reset.
local function anchors(f)
    local out = {}
    for i = 1, f:GetNumPoints() do
        local p, rel, rp, x, y = f:GetPoint(i)
        out[i] = { p, rel, rp, x, y }
    end
    return out
end

local setupLater = {}   -- secure frames made in combat: set up once it ends

function ns.Move(f, opts)
    if not f or f.voidMove then return f end
    if not canTouch(f) then
        -- even EnableMouse is blocked on a secure frame in combat
        if not setupLater[f] then
            setupLater[f] = opts
            local w = CreateFrame("Frame")
            w:RegisterEvent("PLAYER_REGEN_ENABLED")
            w:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                local o = setupLater[f]
                setupLater[f] = nil
                if o then ns.Move(f, o) end
            end)
        end
        return f
    end
    local m = {
        db = opts.db, key = opts.key, modifier = opts.modifier, onMoved = opts.onMoved,
        home = anchors(f),
    }
    f.voidMove = m
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- Put it where it was saved (true when there was a saved spot).
    function m.place(g)
        local pos = store(m)
        local p = pos and pos[m.key]
        if type(p) ~= "table" or type(p[1]) ~= "string" then return false end
        if not canTouch(g) then later(g); return true end
        g:ClearAllPoints()
        g:SetPoint(p[1], UIParent, p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
        return true
    end

    m.attach = function(handle)
        handle:RegisterForDrag("LeftButton")
        handle:HookScript("OnDragStart", function()
            if not modifierDown(m.modifier) or not canTouch(f) then return end
            -- a tooltip over the box hides where it is going (the user, 2026-11-12)
            if GameTooltip and (GameTooltip:IsOwned(handle) or GameTooltip:IsOwned(f)) then GameTooltip:Hide() end
            m.moving = true
            f:StartMoving()
        end)
        handle:HookScript("OnDragStop", function()
            if not m.moving then return end
            m.moving = false
            f:StopMovingOrSizing()
            if f.SetUserPlaced then f:SetUserPlaced(false) end   -- ours, not the client's layout cache
            local p, _, rp, x, y = f:GetPoint(1)
            local pos = store(m)
            if pos and p then
                pos[m.key] = { p, rp, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10 }
            end
            if m.onMoved then m.onMoved(f) end
        end)
    end

    -- handle = false: nothing to grab yet (a holder that lets the mouse through; its
    -- children are added with ns.MoveHandle)
    local handle = opts.handle
    if handle == nil then handle = f end
    if handle == false then
        -- no handle
    elseif opts.clickThrough and m.modifier then
        local function sync()
            if m.moving then return end   -- letting go of the key mid-drag mustn't strand the drag
            if canTouch(handle) then handle:EnableMouse(modifierDown(m.modifier) and f:IsShown()) end
        end
        local w = CreateFrame("Frame")
        w:RegisterEvent("MODIFIER_STATE_CHANGED")
        w:SetScript("OnEvent", sync)
        f:HookScript("OnShow", sync)
        sync()
    else
        handle:EnableMouse(true)
    end
    if handle then m.attach(handle) end
    -- Boxes made before the SavedVariables loaded, or that the addon places
    -- again each time they open: the saved spot wins whenever it shows.
    -- (the Show hook too: an addon setting its OnShow script after this would drop the script hook)
    local function onShow(g) if not m.moving and g:IsShown() then m.place(g) end end
    f:HookScript("OnShow", onShow)
    hooksecurefunc(f, "Show", onShow)
    hooksecurefunc(f, "SetShown", onShow)
    m.place(f)
    return f
end

-- Save where `f` is now (after a resize: StartSizing re-anchors the frame, so the old saved
-- spot would put it somewhere else after a restart).
function ns.MoveSave(f)
    local m = f and f.voidMove
    local pos = m and store(m)
    local p, _, rp, x, y = f:GetPoint(1)
    if pos and p then
        pos[m.key] = { p, rp, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10 }
    end
end

-- One more thing to grab that moves `f` (e.g. each toast in a holder that lets the mouse
-- through). It keeps its own mouse setting.
function ns.MoveHandle(f, handle)
    local m = f and f.voidMove
    if m and handle and not handle.voidMoveFor then
        handle.voidMoveFor = f
        m.attach(handle)
    end
end

function ns.MoveReset(f)
    local m = f and f.voidMove
    if not m then return end
    local pos = store(m)
    if pos then pos[m.key] = nil end
    if not canTouch(f) then return end
    f:ClearAllPoints()
    for _, a in ipairs(m.home) do
        f:SetPoint(a[1], a[2] or UIParent, a[3], a[4], a[5])
    end
end
