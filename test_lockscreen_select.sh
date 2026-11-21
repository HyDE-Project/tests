#!/usr/bin/env bash
# `hyde-shell lockscreen --select` (the Waybar HyDE menu's "Lockscreen" entry)
# used to fall through to the normal launch, which passes every argument on to
# the lockscreen: hyprlock.sh knows --select, but any other lockscreen was just
# started, locking the screen instead of offering a choice. --select now only
# hands over to a wrapper script that offers a selector, and fails clearly
# otherwise -- it must never start a lock.
#
# Covers: hyprlock (wrapper with a selector), a lockscreen without a wrapper,
# a wrapper without a selector, one that mentions --select only in a comment,
# one declaring a flag that merely starts with --select, the short flag, an empty/unset override
# falling back to hyprlock, a lockscreen command with arguments, --get and
# --select together, extra arguments after --select, and that a plain call
# and an unknown flag still launch the lockscreen as before.

. "$(dirname -- "$0")/lib/common.sh"

script="$REPO_ROOT/Configs/.local/lib/hyde/lockscreen.sh"
[ -f "$script" ] || {
    fail "lockscreen.sh not found at $script"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
stubs="$work_dir/bin"
log="$work_dir/calls.log"
mkdir -p "$stubs"

# Every stub records how it was called, and nothing else.
stub() {
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n%s\n' "$1" "$log" "${2:-}" >"$stubs/$1"
    chmod +x "$stubs/$1"
}
stub app.sh
stub notify-send
# A wrapper offers a selector by declaring --select through argparse.sh, as
# hyprlock.sh does. The declarations sit after `exit 0`: lockscreen.sh only
# reads them, the stubs never run them.
stub hyprlock.sh 'exit 0
argparse "--select,-S" "" "Selects the hyprlock layout"'
stub swaylock.sh '# a wrapper with no layout selector'
stub commentlock.sh '# --select unsupported, arguments are ignored'
stub selectionlock.sh 'exit 0
argparse "--selection" "" "not the selector"'

# $1.. = lockscreen.sh arguments; LOCK_ENV holds one extra env assignment
# (kept as a single word, so a value with spaces stays intact).
run() {
    : >"$log"
    env -i HOME="$work_dir" PATH="$stubs:/usr/bin:/bin" HYDE_SHELL_INIT=1 \
        LIB_DIR="$REPO_ROOT/Configs/.local/lib" ${LOCK_ENV:+"$LOCK_ENV"} \
        bash "$script" "$@" 2>&1
}

never_locked() {
    grep -q '^app.sh' "$log" && fail "$1 started the lockscreen: $(cat "$log")"
    return 0
}

# --- hyprlock (default): hands over to hyprlock.sh --select, no lock ---
out=$(run --select)
status=$?
[ "$status" -eq 0 ] || fail "--select with hyprlock exited $status: $out"
grep -qx 'hyprlock.sh --select' "$log" || fail "--select did not run hyprlock.sh --select: $(cat "$log")"
never_locked "--select with hyprlock"

# --- the short flag behaves the same ---
run -S >/dev/null
grep -qx 'hyprlock.sh --select' "$log" || fail "-S did not run hyprlock.sh --select: $(cat "$log")"
never_locked "-S"

# --- extra arguments after --select are not passed on to anything ---
run --select --extra 'with space' >/dev/null
grep -qx 'hyprlock.sh --select' "$log" || fail "--select with extra arguments passed them on: $(cat "$log")"
never_locked "--select with extra arguments"

# --- an empty override falls back to hyprlock instead of an empty name ---
LOCK_ENV="HYDE_LOCKSCREEN=" run --select >/dev/null
grep -qx 'hyprlock.sh --select' "$log" || fail "an empty HYDE_LOCKSCREEN did not fall back to hyprlock: $(cat "$log")"

# --- a lockscreen with no wrapper script: clear failure, never a lock ---
out=$(LOCK_ENV="HYDE_LOCKSCREEN=gtklock" run --select)
status=$?
[ "$status" -ne 0 ] || fail "--select without a wrapper exited 0"
case "$out" in *"no layout selector for lockscreen 'gtklock'"*) ;; *) fail "--select without a wrapper gave no explanation: $out" ;; esac
grep -q '^notify-send' "$log" || fail "--select without a wrapper sent no notification"
never_locked "--select without a wrapper"

# --- a wrapper that has no selector is not started either ---
out=$(LOCK_ENV="HYDE_LOCKSCREEN=swaylock" run --select)
status=$?
[ "$status" -ne 0 ] || fail "--select with a selector-less wrapper exited 0"
grep -q '^swaylock.sh' "$log" && fail "--select started a wrapper that has no selector: $(cat "$log")"
never_locked "--select with a selector-less wrapper"

# --- a wrapper that only mentions --select (a comment) or declares a flag that
# merely starts with it is not a selector: never started ---
for name in commentlock selectionlock; do
    out=$(LOCK_ENV="HYDE_LOCKSCREEN=$name" run --select)
    status=$?
    [ "$status" -ne 0 ] || fail "--select with $name.sh exited 0"
    grep -q "^$name.sh" "$log" && fail "--select started $name.sh, which declares no --select: $(cat "$log")"
    case "$out" in *"no layout selector for lockscreen '$name'"*) ;; *) fail "--select with $name.sh gave no explanation: $out" ;; esac
    never_locked "--select with $name.sh"
done

# --- a lockscreen command with arguments has no wrapper by that name ---
out=$(LOCK_ENV="HYDE_LOCKSCREEN=swaylock -f" run --select)
[ $? -ne 0 ] || fail "--select with a lockscreen command with arguments exited 0"
case "$out" in *"lockscreen 'swaylock -f'"*) ;; *) fail "a lockscreen command with arguments was not reported: $out" ;; esac
never_locked "--select with a lockscreen command with arguments"

# --- --get and --select together: whichever wins, no lock is started ---
for combo in "--get --select" "--select --get"; do
    # shellcheck disable=SC2086
    out=$(run $combo)
    [ "$out" = "hyprlock" ] || grep -qx 'hyprlock.sh --select' "$log" ||
        fail "$combo neither printed the lockscreen nor ran its selector: $out $(cat "$log")"
    never_locked "$combo"
done

# --- unchanged behaviour: --get prints, a plain call and unknown flags lock ---
out=$(LOCK_ENV="HYDE_LOCKSCREEN=gtklock" run --get)
[ "$out" = "gtklock" ] || fail "--get printed '$out' instead of the lockscreen"
[ -s "$log" ] && fail "--get ran something: $(cat "$log")"

run >/dev/null
grep -q '^app.sh .*hyprlock.sh$' "$log" || fail "a plain call did not launch hyprlock.sh through app.sh: $(cat "$log")"

run --immediate >/dev/null
grep -q '^app.sh .*hyprlock.sh --immediate$' "$log" ||
    fail "an unknown flag was not passed on to the lockscreen: $(cat "$log")"

printf '    lockscreen --select checked\n'

finish
