-- Behaviour harness for hyde/binds.lua's action replay -- the path the keybind
-- hint menu uses. hyprctl reports a Lua bind only as a registry reference, so
-- the hint dispatches `hyde.binds.action("<ref>", "<token>")`, built from the
-- token hyde/binds.lua publishes in lua_bind_actions.json. The module has to
-- return the action that registration was created with, and fail loudly for
-- anything else: a stale token, an expired or disabled handle, a reference it
-- never saw.
--
-- REPO_ROOT selects the tree under test and HYDE_TEST_CACHE the cache
-- directory the manifest is published under. Everything Hyprland exposes is
-- stubbed: no compositor runs, nothing is dispatched, and only files under
-- that cache directory are written.

local repo_root = assert(os.getenv("REPO_ROOT"), "REPO_ROOT is not set")
local cache_root = assert(os.getenv("HYDE_TEST_CACHE"), "HYDE_TEST_CACHE is not set")
local binds_path = repo_root .. "/Configs/.local/share/hypr/lua/hyde/binds.lua"
local manifest_path = cache_root .. "/hyde/lua_bind_actions.json"

local failures = 0

local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("    fail: " .. message)
    end
    return condition
end

local function read_file(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function escape_pattern(text)
    return (text:gsub("[%p]", "%%%0"))
end

-- The token published for one registry reference: the hint only ever dispatches
-- what this manifest says, so this is where the token comes from.
local function published_token(ref)
    local text = read_file(manifest_path)
    if text == nil then
        return nil
    end
    return text:match('"' .. escape_pattern(ref) .. '"%s*:%s*"([^"]*)"')
end

local function replay(ref, token)
    if type(hyde.binds) ~= "table" or type(hyde.binds.action) ~= "function" then
        return false, "hyde.binds.action is not exported"
    end
    return pcall(hyde.binds.action, ref, token)
end

-- One Hyprland-like load: the stub only knows what hyprctl would report, which
-- is the reference on the handle hl.bind() returns.
local function new_session(options)
    options = options or {}
    local session = {records = {}, handlers = {}, next_arg = 100, forced_ref = nil}

    local function dsp_proxy(prefix)
        return setmetatable(
            {},
            {
                __index = function(_, key)
                    return dsp_proxy(prefix == "" and key or prefix .. "." .. key)
                end,
                __call = function(_, ...)
                    return {dispatcher = prefix, args = {...}}
                end
            }
        )
    end

    local function native_bind(combo, action, opts)
        local ref = session.forced_ref
        session.forced_ref = nil
        if ref == nil then
            ref = tostring(session.next_arg)
            session.next_arg = session.next_arg + 1
        else
            ref = tostring(ref)
            if tonumber(ref) and tonumber(ref) >= session.next_arg then
                session.next_arg = tonumber(ref) + 1
            end
        end

        local handle = {combo = combo, action = action, opts = opts}
        if not options.bare_handle then
            handle.arg = ref
        end
        handle.enabled = true
        function handle:is_enabled()
            return self.enabled
        end
        session.records[#session.records + 1] = handle
        return handle
    end

    _G.hl = {
        dsp = dsp_proxy(""),
        bind = native_bind,
        unbind = function(target)
            if type(target) == "table" then
                target.enabled = nil
                return
            end
            for index = #session.records, 1, -1 do
                if session.records[index].combo == target then
                    session.records[index].enabled = nil
                    return
                end
            end
        end,
        on = function(event, handler)
            session.handlers[event] = session.handlers[event] or {}
            table.insert(session.handlers[event], handler)
        end,
        dispatch = function() end,
        notification = {create = function() end},
        get_active_window = function()
            return {fullscreen = 0, floating = false}
        end
    }
    _G.hyde = {path = {cache = cache_root}}

    session.load = function()
        dofile(binds_path)
    end
    session.fire = function(event)
        for _, handler in ipairs(session.handlers[event] or {}) do
            handler()
        end
    end
    session.force = function(ref)
        session.forced_ref = tostring(ref)
    end
    return session
end

-- An older Hyprland exposes no handle.arg. There is nothing the hint could
-- replay then, so no reference may be published and no combo may stand in for
-- one.
local legacy = new_session({bare_handle = true})
legacy.load()
hl.bind("SUPER + Q", hl.dsp.exec_cmd("hyde-shell app -- kitty"), {description = "no reference"})
legacy.fire("hyprland.start")
local legacy_manifest = read_file(manifest_path)
check(legacy_manifest ~= nil, "the manifest is not published when a load sees no registry reference")
if legacy_manifest then
    check(
        legacy_manifest:find('"100"') == nil,
        "a bind without a registry reference was published anyway"
    )
end
check(not replay("100", "0"), "a bind without a registry reference is replayable")
check(not replay("SUPER + Q", "0"), "a bind was replayed by its combo instead of a registry reference")

-- The live case: several registrations of one combo must stay distinct, and
-- each must replay exactly the action it was created with.
local session = new_session()
session.load()
-- Held for the rest of the run: the fresh load below must not be able to reuse
-- this module's generation table address and mint the same generation string.
local retained_action = hyde.binds.action
check(type(retained_action) == "function", "hyde.binds.action is not exported")

local runs = {release = 0, plain = 0}

local press_action = hl.dsp.exec_cmd("hyde-shell app -- kitty")
local press = hl.bind("SUPER + Q", press_action, {description = "press"})
local release_action = function()
    runs.release = runs.release + 1
end
local release = hl.bind("SUPER + Q", release_action, {description = "on release", release = true})
local submap_action = hl.dsp.window.close()
local submap = hl.bind("SUPER + Q", submap_action, {description = "close", submap = "resize"})
local plain_action = function()
    runs.plain = runs.plain + 1
end
local plain = hl.bind("SUPER + W", plain_action, {description = "plain"})

check(type(press) == "table" and press.arg ~= nil, "hl.bind does not return a handle carrying .arg")
check(type(press) == "table" and type(press.is_enabled) == "function",
    "the handle hl.bind returns has no is_enabled()")

local seen_refs = {}
for label, handle in pairs({press = press, release = release, submap = submap, plain = plain}) do
    if check(type(handle) == "table" and handle.arg ~= nil, label .. " bind has no registry reference") then
        local ref = tostring(handle.arg)
        check(seen_refs[ref] == nil,
            string.format("%s bind reuses registry reference %s, so one of them is unreachable", label, ref))
        seen_refs[ref] = label
    end
end

session.fire("hyprland.start")
check(read_file(manifest_path) ~= nil, "lua_bind_actions.json is not published on hyprland.start")

local function check_replay(label, handle, expected)
    if not check(type(handle) == "table" and handle.arg ~= nil, label .. " bind has no registry reference") then
        return nil
    end
    local ref = tostring(handle.arg)
    local token = published_token(ref)
    if not check(token ~= nil, string.format("no token published for the %s bind (reference %s)", label, ref)) then
        return nil
    end
    local ok, action = replay(ref, token)
    if not check(ok, string.format("the %s bind (reference %s) does not replay: %s", label, ref, tostring(action))) then
        return nil
    end
    check(rawequal(action, expected), string.format("the %s bind replayed another bind's action", label))
    return token
end

check_replay("press", press, press_action)
check_replay("release", release, release_action)
check_replay("submap", submap, submap_action)
check_replay("plain", plain, plain_action)

local press_ref = tostring(press.arg)
local press_token = published_token(press_ref)

-- Every way a hint cache goes stale has to fail rather than run something.
check(not replay("999999", "table: 0x0:1"), "an unknown registry reference replayed")
check(not replay(press_ref, "table: 0x0:1"), "a wrong token for a live reference replayed")
check(not replay(press_ref), "a missing token replayed")

hl.unbind(release)
check(release.enabled == nil, "the stub did not expire the unbound handle")
check(not replay(tostring(release.arg), published_token(tostring(release.arg))),
    "an unbound bind replayed anyway")
check(runs.release == 0, "an unbound bind's action ran")

plain.enabled = false
check(not replay(tostring(plain.arg), published_token(tostring(plain.arg))),
    "a disabled bind replayed anyway")
check(runs.plain == 0, "a disabled bind's action ran")
plain.enabled = true

-- Hyprland reuses a reference once its bind is gone: the token of the removed
-- registration must not reach the bind that now owns the reference.
local reused_ref = "4242"
session.force(reused_ref)
local removed_action = function()
    runs.removed = (runs.removed or 0) + 1
end
local removed = hl.bind("SUPER + F8", removed_action, {description = "removed"})
session.fire("config.reloaded")
local removed_token = published_token(reused_ref)
check(removed_token ~= nil, "the first bind at a reused reference was not published")

hl.unbind(removed)
session.force(reused_ref)
local replacement_action = function()
    runs.replacement = (runs.replacement or 0) + 1
end
local replacement = hl.bind("SUPER + F9", replacement_action, {description = "replacement"})
session.fire("config.reloaded")
local replacement_token = published_token(reused_ref)
check(replacement_token ~= nil, "the replacement bind at a reused reference was not published")
check(replacement_token ~= removed_token, "rebinding a registry reference kept the removed token")
check(not replay(reused_ref, removed_token),
    "the removed bind's token still replays once its reference was reused")
check((runs.replacement or 0) == 0, "a stale token ran the replacement bind's action")
local ok, action = replay(reused_ref, replacement_token)
check(ok and rawequal(action, replacement_action),
    "the reused reference does not replay the bind that now owns it")

-- The export hook is callable on its own (the live probe and a reload use the
-- same path) and leaves nothing behind when it works.
os.remove(manifest_path)
check(type(hyde.binds._write_actions_cache) == "function",
    "hyde.binds._write_actions_cache is not exported")
if type(hyde.binds._write_actions_cache) == "function" then
    hyde.binds._write_actions_cache()
    check(read_file(manifest_path) ~= nil, "the export hook does not write the manifest when called")
    check(read_file(manifest_path .. ".tmp") == nil, "the export hook left its temporary manifest behind")
end

-- A fresh load (new Lua state, as a new session or a re-executed module gets)
-- starts a new generation, so a token from the previous load must not reach a
-- bind that was registered after it.
local fresh = new_session()
fresh.load()
local fresh_runs = 0
local recycled_action = function()
    fresh_runs = fresh_runs + 1
end
fresh.force(press_ref)
local recycled = hl.bind("SUPER + Q", recycled_action, {description = "recycled"})
hl.bind("SUPER + F1", hl.dsp.window.float(), {description = "float"})
hl.bind("SUPER + F2", function() end, {description = "plain"})
fresh.fire("hyprland.start")

local fresh_token = published_token(press_ref)
check(fresh_token ~= nil, "a fresh load did not publish a token for its own bind")
check(fresh_token ~= press_token, "a fresh load reused the previous load's token")
check(not replay(press_ref, press_token), "a token from the previous load replayed a new bind")
check(fresh_runs == 0, "a stale token from the previous load ran a new bind's action")
ok, action = replay(press_ref, fresh_token)
check(ok and rawequal(action, recycled_action), "the fresh load's token does not replay its own bind")

-- The published file is what the hint reads: a single line of reference to
-- token, never an expression and never a command.
local manifest = read_file(manifest_path) or ""
local body = manifest:gsub("%s+$", "")
check(manifest ~= "", "no manifest was published by the fresh load")
check(body:find("\n") == nil, "the manifest is not a single line, so a value could break the reader")
check(manifest:find("hyde%.binds%.action") == nil, "the manifest carries expressions instead of tokens")
check(manifest:find("exec_cmd") == nil, "the manifest carries a command")
for ref in pairs({[press_ref] = true, ["101"] = true, ["102"] = true}) do
    check(published_token(ref) ~= nil, string.format("reference %s is missing from the published manifest", ref))
end

print(string.format("    %d bind(s) registered, %d manifest reference(s) checked", #session.records,
    select(2, manifest:gsub('"[%d]+"%s*:', ""))))

os.exit(failures == 0 and 0 or 1)
