#!/usr/bin/env sh
# "Show Cover" in the mediaplayer/spotify right-click menus opens mediacover.py,
# a layer-shell popup with the album art (#2153). Its display-free logic
# (art URL -> local file, cache, player choice, placement, toggle) and the
# menu wiring are checked in python/check_media_cover.py.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_media_cover.py" ||
    fail "mediacover.py or its menu wiring is broken"

finish
