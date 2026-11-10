#!/usr/bin/env sh
# File-manager dialogs (Dolphin's Properties, Copying, ...) must float while
# the main windows tile: a trailing float = false rule for all file managers
# used to override the dialog title rules (HyDE-Project/HyDE#2211).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    skip "lua or python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_window_rules_float.py" ||
    fail "window_rules.lua tiles file-manager dialogs or floats their main windows"

finish
