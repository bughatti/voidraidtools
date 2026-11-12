----------------------------------------------------------------------
-- VoidHubBundle — drop-in shared across all Void* addons.
--
-- Cooperative election: the first Void* addon that loads creates the
-- single hub button. Any other Void* addon loaded after sees the global
-- flag and skips creation. If the "owning" addon is later disabled, the
-- next /reload triggers another addon to create it.
--
-- Left-click hub → vertical row of Void* minimap icons
-- Right-click hub → info panel about all Void* addons (cross-promotion) + copy settings from another character
--
-- Position persistence: uses shared SavedVariablesPerCharacter VoidHubCharDB
-- (each Void* addon's TOC must include this var name for persistence to
-- work regardless of which addon owns the hub this session).
----------------------------------------------------------------------

-- Addons without a minimap button of their own (VoidBars, VoidFrames, ...)
-- register a launcher instead, from their own code, whichever bundle copy wins:
--   VoidHubLaunchers = VoidHubLaunchers or {}
--   VoidHubLaunchers.VoidBars = { icon = "Interface\Icons\...", onClick = function(button) ... end }
-- Borders are one screen pixel (tools/cmd/pixelfix, 2026-11-09). WoW snaps each border
-- piece to the pixel grid, and a thin line on a fractional position can snap to 0 px: a side
-- of a box vanishes. VoidPX() asks for one real pixel, and the hook below (installed once, by
-- the first Void addon loaded) turns snapping off on the edges of flat WHITE8X8 borders, like
-- Blizzard's NineSliceUtil.DisableSharpening, so a 1 px line always covers a pixel.
local function VoidPX()
    local s = UIParent and UIParent:GetEffectiveScale()
    if s and s > 0 and PixelUtil and PixelUtil.GetPixelToUIUnitFactor then return PixelUtil.GetPixelToUIUnitFactor() / s end
    return 1
end
if not _G.__VoidBorderHook and hooksecurefunc and NineSliceUtil and NineSliceUtil.ApplyLayout then
    _G.__VoidBorderHook = true
    local EDGES = { "TopEdge", "BottomEdge", "LeftEdge", "RightEdge",
                    "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner" }
    hooksecurefunc(NineSliceUtil, "ApplyLayout", function(c)
        local i = type(c) == "table" and c.backdropInfo
        local e = i and i.edgeFile
        if type(e) ~= "string" or not e:lower():find("white8x8", 1, true) or (tonumber(i.edgeSize) or 0) > 3 then return end
        for _, k in ipairs(EDGES) do
            local t = c[k]
            if t and t.SetSnapToPixelGrid then
                t:SetSnapToPixelGrid(false)
                t:SetTexelSnappingBias(0)
            end
        end
    end)
end
_G.VoidHubLaunchers = _G.VoidHubLaunchers or {}

