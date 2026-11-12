#!/usr/bin/env sh
# The keybind hint menu runs a bind by the registry reference the compositor
# reports, so hyde/binds.lua has to keep each registration's own action and
# publish the expression that replays it. The Lua harness exercises the module
# against a stubbed Hyprland API and leaves a real lua_bind_actions.json behind;
# the Python check reads that file and the hint script's rewrite rules.

. "$(dirname -- "$0")/lib/common.sh"

have_lua=0
if command -v lua >/dev/null 2>&1; then
    have_lua=1
else
    skip "lua is not installed"
fi

have_python=0
if command -v python3 >/dev/null 2>&1; then
    have_python=1
else
    skip "python3 is not installed"
fi

if [ "$have_lua" -eq 0 ] && [ "$have_python" -eq 0 ]; then
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cache_home="$work_dir/cache"
mkdir -p "$cache_home/hyde"
manifest="$cache_home/hyde/lua_bind_actions.json"

if [ "$have_lua" -eq 1 ]; then
    HYDE_TEST_CACHE="$cache_home" \
        lua "$TESTS_DIR/lua/bind_actions_harness.lua" ||
        fail "bind_actions_harness reported defects"
fi

if [ "$have_python" -eq 1 ]; then
    if [ "$have_lua" -eq 1 ]; then
        HYDE_TEST_MANIFEST="$manifest" python3 "$TESTS_DIR/python/check_keybind_hint.py" ||
            fail "check_keybind_hint reported defects"
    else
        python3 "$TESTS_DIR/python/check_keybind_hint.py" ||
            fail "check_keybind_hint reported defects"
    fi
fi

finish
