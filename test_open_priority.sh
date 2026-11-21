#!/usr/bin/env sh
# hyde-shell open resolves a MIME's app in priority order: the keyword's
# configured app, then --fall, then the desktop's own default. Checked
# against open.lua directly in lua/open_priority_harness.lua.
#
# Moved here from HyDE's .github/scripts/test_open_priority.sh so it runs as
# part of the suite like any other case, instead of a separate workflow step
# (HyDE-Project/HyDE#2178).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

lua "$TESTS_DIR/lua/open_priority_harness.lua" || fail "open_priority_harness reported defects"

finish