----------------------------------------------------------------------
-- The drawer (2026-11-11): left-click the hub -> ONE panel, every Void addon by name, grouped
-- by what it helps with, its on/off switches right under it. It replaces the ring of unnamed
-- icons and the separate Quick switches box (the user: "the icon buttons around the map are
-- getting confusing"). On WoW Forever the addons that do nothing there are left out.
--
-- An addon adds a switch from its own code (the id's first part names the addon):
--   VoidHubToggles = VoidHubToggles or {}
--   table.insert(VoidHubToggles, { id = "VoidGather.hud", group = "Gathering",
--       label = "Gathering HUD", tip = "...", get = function() return on end,
--       set = function(on) ... end, noCombat = true (optional: waits for combat to end) })
-- and, without a minimap button of its own, a launcher:
--   VoidHubLaunchers.VoidBars = { icon = "Interface\\Icons\\...", onClick = function(button) ... end }
--
-- This part runs in EVERY copy of the bundle, before the hub election below, and the newest
-- QUICK_VERSION loaded builds the drawer. It takes over the hub button's left click by name,
-- so it works whichever copy (old or new) made the button.
----------------------------------------------------------------------
_G.VoidHubToggles = _G.VoidHubToggles or {}
do
    -- 3: VoidSequencer, VoidPlates, VoidFrames and VoidCheatSheet listed on WoW Forever again (2 hid
    -- them as Midnight-only; all four work there; the user, 2026-11-11: "seq is not in the new hud")
    local QUICK_VERSION = 3
    if (_G.__VoidQuickVersion or 0) < QUICK_VERSION then
        _G.__VoidQuickVersion = QUICK_VERSION
        local Q = {}
        _G.VoidHubQuick = Q
        local box
        local afterCombat = {}
        local FOREVER = (select(4, GetBuildInfo()) or 0) < 100000

        -- name, label, group; noForever = does nothing on WoW Forever (Midnight content)
        local GROUPS = { "Questing and travel", "Gear and gold", "Professions", "Combat", "PvP and groups", "Other" }
        local ADDONS = {
            { "VoidQuest", "Quests", 1 }, { "VoidGPS", "GPS", 1 }, { "VoidMap", "World map", 1 },
            { "VoidLayer", "Layers", 1 }, { "VoidSweep", "Map radar", 1 },
            { "VoidGear", "Gear", 2 }, { "VoidBags", "Bags", 2 }, { "VoidAH", "Auction House", 2 },
            { "VoidProf", "Professions", 3 }, { "VoidGather", "Gathering", 3 }, { "VoidFisher", "Fishing", 3 },
            { "VoidBars", "Action bars", 4 }, { "VoidTank", "Tank tools", 4 }, { "VoidAlert", "Alerts", 4 },
            { "VoidSequencer", "Sequencer", 4 }, { "VoidPlates", "Nameplates", 4 },
            { "VoidFrames", "Party frames", 4 }, { "VoidCheatSheet", "Cheat sheets", 4 },
            { "VoidRaidTools", "Raid tools", 4, true }, { "VoidRaidToolsReader", "VRT reader", 4, true },
            { "VoidDice", "Dice", 4 }, { "VoidComp", "Comp tool", 4 },
            { "VoidBounty", "Bounties", 5 }, { "VoidScout", "Scout", 5 }, { "VoidPug", "Pug tracker", 5 },
            { "VoidLFG", "Group finder", 5 }, { "VoidWatcher", "Watcher", 5 },
            { "VoidCalendar", "Calendar", 6 }, { "VoidAsk", "Ask", 6 }, { "VoidUI", "UI", 6 },
        }

        local function isOn(e)
            local ok, v = pcall(e.get)
            return ok and v and true or false
        end

        local function iconOf(name, launcher)
            local btn = _G[name .. "MinimapBtn"]
            if btn and btn.GetRegions then
                for _, region in ipairs({ btn:GetRegions() }) do
                    if region.GetTexture and region:GetObjectType() == "Texture" then
                        local tex = region:GetTexture()
                        if tex and not tostring(tex):find("Minimap%-Tracking") and not tostring(tex):find("Minimap%-Background") then return tex end
                    end
                end
            end
            return launcher and launcher.icon or "Interface\\Icons\\spell_shadow_summonvoidwalker"
        end

        local function opener(name)
            local btn = _G[name .. "MinimapBtn"]
            if btn and btn.GetScript and btn:GetScript("OnClick") then
                return function(button) btn:GetScript("OnClick")(btn, button) end
            end
            local l = _G.VoidHubLaunchers and _G.VoidHubLaunchers[name]
            if type(l) == "table" and l.onClick then return function(button) l.onClick(button) end, l end
        end

        -- what the drawer shows: groups -> addons (loaded ones) -> their switches
        local function model()
            local toggles, seen = {}, {}
            for _, e in ipairs(_G.VoidHubToggles) do
                if type(e) == "table" and e.label and e.get and e.set and not seen[e.id or e.label] then
                    seen[e.id or e.label] = true
                    local owner = type(e.id) == "string" and e.id:match("^([%w]+)%.") or "?"
                    toggles[owner] = toggles[owner] or {}
                    table.insert(toggles[owner], e)
                end
            end
            for _, list in pairs(toggles) do table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end) end
            local groups, known = {}, {}
            for gi = 1, #GROUPS do groups[gi] = { name = GROUPS[gi], addons = {} } end
            for _, a in ipairs(ADDONS) do
                local name = a[1]
                known[name] = true
                local open, launcher = opener(name)
                local sw = toggles[name]
                if (open or sw) and not (FOREVER and a[4]) then
                    table.insert(groups[a[3]].addons, { name = name, label = a[2], open = open, icon = iconOf(name, launcher), toggles = sw or {} })
                end
            end
            for owner, list in pairs(toggles) do   -- switches of an addon this list doesn't know
                if not known[owner] then
                    table.insert(groups[#GROUPS].addons, { name = owner, label = owner:gsub("^Void", ""), icon = iconOf(owner), toggles = list })
                end
            end
            local out = {}
            for _, g in ipairs(groups) do if #g.addons > 0 then out[#out + 1] = g end end
            return out
        end

        ------------------------------------------------------------------
        -- rows (reused): kind = "group" | "addon" | "toggle"
        ------------------------------------------------------------------
        local rows, COL_W, ROW_H = {}, 230, { group = 20, addon = 22, toggle = 18 }

        local function flip(e)
            local pending = afterCombat[e]
            local want
            if pending ~= nil then want = not pending else want = not isOn(e) end
            if e.noCombat and InCombatLockdown() then
                -- a click flips what's waiting for the fight to end (Astra, 2026-11-07)
                if want == isOn(e) then
                    afterCombat[e] = nil
                    print(("|cff00c7ffVoid|r %s: no change."):format(e.label))
                else
                    afterCombat[e] = want
                    print(("|cff00c7ffVoid|r %s: after this fight."):format(e.label))
                end
                return
            end
            afterCombat[e] = nil
            local ok, err = pcall(e.set, want)
            if not ok then geterrorhandler()(err) end
        end

        local function row(i)
            local r = rows[i]
            if r then return r end
            r = CreateFrame("Button", nil, box)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r.icon = r:CreateTexture(nil, "ARTWORK")
            r.icon:SetSize(16, 16)
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetJustifyH("LEFT")
            r.text:SetWordWrap(false)
            r.pill = r:CreateTexture(nil, "ARTWORK")
            r.pill:SetSize(30, 13)
            r.pill:SetPoint("RIGHT", -6, 0)
            r.state = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.state:SetPoint("CENTER", r.pill)
            r.line = r:CreateTexture(nil, "ARTWORK")
            r.line:SetHeight(1)
            r.line:SetPoint("BOTTOMLEFT", 6, 1)
            r.line:SetPoint("BOTTOMRIGHT", -6, 1)
            r.line:SetColorTexture(0, 0.78, 1, 0.25)
            r.hl = r:CreateTexture(nil, "BACKGROUND")
            r.hl:SetAllPoints()
            r.hl:SetColorTexture(0, 0.78, 1, 0.12)
            r.hl:Hide()
            r:SetScript("OnEnter", function(self)
                if self.kind == "group" then return end
                self.hl:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.kind == "addon" then
                    GameTooltip:SetText("|cff00c7ff" .. self.a.name .. "|r")
                    GameTooltip:AddLine(self.a.open and "Click to open" or "No window: its switches are below", 1, 1, 1)
                else
                    GameTooltip:SetText(self.e.label, 1, 1, 1)
                    if self.e.tip then GameTooltip:AddLine(self.e.tip, 0.8, 0.8, 0.8, true) end
                end
                GameTooltip:Show()
            end)
            r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
            r:SetScript("OnClick", function(self, button)
                if self.kind == "addon" and self.a.open then
                    box:Hide()
                    local ok, err = pcall(self.a.open, button)
                    if not ok then geterrorhandler()(err) end
                elseif self.kind == "toggle" then
                    flip(self.e)
                    C_Timer.After(0.1, Q.Paint)
                end
            end)
            rows[i] = r
            return r
        end

        local function paintState(r)
            local e = r.e
            if afterCombat[e] ~= nil then
                r.pill:SetColorTexture(0.5, 0.45, 0.1, 0.9); r.state:SetText("|cffffd200wait|r")
            elseif isOn(e) then
                r.pill:SetColorTexture(0.1, 0.55, 0.2, 0.95); r.state:SetText("ON")
            else
                r.pill:SetColorTexture(0.25, 0.25, 0.28, 0.95); r.state:SetText("|cffaaaaaaOFF|r")
            end
        end

        -- lay the groups out in one or two columns (split at a group boundary near the middle)
        function Q.Paint()
            if not box then return 0 end
            local groups = model()
            local items = {}
            for _, g in ipairs(groups) do
                local block = { { kind = "group", g = g } }
                for _, a in ipairs(g.addons) do
                    block[#block + 1] = { kind = "addon", a = a }
                    for _, e in ipairs(a.toggles) do block[#block + 1] = { kind = "toggle", e = e } end
                end
                items[#items + 1] = block
            end
            local total = 0
            for _, b in ipairs(items) do for _, it in ipairs(b) do total = total + ROW_H[it.kind] end end
            local cols = total > 300 and 2 or 1
            local col, y, colH, maxH, n = 0, 0, {}, 0, 0
            for bi, b in ipairs(items) do
                local bh = 0
                for _, it in ipairs(b) do bh = bh + ROW_H[it.kind] end
                if cols == 2 and col == 0 and bi > 1 and y + bh / 2 > total / 2 then col, y = 1, 0 end
                for _, it in ipairs(b) do
                    n = n + 1
                    local r = row(n)
                    r.kind, r.a, r.e = it.kind, it.a, it.e
                    local h = ROW_H[it.kind]
                    r:SetSize(COL_W, h)
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", 4 + col * (COL_W + 8), -28 - y)
                    r.icon:Hide(); r.pill:Hide(); r.state:Hide(); r.line:Hide()
                    r.text:ClearAllPoints()
                    if it.kind == "group" then
                        r.text:SetFontObject("GameFontNormalSmall")
                        r.text:SetPoint("LEFT", 6, -2)
                        r.text:SetText(it.g.name)
                        r.line:Show()
                    elseif it.kind == "addon" then
                        r.icon:Show(); r.icon:SetPoint("LEFT", 8, 0); r.icon:SetTexture(it.a.icon)
                        r.text:SetFontObject("GameFontHighlight")
                        r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
                        r.text:SetPoint("RIGHT", -6, 0)
                        r.text:SetText(it.a.open and it.a.label or ("|cffa0a0a8" .. it.a.label .. "|r"))
                    else
                        r.text:SetFontObject("GameFontHighlightSmall")
                        r.text:SetPoint("LEFT", 32, 0)
                        r.text:SetPoint("RIGHT", r.pill, "LEFT", -4, 0)
                        r.text:SetText("|cffc8c8d0" .. it.e.label .. "|r")
                        r.pill:Show(); r.state:Show()
                        paintState(r)
                    end
                    r:Show()
                    y = y + h
                end
                colH[col] = y
                maxH = math.max(maxH, y)
            end
            for i = n + 1, #rows do rows[i]:Hide() end
            box:SetSize(8 + cols * COL_W + (cols - 1) * 8, 36 + maxH + 26)   -- 26: the background slider
            return n
        end

        -- background opacity (the user, 11-11: "a transparency setting to the hub"): only the
        -- panel's background and border fade, the names and switches stay solid. Per character.
        local function alpha()
            VoidHubCharDB = VoidHubCharDB or {}
            local a = tonumber(VoidHubCharDB.drawerAlpha) or 0.96
            return math.max(0.1, math.min(1, a))
        end
        local function applyAlpha()
            if not box then return end
            local a = alpha()
            box:SetBackdropColor(0.05, 0.05, 0.07, a)
            box:SetBackdropBorderColor(0, 0.78, 1, 0.3 + 0.5 * a)
            if box.pct then box.pct:SetText(("%d%%"):format(math.floor(a * 100 + 0.5))) end
        end

        local function build()
            if box then return end
            box = CreateFrame("Frame", "VoidHubDrawer", UIParent, "BackdropTemplate")
            box:SetSize(240, 60)
            box:SetFrameStrata("HIGH")
            box:SetClampedToScreen(true)
            box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = VoidPX() })
            box:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
            box:SetBackdropBorderColor(0, 0.78, 1, 0.7)
            box:EnableMouse(true)
            local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            title:SetPoint("TOPLEFT", 10, -8)
            title:SetText("|cff00c7ffVoid addons|r")
            local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hint:SetPoint("TOPRIGHT", -10, -9)
            hint:SetText("click a name to open")   -- short: a one-column drawer is only 240 wide
            -- the background slider, along the bottom
            local lbl = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            lbl:SetPoint("BOTTOMLEFT", 12, 9)
            lbl:SetText("Background")
            local s = CreateFrame("Slider", nil, box)
            s:SetOrientation("HORIZONTAL")
            s:SetSize(110, 14)   -- label + slider + % fit a one-column (238 px) drawer
            s:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
            s:SetMinMaxValues(0.1, 1)
            s:SetValueStep(0.05)
            if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
            local track = s:CreateTexture(nil, "BACKGROUND")
            track:SetColorTexture(1, 1, 1, 0.18)
            track:SetHeight(3)
            track:SetPoint("LEFT"); track:SetPoint("RIGHT")
            s:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
            local th = s:GetThumbTexture()
            th:SetSize(8, 14)
            th:SetVertexColor(0, 0.78, 1)
            box.pct = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            box.pct:SetPoint("LEFT", s, "RIGHT", 8, 0)
            s:SetValue(alpha())
            s:SetScript("OnValueChanged", function(_, v)
                VoidHubCharDB = VoidHubCharDB or {}
                VoidHubCharDB.drawerAlpha = math.floor(v * 20 + 0.5) / 20
                applyAlpha()
            end)
            s:EnableMouseWheel(true)
            s:SetScript("OnMouseWheel", function(self, d) self:SetValue(math.max(0.1, math.min(1, self:GetValue() + d * 0.05))) end)
            s:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText("Background", 1, 1, 1)
                GameTooltip:AddLine("How see-through this panel is. Drag or use the mouse wheel. The names and switches stay solid.", 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            s:SetScript("OnLeave", function() GameTooltip:Hide() end)
            applyAlpha()
            box:Hide()
            tinsert(UISpecialFrames, "VoidHubDrawer")   -- Esc closes it
            local acc = 0
            box:SetScript("OnUpdate", function(_, dt)   -- switches change elsewhere too
                acc = acc + dt
                if acc > 0.5 then
                    acc = 0
                    for _, r in ipairs(rows) do if r:IsShown() and r.kind == "toggle" then paintState(r) end end
                end
            end)
            box:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
            box:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
            box:SetScript("OnEvent", function(self)
                -- a click anywhere else closes it (the hub button toggles it itself)
                if self:IsMouseOver() then return end
                local hub = _G.VoidHubMinimapBtn
                if hub and hub:IsMouseOver() then return end
                self:Hide()
            end)
            local ev = CreateFrame("Frame")
            ev:RegisterEvent("PLAYER_REGEN_ENABLED")
            ev:SetScript("OnEvent", function()
                for e, want in pairs(afterCombat) do
                    afterCombat[e] = nil
                    local ok, err = pcall(e.set, want)
                    if not ok then geterrorhandler()(err) end
                end
                if box:IsShown() then Q.Paint() end
            end)
        end

        -- beside the hub, on the side toward the middle of the screen
        local function rect(f)
            local l, b, w, h = f:GetRect()
            if not l then return nil end
            local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
            return l * s, b * s, w * s, h * s
        end
        local function place()
            local hub = _G.VoidHubMinimapBtn
            local l, b, w, h
            if hub then l, b, w, h = rect(hub) end
            box:ClearAllPoints()
            if not l then box:SetPoint("CENTER"); return end
            local right = (l + w / 2) > UIParent:GetWidth() / 2
            local top = (b + h / 2) > UIParent:GetHeight() / 2
            local px = right and (l - 6) or (l + w + 6)
            local py = top and (b + h) or b
            box:SetPoint((top and "TOP" or "BOTTOM") .. (right and "RIGHT" or "LEFT"), UIParent, "BOTTOMLEFT", px, py)
        end

        function Q.Show()
            build()
            if (Q.Paint() or 0) == 0 then box:Hide(); return end
            place()
            box:Show()
        end
        function Q.Hide() if box then box:Hide() end end
        function Q.Toggle() if box and box:IsShown() then Q.Hide() else Q.Show() end end

        -- take over the hub button's left click (made by whichever bundle copy won its election)
        function Q.Install()
            local hub = _G.VoidHubMinimapBtn
            if not hub or Q.hooked then return hub ~= nil end
            Q.hooked = true
            local orig = hub:GetScript("OnClick")
            hub:SetScript("OnClick", function(self, button)
                if button == "LeftButton" then
                    if _G.VoidHubPopup then _G.VoidHubPopup:Hide() end   -- the old icon ring, never again
                    Q.Toggle()
                elseif orig then
                    orig(self, button)
                end
            end)
            hub:HookScript("OnEnter", function()
                if GameTooltip:IsOwned(hub) then
                    GameTooltip:AddLine("Left-click: every Void addon by name, with its switches", 0.5, 0.8, 0.5)
                    GameTooltip:Show()
                end
            end)
            -- a cyan ring: ours at a glance, not BugSack's or Blizzard's round buttons
            for _, region in ipairs({ hub:GetRegions() }) do
                if region.GetWidth and (region:GetWidth() or 0) > 40 then
                    region:SetVertexColor(0.35, 0.85, 1)
                end
            end
            return true
        end

        SLASH_VOIDQUICK1 = "/vquick"
        SlashCmdList.VOIDQUICK = function() Q.Toggle() end
    end
    -- every new copy tries; the hub button appears ~0.5 s after login, so retry a while
    local qf = CreateFrame("Frame")
    qf:RegisterEvent("PLAYER_LOGIN")
    qf:SetScript("OnEvent", function()
        local tries = 0
        local function try()
            local Q = _G.VoidHubQuick
            if not Q or Q.hooked then return end
            tries = tries + 1
            if not Q.Install() and tries < 20 then C_Timer.After(0.5, try) end
        end
        C_Timer.After(1, try)
    end)
end


-- Election guard — only first-loaded Void* addon does the work
if _G.__VoidHubLoaded then return end
_G.__VoidHubLoaded = true

local CYAN_R, CYAN_G, CYAN_B = 0.00, 0.78, 1.00
local BORDER_TEX = "Interface\\Minimap\\MiniMap-TrackingBorder"
local hubBtn, popupFrame, infoFrame
local popupItems = {}

----------------------------------------------------------------------
-- Whitelist of OUR Void* addons (don't pick up third-party "Void*" addons)
----------------------------------------------------------------------
-- public = published on CurseForge. Only public addons are listed in the
-- /vhub info panel; the rest stay here so their minimap icons still fold
-- into the hub for anyone who has them.
local KNOWN_VOID_ADDONS = {
    { name = "VoidAH",         label = "Auction House",     public = true, desc = "A full Auction House replacement with built-in profession leveling plans and shopping lists." },
    { name = "VoidAlert",      label = "Alerts",            desc = "Custom on-screen alerts for combat events." },
    { name = "VoidBags",       label = "Bags",              public = true, desc = "Smart bag organizer with auto-categorization, cross-character tracking, and one-click merchant tools." },
    { name = "VoidBars",       label = "Action Bars",       public = true, desc = "Action bars with smart Consumables, Travel and Professions bars, profiles and layout presets." },
    { name = "VoidBounty",     label = "Bounties",          desc = "WoW Forever world PvP: enemy players nearby, the players who killed you, and writs paid in vendor goods." },
    { name = "VoidCalendar",   label = "Calendar",         public = true, desc = "A Void-themed calendar replacement that shows every event in your own time zone." },
    { name = "VoidCheatSheet", label = "Cheat Sheets",      public = true, desc = "In-game cheat sheets for every Midnight raid, the full Mythic+ pool, and delve bosses, auto-pops on pull." },
    { name = "VoidComp",       label = "Comp Tool",         desc = "Group composition planning and balance helper." },
    { name = "VoidDice",       label = "Dice Roller",       desc = "Standardized loot-roll rolls for raids." },
    { name = "VoidFisher",     label = "Fishing",           desc = "Fishing tracker: catches, their value and the best spots." },
    { name = "VoidFrames",     label = "Party Frames",      public = true, desc = "Clean party and raid frames with click casting built in." },
    { name = "VoidGather",     label = "Gathering",         public = true, desc = "Every mining, herb, skinning and lumber spot on your map, shared with other players, plus what your gathering is worth per hour." },
    { name = "VoidGear",       label = "Gear Planner",      public = true, desc = "What the top Mythic+ players of your spec wear, your upgrades, and where your crests should go." },
    { name = "VoidGPS",        label = "GPS",               desc = "Type a place, an NPC, a service or a party member: a route along walked paths, flight paths and zeppelins, through zones." },
    { name = "VoidLayer",      label = "Layers",            public = true, desc = "WoW Forever: see your layer, hop to another with one click, and rares up on other layers." },
    { name = "VoidLFG",        label = "Group Finder",      desc = "Enhanced LFG dialog with party history and quality filters." },
    { name = "VoidMap",        label = "World Map",         desc = "The world map in a Void window: same navigation, filters and pins, your quests beside it." },
    { name = "VoidPlates",     label = "Nameplates",        public = true, desc = "Clean, readable enemy nameplates: who is casting, what to kick and who it is aimed at." },
    { name = "VoidProf",       label = "Professions",       public = true, desc = "What to spend profession knowledge on, this week's knowledge sources, and the cheapest way to level from what your characters have." },
    { name = "VoidPug",        label = "Pug Tracker",       public = true, desc = "Track pug raid lockouts automatically, never lose contact with a good pug leader." },
    { name = "VoidQuest",      label = "Quests",            desc = "Quest helper with proximity sort and step-by-step guides." },
    { name = "VoidRaidTools",  label = "Raid Tools",        public = true, desc = "A complement to DBM and BigWigs that handles the parts they leave to you: kick rotation, tank swaps, boss helpers." },
    { name = "VoidRaidToolsReader", label = "VRT Reader",   public = true, desc = "The required companion to VoidRaidTools. Records boss events so its alerts know what really happens in each fight." },
    { name = "VoidScout",      label = "Scout",             public = true, desc = "Behavior-aware player and group scoring for the Premade Groups finder." },
    { name = "VoidSequencer",  label = "Sequencer",         public = true, desc = "One-button rotations and recommended talent builds for every spec, with a single-target / AoE switch." },
    { name = "VoidSweep",      label = "Map Radar",         public = true, desc = "Live map radar: rares, world bosses, treasures and lore that are up right now." },
    { name = "VoidTank",       label = "Tank Tools",        desc = "Tank-swap alerts and threat tracking." },
    { name = "VoidUI",         label = "UI Overhaul",       desc = "Full UI replacement with class-themed accents." },
}

local function PositionHub(btn)
    VoidHubCharDB = VoidHubCharDB or {}
    local angle  = math.rad(VoidHubCharDB.minimapAngle or 215)
    local radius = (Minimap:GetWidth() / 2) + 6
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function DiscoverVoidButtons()
    local found = {}
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and type(btn) == "table"
            and btn.GetObjectType and btn:GetObjectType() == "Button" then
            table.insert(found, { name = info.label, fullName = info.name, button = btn })
        elseif type(VoidHubLaunchers[info.name]) == "table" then
            table.insert(found, { name = info.label, fullName = info.name, launcher = VoidHubLaunchers[info.name] })
        end
    end
    return found
end

----------------------------------------------------------------------
-- Popup (left-click) — vertical row of installed Void* minimap icons
----------------------------------------------------------------------
local function BuildPopup()
    if popupFrame then return popupFrame end
    -- Its own frame on UIParent, not the minimap's: a gathering HUD (VoidGather,
    -- FarmHud) moves the minimap and fades it out, which took the popup with it.
    popupFrame = CreateFrame("Frame", "VoidHubPopup", UIParent)
    popupFrame:SetSize(40, 40)
    popupFrame:SetFrameStrata("HIGH")
    popupFrame:Hide()
    popupFrame:EnableMouse(false)   -- only its icons take clicks (it's a ring, not a box)
    popupFrame:SetScript("OnShow", function(self)
        self:SetScript("OnEvent", function(_, event)
            if event == "GLOBAL_MOUSE_DOWN" then
                if hubBtn and hubBtn:IsMouseOver() then return end
                for _, it in ipairs(popupItems) do
                    if it:IsShown() and it:IsMouseOver() then return end
                end
                self:Hide()
            end
        end)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    popupFrame:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    return popupFrame
end

local function RefreshPopup()
    BuildPopup()
    for _, it in ipairs(popupItems) do if type(it) == "table" and it.SetPoint then it:Hide() end end

    local buttons = DiscoverVoidButtons()
    local slotSize, gap, n = 28, 4, #buttons
    if n == 0 then
        popupFrame:SetSize(160, 30)
        if not popupItems._noneLabel then
            local lbl = popupFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            lbl:SetPoint("CENTER")
            popupItems._noneLabel = lbl
        end
        popupItems._noneLabel:SetText("No Void* addons found")
        popupItems._noneLabel:Show()
        return
    end
    if popupItems._noneLabel then popupItems._noneLabel:Hide() end

    -- Rings around the hub button: about 5 icons in the first ring, 8 in the next,
    -- 11 after that (half rings). A full circle when it all fits on the screen,
    -- else half rings opening toward the middle of the screen (the hub usually
    -- sits on the minimap, in a corner).
    popupFrame:SetSize(1, 1)
    local positions = {}
    do
        local STEP, RSTEP, MARGIN = 34, 34, 18
        local hb = hubBtn or Minimap
        local uiScale = UIParent:GetEffectiveScale()
        local hx, hy = hb:GetCenter()
        local hs = hb:GetEffectiveScale() / uiScale
        hx, hy = (hx or 0) * hs, (hy or 0) * hs
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        local function layout(span, a0)
            local pts, left, ring = {}, n, 0
            while left > 0 do
                ring = ring + 1
                -- across the 140-degree fan: 5 icons, then 7, 9, 12
                local r = 56 + (ring - 1) * RSTEP
                local cap = math.floor(span * r / STEP) + ((span >= 2 * math.pi - 0.01) and 0 or 1)
                local m = math.min(left, math.max(cap, 1))
                local gapA = (span >= 2 * math.pi - 0.01) and (2 * math.pi / m) or (cap > 1 and span / (cap - 1) or 0)
                local startA = (span >= 2 * math.pi - 0.01) and (a0 + math.pi / 2) or (a0 - gapA * (m - 1) / 2)
                for j = 0, m - 1 do
                    local a = startA + gapA * j
                    pts[#pts + 1] = { r * math.cos(a), r * math.sin(a) }
                end
                left = left - m
            end
            return pts
        end
        local function fits(pts)
            for _, p in ipairs(pts) do
                local x, y = hx + p[1], hy + p[2]
                if x < MARGIN or x > sw - MARGIN or y < MARGIN or y > sh - MARGIN then return false end
            end
            return true
        end
        -- A fan opening outward from what the hub sits on (the minimap, or a HUD's
        -- stand-in for it), through the hub, so the rings stay clear of the minimap
        -- and of the other buttons on its rim; 140 degrees keeps the ends off them.
        -- If that runs off the screen (a hub in a corner), a narrower fan toward
        -- the screen's middle; whatever still sticks out is nudged back in.
        local base = hb:GetParent()
        local bx, by
        -- (not `base and base:GetCenter()`: an `and` keeps only the first return)
        if base and base.GetCenter then bx, by = base:GetCenter() end
        local outward
        if bx and by and base ~= UIParent then
            local bs = base:GetEffectiveScale() / uiScale
            outward = math.atan2(hy - by * bs, hx - bx * bs)
        end
        local toward = math.atan2(sh / 2 - hy, sw / 2 - hx)
        positions = layout(math.rad(140), outward or toward)
        if not fits(positions) then positions = layout(math.rad(140), toward) end
        if not fits(positions) then positions = layout(math.pi / 2, toward) end
        -- still off the screen: slide the whole fan in (keeps the spacing; nudging
        -- icons one by one stacked them on top of each other in a corner)
        local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
        for _, p in ipairs(positions) do
            x0, x1 = math.min(x0, hx + p[1]), math.max(x1, hx + p[1])
            y0, y1 = math.min(y0, hy + p[2]), math.max(y1, hy + p[2])
        end
        local dx = (x0 < MARGIN and MARGIN - x0) or (x1 > sw - MARGIN and sw - MARGIN - x1) or 0
        local dy = (y0 < MARGIN and MARGIN - y0) or (y1 > sh - MARGIN and sh - MARGIN - y1) or 0
        for _, p in ipairs(positions) do p[1], p[2] = p[1] + dx, p[2] + dy end
    end
    for i, entry in ipairs(buttons) do
        local item = popupItems[i]
        if not item then
            item = CreateFrame("Button", nil, popupFrame)
            item:SetSize(slotSize, slotSize)
            item.icon = item:CreateTexture(nil, "BACKGROUND")
            item.icon:SetSize(20, 20)
            item.icon:SetPoint("CENTER")
            item.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            item.border = item:CreateTexture(nil, "OVERLAY")
            item.border:SetSize(54, 54)
            item.border:SetPoint("TOPLEFT", -2, 2)
            item.border:SetTexture(BORDER_TEX)
            item.hl = item:CreateTexture(nil, "OVERLAY")
            item.hl:SetSize(20, 20)
            item.hl:SetPoint("CENTER")
            item.hl:SetColorTexture(CYAN_R, CYAN_G, CYAN_B, 0.35)
            item.hl:Hide()
            item:SetScript("OnEnter", function(self)
                self.hl:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(("|cff00c7ff%s|r"):format(self._fullName or self._name or "?"))
                GameTooltip:AddLine("Click to open", 1, 1, 1)
                GameTooltip:Show()
            end)
            item:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
            popupItems[i] = item
        end
        item:ClearAllPoints()
        item:SetPoint("CENTER", popupFrame, "CENTER", positions[i][1], positions[i][2])
        item._name, item._fullName, item._addonButton, item._launcher = entry.name, entry.fullName, entry.button, entry.launcher
        local srcTexture = entry.launcher and entry.launcher.icon
        if entry.button and entry.button.GetRegions then
            for _, region in ipairs({ entry.button:GetRegions() }) do
                if region.GetTexture and region:GetObjectType() == "Texture" then
                    local tex = region:GetTexture()
                    if tex and not tostring(tex):find("Minimap%-Tracking") then srcTexture = tex; break end
                end
            end
        end
        item.icon:SetTexture(srcTexture or "Interface\\Icons\\spell_shadow_summonvoidwalker")
        item:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        item:SetScript("OnClick", function(self, button)
            popupFrame:Hide()
            if self._launcher then
                if self._launcher.onClick then self._launcher.onClick(button) end
                return
            end
            local script = self._addonButton:GetScript("OnClick")
            if script then script(self._addonButton, button) end
        end)
        item:Show()
    end
end

local function TogglePopup()
    BuildPopup()
    if popupFrame:IsShown() then popupFrame:Hide(); return end
    RefreshPopup()
    popupFrame:ClearAllPoints()
    -- centered on the hub button: its icons ring around it (RefreshPopup)
    popupFrame:SetPoint("CENTER", hubBtn or Minimap, "CENTER")
    popupFrame:Show()
end

----------------------------------------------------------------------
-- Info panel (right-click) — full list of Void* addons with descriptions,
-- highlighting which ones the user has installed
----------------------------------------------------------------------
local function BuildInfoFrame()
    if infoFrame then return infoFrame end
    infoFrame = CreateFrame("Frame", "VoidHubInfo", UIParent, "BackdropTemplate")
    infoFrame:SetSize(440, 540)
    infoFrame:SetPoint("CENTER")
    infoFrame:SetFrameStrata("HIGH")
    infoFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = VoidPX(),
    })
    infoFrame:SetBackdropColor(0.04, 0.05, 0.08, 0.97)
    infoFrame:SetBackdropBorderColor(CYAN_R, CYAN_G, CYAN_B, 0.85)
    infoFrame:Hide()
    infoFrame:SetMovable(true)
    infoFrame:SetClampedToScreen(true)
    infoFrame:EnableMouse(true)
    infoFrame:RegisterForDrag("LeftButton")
    infoFrame:SetScript("OnDragStart", infoFrame.StartMoving)
    -- kept after a restart (the user, 2026-11-12: every box stays where it was moved). Inline, not
    -- VoidMove.lua: whichever addon's bundle copy runs, it may not carry that file.
    infoFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        local p, _, rp, x, y = self:GetPoint(1)
        VoidHubCharDB = VoidHubCharDB or {}
        if p then VoidHubCharDB.infoPos = { p, rp, math.floor(x + 0.5), math.floor(y + 0.5) } end
    end)
    infoFrame:SetScript("OnShow", function(self)
        local p = VoidHubCharDB and VoidHubCharDB.infoPos
        if type(p) == "table" and type(p[1]) == "string" then
            self:ClearAllPoints()
            self:SetPoint(p[1], UIParent, p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
        end
    end)
    table.insert(UISpecialFrames, "VoidHubInfo")

    -- Title
    local title = infoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cff00c7ffVoid Addons|r")

    -- Close button
    local close = CreateFrame("Button", nil, infoFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Copy settings from another character: settings are per character in
    -- every Void addon (CharSettings.lua), which sign up in VoidHubSettings.
    local copyBtn = CreateFrame("Button", nil, infoFrame, "BackdropTemplate")
    copyBtn:SetSize(180, 20)
    copyBtn:SetPoint("TOP", 0, -34)
    copyBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = VoidPX() })
    copyBtn:SetBackdropColor(0.10, 0.12, 0.15, 1)
    copyBtn:SetBackdropBorderColor(CYAN_R, CYAN_G, CYAN_B, 0.6)
    local copyText = copyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyText:SetPoint("CENTER")
    copyText:SetText("Copy settings from...")
    copyBtn:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        local reg = _G.VoidHubSettings or {}
        local byChar, addons = {}, {}
        for addon, r in pairs(reg) do
            addons[#addons + 1] = addon
            for _, key in ipairs(r.characters()) do
                byChar[key] = byChar[key] or {}
                table.insert(byChar[key], addon)
            end
        end
        local chars = {}
        for key in pairs(byChar) do chars[#chars + 1] = key end
        table.sort(chars)
        MenuUtil.CreateContextMenu(self, function(_, root)
            if root.SetScrollMode then root:SetScrollMode(400) end   -- many alts: scroll, don't run off screen
            root:CreateTitle("Copy settings from")
            if #chars == 0 then
                root:CreateTitle("|cff8c8c9eNo other character yet: log one in first.|r")
            end
            for _, key in ipairs(chars) do
                local list = byChar[key]
                table.sort(list)
                local sub = root:CreateButton(key)
                sub:CreateButton(("|cff00c7ffAll Void addons (%d)|r"):format(#list), function()
                    for _, addon in ipairs(list) do reg[addon].copyFrom(key) end
                    ReloadUI()
                end)
                for _, addon in ipairs(list) do
                    sub:CreateButton(addon, function()
                        if reg[addon].copyFrom(key) then ReloadUI() end
                    end)
                end
            end
        end)
    end)
    copyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(CYAN_R, CYAN_G, CYAN_B, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Copy settings from another character", CYAN_R, CYAN_G, CYAN_B)
        GameTooltip:AddLine("Each character keeps its own Void addon settings, and a new character starts with the last one you played. Pick a character to take its settings for all your Void addons or just one. A reload applies them.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    copyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(CYAN_R, CYAN_G, CYAN_B, 0.6)
        GameTooltip:Hide()
    end)

    -- Scrollable list of addons
    local scroll = CreateFrame("ScrollFrame", nil, infoFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -62)
    scroll:SetPoint("BOTTOMRIGHT", -30, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(390, 1)
    scroll:SetScrollChild(content)

    local yOff = 0
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
      if info.public then
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(390, 52)
        row:SetPoint("TOPLEFT", 0, -yOff)

        local installed = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(info.name))
            or (IsAddOnLoaded and IsAddOnLoaded(info.name))

        local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFs:SetPoint("TOPLEFT", 4, -2)
        nameFs:SetText(("|cff00c7ff%s|r  |cff%s%s|r"):format(
            info.name,
            installed and "66ff66" or "888888",
            installed and "[installed]" or "[not installed]"
        ))

        local labelFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        labelFs:SetPoint("TOPLEFT", 4, -18)
        labelFs:SetText(info.label)
        labelFs:SetTextColor(0.8, 0.8, 0.85)

        local descFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        descFs:SetPoint("TOPLEFT", 4, -32)
        descFs:SetPoint("RIGHT", -4, 0)
        descFs:SetJustifyH("LEFT")
        descFs:SetText(info.desc)
        descFs:SetTextColor(0.65, 0.65, 0.7)

        yOff = yOff + 56
      end
    end
    content:SetHeight(yOff)

    -- Footer
    local footer = infoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOM", 0, 4)
    footer:SetText("All free on CurseForge: search \"bughatti\"  ·  voidscout.io")
    footer:SetTextColor(0.5, 0.5, 0.55)

    return infoFrame
end

local function ToggleInfo()
    BuildInfoFrame()
    if infoFrame:IsShown() then infoFrame:Hide() else infoFrame:Show() end
end

----------------------------------------------------------------------
-- Hub button on minimap
----------------------------------------------------------------------
local function CreateHubButton()
    if hubBtn then return end
    if _G.VoidHubMinimapBtn then return end   -- another addon's bundle already created it
    if not Minimap then return end

    hubBtn = CreateFrame("Button", "VoidHubMinimapBtn", Minimap)
    hubBtn:SetSize(28, 28)
    hubBtn:SetFrameStrata("MEDIUM")
    hubBtn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 11)

    local icon = hubBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\spell_shadow_summonvoidwalker")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = hubBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture(BORDER_TEX)

    hubBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    hubBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ToggleInfo() else TogglePopup() end
    end)
    hubBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidHub|r")
        GameTooltip:AddLine("Left-click: open Void addons", 1, 1, 1)
        GameTooltip:AddLine("Right-click: all Void addons, copy settings from another character", 1, 1, 1)
        GameTooltip:AddLine("Drag: reposition", 0.7, 0.7, 0.7)
        local buttons = DiscoverVoidButtons()
        if #buttons > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("|cff8c8c9e%d Void addon(s) detected|r"):format(#buttons))
        end
        GameTooltip:Show()
    end)
    hubBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    hubBtn:SetMovable(true)
    hubBtn:RegisterForDrag("LeftButton")
    hubBtn:SetScript("OnDragStart", function(self) self._dragging = true end)
    hubBtn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    hubBtn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            px = px / scale; py = py / scale
            VoidHubCharDB = VoidHubCharDB or {}
            VoidHubCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionHub(self)
        end
    end)
    PositionHub(hubBtn)
end

----------------------------------------------------------------------
-- Satellite-icon consolidation: once the hub is up, hide the individual
-- Void* minimap buttons so the minimap isn't cluttered. The hub popup
-- still launches them via the source button's OnClick — they just become
-- invisible launch shims. User can opt out by setting
-- VoidHubCharDB.showSatellites = true (right-click hub → toggle, /vhub satellites).
----------------------------------------------------------------------
local _satelliteHookInstalled = {}

local function HideSatellites()
    VoidHubCharDB = VoidHubCharDB or {}
    if VoidHubCharDB.showSatellites then return end
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and btn.Hide then
            btn:Hide()
            -- Lock the button hidden: any later Show() (from the owning
            -- addon's own login/config path) gets silently reverted on the
            -- next frame. Avoid hooking Show directly (taint-prone); use a
            -- one-shot OnShow handler instead.
            if not _satelliteHookInstalled[info.name] and btn.HookScript then
                btn:HookScript("OnShow", function(self)
                    if not (VoidHubCharDB and VoidHubCharDB.showSatellites) then
                        self:Hide()
                    end
                end)
                _satelliteHookInstalled[info.name] = true
            end
        end
    end
end

local function ShowSatellites()
    for _, info in ipairs(KNOWN_VOID_ADDONS) do
        local btn = _G[info.name .. "MinimapBtn"]
        if btn and btn.Show then btn:Show() end
    end
end

----------------------------------------------------------------------
-- Slash command for the hub itself: /vhub
----------------------------------------------------------------------
SLASH_VOIDHUB1 = "/vhub"
SlashCmdList["VOIDHUB"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    VoidHubCharDB = VoidHubCharDB or {}
    if msg == "satellites" or msg == "sat" or msg == "icons" then
        VoidHubCharDB.showSatellites = not VoidHubCharDB.showSatellites
        if VoidHubCharDB.showSatellites then
            ShowSatellites()
            print("|cff00c7ff[VoidHub]|r Individual minimap icons |cff66ff66shown|r.")
        else
            HideSatellites()
            print("|cff00c7ff[VoidHub]|r Individual minimap icons |cffff9933hidden|r — use the hub.")
        end
    elseif msg == "info" or msg == "i" then
        ToggleInfo()
    elseif msg == "" or msg == "help" then
        print("|cff00c7ff[VoidHub]|r Commands:")
        print("  |cff00c7ff/vhub|r — show this help")
        print("  |cff00c7ff/vhub satellites|r — toggle individual minimap icons")
        print("  |cff00c7ff/vhub info|r — open the Void Addons info panel")
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    C_Timer.After(0.5, function()
        CreateHubButton()
        HideSatellites()
    end)
    -- Re-sweep for late-loading addons (LoD, etc.)
    C_Timer.After(2.0, HideSatellites)
    C_Timer.After(5.0, HideSatellites)
end)
