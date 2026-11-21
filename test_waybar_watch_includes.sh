#!/usr/bin/env sh
# waybar.py --watch (the session autostart path) must generate the includes
# that defaults.css imports (HyDE-Project/HyDE#2160).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_watch_includes.py" ||
    fail "waybar.py --watch starts waybar without its CSS includes"

finish
