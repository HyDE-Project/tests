-- open.lua resolves which desktop entry to launch for a MIME type in a
-- documented order (open.lua: "1) config.toml mapping 2) mime default
-- 3) --fall"): a user-configured app for the keyword, then the desktop's own
-- default for the MIME, then the caller's --fall as the last resort. Each
-- tier must win over the ones below it, and only be tried once the ones
-- above it fail to resolve. `REPO_ROOT` selects the tree to check, which
-- lets the same harness run against any checkout.

local repo_root = assert(os.getenv("REPO_ROOT"), "REPO_ROOT is not set")
local open_lua = repo_root .. "/Configs/.local/lib/hyde/open.lua"

package.preload["lgi"] = function()
    return {Gio = {}, GLib = {}}
end

local open = assert(loadfile(open_lua))("__test__")

local function fake_app(id)
    return {
        get_id = function()
            return id
        end,
        get_name = function()
            return id
        end
    }
end

local function reset()
    local launches = {}
    open.resolve_mime = function()
        return "text/html"
    end
    open.set_default_app_for_mime = function()
        return true
    end
    open.launch_app_for_files = function(appinfo)
        table.insert(launches, appinfo:get_id())
        return true
    end
    return launches
end

local function run_case(label, configured_app, mime_default_id, fallback, appinfo_map, expected)
    local launches = reset()

    open.get_configured_app_for_keyword = function(keyword)
        if keyword == "web-browser" then
            return configured_app
        end
        return nil
    end

    open.appinfo_from_desktop = function(name)
        local id = appinfo_map[name]
        if id then
            return fake_app(id)
        end
        return nil, "missing"
    end

    open.find_default_app_for_mime = function()
        if mime_default_id then
            return fake_app(mime_default_id)
        end
        return nil, "no default for mime"
    end

    local args = {[0] = "hyde-shell", "open", "web-browser", "--std"}
    if fallback then
        table.insert(args, "--fall")
        table.insert(args, fallback)
    end

    local rc = open.cli_main(args)
    assert(rc == 0, label .. ": cli_main failed with " .. tostring(rc))
    assert(#launches == 1, label .. ": expected exactly one launch, got " .. tostring(#launches))
    assert(
        launches[1] == expected,
        label .. ": expected " .. expected .. ", got " .. tostring(launches[1])
    )
end

-- Tier 1 wins outright: a resolvable configured app beats both the mime
-- default and --fall, even though both are also available here.
run_case(
    "configured-first",
    "config.desktop",
    "mime.desktop",
    "fallback.desktop",
    {["config.desktop"] = "config.desktop", ["fallback.desktop"] = "fallback.desktop"},
    "config.desktop"
)

-- Tier 1 fails to resolve (not on disk) -- tier 2 wins over tier 3, even
-- though --fall is also available here.
run_case(
    "mime-default-second",
    "missing.desktop",
    "mime.desktop",
    "fallback.desktop",
    {["fallback.desktop"] = "fallback.desktop"},
    "mime.desktop"
)

-- Tiers 1 and 2 both fail -- --fall is the last resort.
run_case("fallback-last", "missing.desktop", nil, "fallback.desktop", {
    ["fallback.desktop"] = "fallback.desktop"
}, "fallback.desktop")

print("open.lua priority checked")
