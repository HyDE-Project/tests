#!/usr/bin/env sh
# waybar.py's layout backups must not count as layouts, and --next/--prev
# must survive a backup being the current layout (HyDE-Project/HyDE#2133).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_layout_nav.py" ||
    fail "waybar.py treats a layout backup as a layout"

finish
