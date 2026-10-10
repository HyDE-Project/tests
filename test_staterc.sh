#!/usr/bin/env bash
##
# staterc writes.
#
# waybar.py, set_conf() and the Lua selectors all rewrite
# $XDG_STATE_HOME/hyde/staterc. Unlocked and truncated in place, two of them
# at once wiped it down to one line (HyDE-Project/HyDE#2194). staterc.sh is
# the locked, atomic writer that set_conf() and Lua share: one KEY="value"
# line per key, every other line kept, values stored literally.
##

. "$(dirname -- "$0")/lib/common.sh"

helper="$REPO_ROOT/Configs/.local/lib/hyde/staterc.sh"
global_control="$REPO_ROOT/Configs/.local/lib/hyde/globalcontrol.sh"

if [ ! -f "$helper" ]; then
    fail "missing Configs/.local/lib/hyde/staterc.sh"
    finish
fi

work_dir=$(mktemp -d)
trap 'chmod -R u+w "$work_dir" 2>/dev/null; rm -rf "$work_dir"' EXIT

state_home="$work_dir/state"
staterc="$state_home/hyde/staterc"

##
# Runs the helper against the private state home.
##
set_state() {
    XDG_STATE_HOME="$state_home" bash "$helper" set "$@"
}

##
# Starts a case from the given staterc content, or from no hyde/ directory.
##
reset_state() {
    chmod -R u+w "$state_home" 2>/dev/null
    rm -rf "$state_home"
    if [ "$#" -gt 0 ]; then
        mkdir -p "$state_home/hyde"
        printf '%s' "$1" >"$staterc"
    fi
}

expect() {
    [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

leftovers() {
    find "$state_home/hyde" -name '.staterc.*' 2>/dev/null | wc -l
}

# 1. fresh install: no hyde/ directory yet
reset_state
(umask 022 && set_state A 1)
expect 'A="1"' "$(cat "$staterc" 2>/dev/null)" "fresh install content"
expect 644 "$(stat -c %a "$staterc" 2>/dev/null)" "fresh install mode under umask 022"

# 2. replace in place, other lines and order kept
reset_state $'X="1"\nA="old"\nY="2"\n'
set_state A new
expect $'X="1"\nA="new"\nY="2"' "$(cat "$staterc")" "replace in place"

# 3. a key present twice ends up once, at its first position
reset_state $'A="1"\nB="2"\nA="3"\n'
set_state A z
expect $'A="z"\nB="2"' "$(cat "$staterc")" "duplicate key collapsed"

# 4. values are stored literally and read back by `source`
for value in '/usr/share/a b' 'x&y' 'a|b' 'back\slash' '50%'; do
    reset_state
    set_state K "$value"
    got=$(bash -c '. "$1"; printf %s "$K"' _ "$staterc")
    expect "$value" "$got" "literal value"
done

# 5. usage errors exit 2 and leave the file alone
reset_state $'A="1"\n'
set_state 1bad v 2>/dev/null
expect 2 "$?" "invalid key exit status"
set_state onlyone 2>/dev/null
expect 2 "$?" "missing value exit status"
expect 'A="1"' "$(cat "$staterc")" "file after usage errors"

# 6. concurrent writers lose nothing
seed=""
for i in 0 1 2 3 4 5 6 7; do seed="${seed}S$i=\"s$i\""$'\n'; done
reset_state "$seed"
for i in $(seq 1 40); do set_state "K$i" "v$i" & done
wait
for i in 0 1 2 3 4 5 6 7; do
    expect 1 "$(grep -c "^S$i=\"s$i\"\$" "$staterc")" "seed S$i after concurrent writes"
done
for i in $(seq 1 40); do
    expect 1 "$(grep -c "^K$i=\"v$i\"\$" "$staterc")" "K$i after concurrent writes"
done
expect 0 "$(leftovers)" "temp files left after concurrent writes"

# 7. an existing file keeps its mode
reset_state $'A="1"\n'
chmod 600 "$staterc"
set_state A 2
expect 600 "$(stat -c %a "$staterc")" "mode of an existing staterc"

# 8. a failed write exits 1 and leaves staterc unchanged
if [ "$(id -u)" -ne 0 ]; then
    reset_state $'A="1"\n'
    chmod 500 "$state_home/hyde"
    set_state A b 2>/dev/null
    expect 1 "$?" "exit status when the directory is read-only"
    chmod 700 "$state_home/hyde"
    expect 'A="1"' "$(cat "$staterc")" "staterc after a failed write"
    expect 0 "$(leftovers)" "temp files left after a failed write"
fi

# 9. set_conf() goes through the helper: its old sed ate backslashes and
# appended a third copy of a key that was already present twice
reset_state $'A="1"\nB="2"\nA="3"\n'
env -i \
    HOME="$work_dir/home" \
    XDG_CONFIG_HOME="$work_dir/home/.config" \
    XDG_DATA_HOME="$work_dir/home/.local/share" \
    XDG_CACHE_HOME="$work_dir/home/.cache" \
    XDG_STATE_HOME="$state_home" \
    XDG_RUNTIME_DIR="$work_dir/run" \
    LIB_DIR="$REPO_ROOT/Configs/.local/lib" \
    PATH="/usr/bin:/bin" \
    bash -c ". '$global_control' >/dev/null 2>&1 || exit 97; set_conf A 'back\\slash'"
expect 0 "$?" "set_conf exit status"
expect 'A="back\slash"' "$(grep '^A=' "$staterc")" "set_conf with a backslash in the value"

finish
