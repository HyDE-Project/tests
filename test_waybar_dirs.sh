#!/usr/bin/env sh
# waybar.py must search /usr/share, not a relative usr/share under whatever
# directory it runs from.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_dirs.py" ||
    fail "waybar.py searches a relative usr/share"

finish
