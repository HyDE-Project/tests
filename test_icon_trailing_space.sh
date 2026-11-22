#!/usr/bin/env sh
# An icon-only Waybar module's glyph overflow must be absorbed by CSS
# padding-right in defaults.css, not a trailing space in its format string,
# or centered modules (e.g. custom/caffeine) skew off-center (#2206).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_icon_trailing_space.py" ||
    fail "an icon-only module's overflow padding regressed"

finish
