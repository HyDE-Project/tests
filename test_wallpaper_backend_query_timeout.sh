#!/usr/bin/env sh
# wallpaper.awww.sh and wallpaper.swww.sh probe the wallpaper daemon with
# "<backend> query" before every apply, and again after starting a fresh
# daemon, to decide whether to (re)start it. A stalled/unresponsive daemon
# makes that plain foreground call block forever, hanging theme.switch.sh
# with it -- the same class of bug 137eda17 fixed for the "<backend> img"
# apply call (bounding it with `timeout 30`), but that fix never touched
# the query/restore probe. Reproduced live: with a daemon stub that never
# returns, the caller hung indefinitely at the unguarded "query" line and
# only completed once every backend call, including query and restore, was
# wrapped in `timeout`. Static-check that every "query"/"restore" call in
# both backends stays wrapped, since the actual hang only shows up with a
# live (never terminating) daemon process, not against this checkout.

. "$(dirname -- "$0")/lib/common.sh"

checked=0
for backend in awww swww; do
    script="$REPO_ROOT/Configs/.local/lib/hyde/wallpaper.$backend.sh"
    if [ ! -f "$script" ]; then
        skip "wallpaper.$backend.sh not shipped in this checkout"
        continue
    fi

    calls=$(grep -E "${backend} (query|restore)" "$script")
    if [ -z "$calls" ]; then
        skip "no $backend query/restore calls found in wallpaper.$backend.sh"
        continue
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        checked=$((checked + 1))
        case "$line" in
        *"timeout "*"$backend query"* | *"timeout "*"$backend restore"*)
            continue
            ;;
        esac
        fail "wallpaper.$backend.sh calls '$line' without a timeout -- if the \
$backend daemon is running but unresponsive, this foreground call blocks \
forever and hangs theme.switch.sh with it, exactly the bug 137eda17 fixed \
for the apply command but left open for the query/restore probe."
    done <<EOF
$calls
EOF
done

[ "$checked" -gt 0 ] && printf '    %d %s call(s) checked for a timeout guard\n' "$checked" "query/restore"

finish
