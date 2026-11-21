#!/usr/bin/env sh
# weather.py cuts the first day by the weather location's clock, not the
# host's (HyDE-Project/HyDE#2159).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

# weather.py imports requests at module level; without it nothing can be loaded.
if ! python3 -c 'import requests' >/dev/null 2>&1; then
    skip "python3 requests is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_weather_location_hour.py" || fail "check_weather_tooltip reported defects"

finish
