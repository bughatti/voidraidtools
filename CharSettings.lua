----------------------------------------------------------------------
-- CharSettings (shared; one identical copy per addon, like the hub bundle):
-- per-character settings without changing how the addon reads them.
--
-- The addon keeps its settings where it always has (VoidXDB.config,
-- VoidXDB.someToggle). This file swaps them per character:
--   ADDON_LOADED   this character's saved values are put in place. A
--                  character seen for the first time keeps what's there:
--                  the settings of the character played last (or the old
--                  shared ones), so a new alt starts set up and nothing
--                  resets on update.
--   PLAYER_LOGOUT  the values are saved back under this character (after
--                  the addon's own logout handlers, which may write settings).
-- Paths listed in `shared` (window positions) stay account-wide.
-- Each character's copy lives in VoidXDB.chars["Name-Realm"].
--
-- Usage, in the addon's own files (loads before them in the TOC):
--   ns.CharSettings.Register("VoidGather", "VoidGatherDB", { "config" },
--       { "config.earnPos", "config.hudPos" })
-- Copy another character's settings: ns.CharSettings.Characters(addon),
-- ns.CharSettings.CopyFrom(addon, key), then ReloadUI().
----------------------------------------------------------------------
local _, ns = ...
local CS = {}
ns.CharSettings = CS

local specs = {}   -- addon -> { db, keys, shared }

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

local function getPath(t, path)
    for part in path:gmatch("[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[part]
    end
    return t
end

-- A value being put back creates its missing parents; clearing one (nil)
-- doesn't.
local function setPath(t, path, value)
    local parts = {}
    for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
        if type(t[parts[i]]) ~= "table" then
            if value == nil then return end
            t[parts[i]] = {}
        end
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
end

local function me()
    local name = UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if not (name and realm and realm ~= "") then return nil end
    return name .. "-" .. realm:gsub("%s", "")
end
CS.Me = me

-- The addon's SavedVariables table, or nil on a fresh install (never created
-- here: the addon's own `DB = DB or { defaults }` must still run).
local function dbOf(spec)
    local db = _G[spec.db]
    if type(db) ~= "table" then return nil end
    if type(db.chars) ~= "table" then db.chars = {} end
    return db
end

-- Put this character's settings in place (keeping the shared paths).
local function load(spec)
    local key = me()
    if not key then return false end
    spec.loaded = key
    local db = dbOf(spec)
    local mine = db and db.chars[key]
    if type(mine) == "table" then
        local keep = {}
        for _, path in ipairs(spec.shared) do keep[path] = copy(getPath(db, path)) end
        for _, k in ipairs(spec.keys) do db[k] = copy(mine[k]) end
        for path, v in pairs(keep) do setPath(db, path, v) end
    end
    return true
end

-- Save the settings in place under this character. After "copy settings
-- from" the copied snapshot is kept instead: the addon may still write its
-- old settings back on the way out of the /reload.
local function save(spec)
    local key = spec.loaded
    local db = key and not spec.frozen and dbOf(spec)
    if not db then return end
    local mine = {}
    for _, k in ipairs(spec.keys) do mine[k] = copy(db[k]) end
    for _, path in ipairs(spec.shared) do setPath(mine, path, nil) end
    db.chars[key] = mine
end

local frame = CreateFrame("Frame")

-- Our logout save must run after the addons' own logout handlers, which can
-- write settings. Handlers run in registration order, so register (again)
-- once the addons are done setting up: after login, and after any addon
-- that loads later.
local function registerLast()
    frame:UnregisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("PLAYER_LOGOUT")
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        local spec = specs[arg1]
        if spec and not spec.loaded and not load(spec) then spec.late = true end
        if IsLoggedIn and IsLoggedIn() then C_Timer.After(0, registerLast) end   -- loaded on demand
    elseif event == "PLAYER_LOGIN" then
        for _, spec in pairs(specs) do
            if spec.late and not spec.loaded then load(spec) end   -- name wasn't known yet
        end
        registerLast()
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0, registerLast)   -- after handlers the addons added during login
    elseif event == "PLAYER_LOGOUT" then
        for _, spec in pairs(specs) do save(spec) end
    end
end)

-- keys: top-level keys of the addon's SavedVariables table that are settings.
-- shared: dotted paths inside them that stay account-wide (positions).
function CS.Register(addon, dbName, keys, shared)
    specs[addon] = { db = dbName, keys = keys, shared = shared or {} }
    -- The Void hub's "Copy settings from..." (VoidHubBundle.lua) lists every
    -- addon that signed up here, whichever addon's hub copy is running.
    _G.VoidHubSettings = _G.VoidHubSettings or {}
    _G.VoidHubSettings[addon] = {
        characters = function() return CS.Characters(addon) end,
        copyFrom = function(key) return CS.CopyFrom(addon, key) end,
    }
end

-- Other characters with saved settings for this addon, sorted.
function CS.Characters(addon)
    local spec, out = specs[addon], {}
    local db = spec and _G[spec.db]
    if type(db) == "table" and type(db.chars) == "table" then
        for k in pairs(db.chars) do
            if k ~= spec.loaded then out[#out + 1] = k end
        end
    end
    table.sort(out)
    return out
end

-- Take another character's settings: they become this character's saved
-- copy and are put in place by the /reload that must follow (addons keep
-- settings in locals). Shared paths aren't part of a character's copy.
function CS.CopyFrom(addon, key)
    local spec = specs[addon]
    local db = spec and spec.loaded and dbOf(spec)
    local theirs = db and db.chars[key]
    if type(theirs) ~= "table" or key == spec.loaded then return false end
    db.chars[spec.loaded] = copy(theirs)
    spec.frozen = true   -- the logout on the way out of the /reload must not overwrite it
    return true
end
