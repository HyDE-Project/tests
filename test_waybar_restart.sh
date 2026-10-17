#!/usr/bin/env sh
# Switching layouts must restart Waybar once, from complete files: under
# systemd restart_waybar() restarts the unit instead of hot-reloading it with
# SIGUSR2, the files Waybar reads are replaced atomically, and one --set
# refreshes and restarts once (HyDE-Project/HyDE#2184).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_restart.py" ||
    fail "a layout switch does not restart Waybar once from complete files"

finish
