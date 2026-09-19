#!/usr/bin/env bash
# Waybar's native `idle_inhibitor` module keeps its on/off state only in
# Waybar's own process memory. Waybar hot-reloads its config via SIGUSR2 on
# routine theme/wallpaper changes (not just --hide), reinitializing every
# module -- silently resetting Caffeine mode to off with no notification
# (issue #2117). caffeine.sh fixes this by tracking state in a file and doing
# the actual inhibiting with a `systemd-inhibit` background process, which is
# independent of Waybar's lifecycle.
#
# This covers: fresh/missing state, toggle on/off, a dead inhibitor pid, a
# pid reused by an unrelated process, several shapes of a corrupted state
# file, a missing systemd-inhibit binary, invalid --sigproc input, and a
# concurrent double-toggle race -- not just the on/off happy path.

. "$(dirname -- "$0")/lib/common.sh"

script="$REPO_ROOT/Configs/.local/lib/hyde/caffeine.sh"
[ -f "$script" ] || {
    fail "caffeine.sh not found at $script"
    finish
}

if ! command -v flock >/dev/null 2>&1; then
    skip "flock is not installed"
    finish
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# A curated PATH: every real /usr/bin tool except systemd-inhibit (so
# `command -v` genuinely fails for it, instead of finding the real one),
# plus a fake systemd-inhibit that behaves like the real one closely enough
# for this script (backgroundable, killable, real comm name for `ps`).
real_path="$work_dir/real-path"
mkdir -p "$real_path"
for f in /usr/bin/*; do
    name=$(basename "$f")
    [ "$name" = "systemd-inhibit" ] && continue
    ln -s "$f" "$real_path/$name" 2>/dev/null
done
cat >"$real_path/systemd-inhibit" <<'EOF'
#!/bin/sh
# Mimics the real systemd-inhibit closely enough for this test (verified
# against the actual binary): it stays alive as its own process -- comm
# matches this script's name, not whatever it wraps -- runs the wrapped
# command as a child, and forwards TERM to that child, so killing the
# parent pid (what caffeine.sh records) cleans up both.
trap 'kill "$child_pid" 2>/dev/null; exit 0' TERM INT
sleep infinity &
child_pid=$!
wait "$child_pid"
EOF
chmod +x "$real_path/systemd-inhibit"
hyde_bin="$REPO_ROOT/Configs/.local/bin"
full_path="$real_path:$hyde_bin"

home_dir="$work_dir/home"
state_file=""

run() {
    local use_path="${CAFFEINE_TEST_PATH:-$full_path}"
    mkdir -p "$home_dir/.config" "$home_dir/.local/share" "$home_dir/.cache" \
        "$home_dir/.local/state" "$home_dir/run"
    env -i \
        HOME="$home_dir" \
        XDG_CONFIG_HOME="$home_dir/.config" \
        XDG_DATA_HOME="$home_dir/.local/share" \
        XDG_CACHE_HOME="$home_dir/.cache" \
        XDG_STATE_HOME="$home_dir/.local/state" \
        XDG_RUNTIME_DIR="$home_dir/run" \
        PATH="$use_path" \
        bash "$script" "$@"
}

fresh_home() {
    rm -rf "$home_dir"
    home_dir="$work_dir/home-$1"
    state_file="$home_dir/run/hyde/caffeine"
}

state_intended() {
    [ -f "$state_file" ] || { echo ""; return; }
    IFS='|' read -r intended _ <"$state_file"
    echo "$intended"
}
state_pid() {
    [ -f "$state_file" ] || { echo ""; return; }
    IFS='|' read -r _ pid <"$state_file"
    echo "$pid"
}

# --- fresh install: no state file yet ---
fresh_home fresh
out=$(run -rq 2>/dev/null)
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "a fresh install did not report deactivated: $out" ;;
esac
[ "$(state_intended)" = "0" ] || fail "a fresh read did not write a clean '0' state"

# --- toggle on: spawns the inhibitor, records a live pid ---
fresh_home toggle-on
out=$(run -tq 2>/dev/null)
case "$out" in
*'"alt":"activated"'*) ;;
*) fail "toggling on did not report activated: $out" ;;
esac
pid=$(state_pid)
[ -n "$pid" ] || fail "toggling on recorded no pid"
if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null || fail "toggling on recorded a pid that isn't running"
    [ "$(ps -p "$pid" -o comm= 2>/dev/null)" = "systemd-inhibit" ] ||
        fail "the recorded pid is not a systemd-inhibit process"
fi

# --- toggle off from on: kills the inhibitor, clears the pid ---
out=$(run -tq 2>/dev/null)
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "toggling off did not report deactivated: $out" ;;
esac
[ "$(state_pid)" = "" ] || fail "toggling off left a pid behind"
if [ -n "$pid" ]; then
    sleep 0.2
    kill -0 "$pid" 2>/dev/null && fail "toggling off did not actually stop the inhibitor process"
fi

# --- a stale/dead pid in the state file self-heals to off ---
fresh_home stale-dead
mkdir -p "$(dirname "$state_file")"
printf '1|999999999\n' >"$state_file"
out=$(run -rq 2>/dev/null)
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "a dead recorded pid was not treated as deactivated: $out" ;;
esac
[ "$(state_intended)" = "0" ] || fail "a dead recorded pid was not self-healed to '0' on disk"

# --- a pid reused by an unrelated live process is not mistaken for ours ---
fresh_home stale-reused
sleep 30 &
other_pid=$!
mkdir -p "$(dirname "$state_file")"
printf '1|%d\n' "$other_pid" >"$state_file"
out=$(run -rq 2>/dev/null)
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "a pid belonging to an unrelated process was treated as our inhibitor: $out" ;;
esac
kill -0 "$other_pid" 2>/dev/null || fail "reconciling a reused pid killed the unrelated process instead of leaving it alone"
kill "$other_pid" 2>/dev/null

# --- malformed state files fall back to a clean 'off' instead of erroring ---
fresh_home malformed
mkdir -p "$(dirname "$state_file")"
for content in 'garbage nonsense' '' 'yes|123|extra|fields' '2|abc' '|'; do
    printf '%s' "$content" >"$state_file"
    out=$(run -rq 2>/dev/null)
    case "$out" in
    *'"alt":"deactivated"'*) ;;
    *) fail "malformed state ('$content') was not handled, got: $out" ;;
    esac
done

# --- systemd-inhibit missing: fails loudly, does not claim to be activated ---
fresh_home no-binary
mkdir -p "$real_path-nosysd"
for f in "$real_path"/*; do
    name=$(basename "$f")
    [ "$name" = "systemd-inhibit" ] && continue
    ln -s "$f" "$real_path-nosysd/$name" 2>/dev/null
done
CAFFEINE_TEST_PATH="$real_path-nosysd:$hyde_bin" out=$(run -tq 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "toggling on with no systemd-inhibit binary exited 0"
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "toggling on with no systemd-inhibit binary did not fall back to deactivated: $out" ;;
esac
[ "$(state_pid)" = "" ] || fail "a failed inhibitor start still recorded a pid"

# --- invalid --sigproc input is reported, without breaking the main action ---
fresh_home sigproc-bad-format
out=$(run -rq -P "no-delimiter-here" 2>&1)
case "$out" in
*'Invalid sigproc format'*) ;;
*) fail "a malformed --sigproc value produced no error: $out" ;;
esac
case "$out" in
*'"alt":"deactivated"'*) ;;
*) fail "a malformed --sigproc value broke the main status output: $out" ;;
esac

fresh_home sigproc-bad-signal
out=$(run -rq -P "waybar,not-a-number" 2>&1)
case "$out" in
*'Signal must be a number'*) ;;
*) fail "a non-numeric --sigproc signal produced no error: $out" ;;
esac

# --- no action / unknown flag: clear failure, not a silent no-op ---
fresh_home no-args
out=$(run 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "running with no arguments exited 0"
case "$out" in
*'No arguments provided'*) ;;
*) fail "running with no arguments gave no explanation: $out" ;;
esac

fresh_home bad-flag
run --this-flag-does-not-exist >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] || fail "an unrecognised flag exited 0"

# --- an unset XDG_RUNTIME_DIR must fail clearly, not fall back to a shared,
# predictable /tmp location another local user could pre-plant (CWE-377:
# a symlink or pre-owned directory at that fixed path would let a different
# user intercept or interfere with this user's state and inhibitor pid). ---
fresh_home no-runtime-dir
out=$(env -i \
    HOME="$home_dir" \
    XDG_CONFIG_HOME="$home_dir/.config" \
    XDG_DATA_HOME="$home_dir/.local/share" \
    XDG_CACHE_HOME="$home_dir/.cache" \
    XDG_STATE_HOME="$home_dir/.local/state" \
    PATH="$full_path" \
    bash "$script" -rq 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "an unset XDG_RUNTIME_DIR exited 0"
case "$out" in
*'XDG_RUNTIME_DIR is not set'*) ;;
*) fail "an unset XDG_RUNTIME_DIR gave no explanation: $out" ;;
esac
[ -e "/tmp/hyde" ] && fail "an unset XDG_RUNTIME_DIR still created a shared /tmp/hyde fallback"

# --- concurrent toggles: the lock keeps the state file and inhibitor
# bookkeeping consistent instead of corrupting it ---
fresh_home concurrent
for _ in 1 2 3 4; do
    run -tq >/dev/null 2>&1 &
done
wait
if [ -f "$state_file" ]; then
    IFS='|' read -r final_intended final_pid <"$state_file"
    case "$final_intended" in
    0 | 1) ;;
    *) fail "concurrent toggles left a corrupted state file: $(cat "$state_file")" ;;
    esac
    if [ "$final_intended" = "1" ]; then
        [ -n "$final_pid" ] && kill -0 "$final_pid" 2>/dev/null ||
            fail "concurrent toggles left 'on' recorded with no live inhibitor"
        [ "$(ps -p "$final_pid" -o comm= 2>/dev/null)" = "systemd-inhibit" ] ||
            fail "concurrent toggles recorded a pid that isn't systemd-inhibit"
        kill "$final_pid" 2>/dev/null
    else
        [ -z "$final_pid" ] || fail "concurrent toggles left 'off' recorded with a stray pid"
    fi
else
    fail "concurrent toggles left no state file at all"
fi

printf '    caffeine.sh persistence and edge cases checked\n'

finish
