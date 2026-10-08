#!/usr/bin/env sh
# Waybar's SIGUSR2 hot-reload must signal only Waybar's own process, not
# every process in its systemd unit's cgroup (HyDE-Project/HyDE#2184).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 "$TESTS_DIR/python/check_waybar_signal_kill_who.py" ||
    fail "_signal_waybar() does not restrict the systemd kill to the main process"

finish
