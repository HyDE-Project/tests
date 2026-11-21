#!/usr/bin/env sh
# run_waybar()'s systemd-run fallback must --collect, or a unit stuck
# `failed` from a prior start-limit-hit blocks the recreate with "Unit
# already exists" (HyDE-Project/HyDE#2160). Drives a real systemd --user
# manager; skips where none is reachable.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

if ! command -v systemd-run >/dev/null 2>&1; then
    skip "systemd-run is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_unit_collect.py" ||
    fail "run_waybar() cannot recreate its unit after a prior failure"

finish
