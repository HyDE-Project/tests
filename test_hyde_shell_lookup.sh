#!/usr/bin/env bash
# Scripts that source hyde-shell locate it with `command -v`, not `which`
# (review on HyDE-Project/HyDE#2120): `which` isn't POSIX, isn't installed
# everywhere, and reports a missing command differently from shell to shell.
#
# Two parts:
# - no shipped file looks hyde-shell up with `which`, in any spelling
#   ($(...), backticks, extra spaces or a tab), while prose or unrelated words
#   don't count; the matcher is checked against fixtures first
# - each script's lookup block really runs: it sources hyde-shell from a PATH
#   that has no `which` at all, takes its error branch (exit 1 with a
#   message, no crash) when hyde-shell is missing or PATH is empty, and still
#   sources a hyde-shell that lacks the exec bit (see below)

. "$(dirname -- "$0")/lib/common.sh"

configs_dir="$REPO_ROOT/Configs"
[ -d "$configs_dir" ] || {
    fail "Configs not found at $configs_dir"
    finish
}

# Word-bounded, any whitespace between the two words.
which_lookup='(^|[^[:alnum:]_-])which[[:space:]]+hyde-shell([^[:alnum:]_.-]|$)'

find_which_lookups() {
    grep -rIlE -- "$which_lookup" "$1" 2>/dev/null || true
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# --- the matcher itself ---
fixture="$work_dir/fixture"
match_case() {
    rm -rf "$fixture"
    mkdir -p "$fixture"
    printf '%s\n' "$2" >"$fixture/script.sh"
    if [ -n "$(find_which_lookups "$fixture")" ]; then got=match; else got=clean; fi
    [ "$got" = "$1" ] || fail "matcher: expected $1 for: $2"
}
match_case match 'if ! source "$(which hyde-shell)"; then'
match_case match 'source `which hyde-shell`'
match_case match 'x=$(which   hyde-shell)'
match_case match "$(printf 'x=$(which\thyde-shell)')"
match_case match 'which hyde-shell'
match_case clean 'if ! source "$(command -v hyde-shell)"; then'
match_case clean 'x=$(type -p hyde-shell)'
match_case clean 'sandwich hyde-shell'
match_case clean 'which hyde-shell-helper'
match_case clean 'which hyde-shellish'
match_case clean ''

# --- the shipped files ---
for hit in $(find_which_lookups "$configs_dir"); do
    fail "${hit#"$REPO_ROOT"/} looks up hyde-shell with which (use command -v)"
done

# --- the lookup blocks, run for real ---
scripts=$(grep -rIl -- 'source "$(command -v hyde-shell)"' "$configs_dir" 2>/dev/null || true)
[ -n "$scripts" ] || fail "no script sources hyde-shell through command -v"

# A PATH with the usual tools but no `which`, so a lookup that still needed it
# would fail here.
tools="$work_dir/tools"
mkdir -p "$tools"
for f in /usr/bin/* /bin/*; do
    name=$(basename "$f")
    [ "$name" = "which" ] && continue
    [ -e "$tools/$name" ] || ln -s "$f" "$tools/$name" 2>/dev/null
done
with_shell="$work_dir/with-shell"
not_exec="$work_dir/not-exec"
mkdir -p "$with_shell" "$not_exec"
printf 'HYDE_SHELL_SOURCED=1\n' >"$with_shell/hyde-shell"
chmod +x "$with_shell/hyde-shell"
printf 'HYDE_SHELL_SOURCED=1\n' >"$not_exec/hyde-shell"
chmod -x "$not_exec/hyde-shell"

# Runs only the script's lookup block (from `if ! source ...` to its `fi`),
# then reports whether hyde-shell got sourced.
run_block() {
    local script=$1 path=$2 block
    block=$(awk '/if ! source "\$\(command -v hyde-shell\)"/ {on=1} on {print} on && /^fi$/ {exit}' "$script")
    [ -n "$block" ] || return 99
    env -i HOME="$work_dir" PATH="$path" /bin/bash -c "$block"'
echo "sourced=${HYDE_SHELL_SOURCED:-0}"' 2>&1
}

for script in $scripts; do
    rel=${script#"$REPO_ROOT"/}

    out=$(run_block "$script" "$with_shell:$tools")
    status=$?
    [ "$status" -ne 99 ] || { fail "$rel: no lookup block found"; continue; }
    [ "$status" -eq 0 ] && case "$out" in *sourced=1*) true ;; *) false ;; esac ||
        fail "$rel: did not source hyde-shell from a PATH without which (status $status): $out"

    # bash's command -v falls back to a non-executable file when no executable
    # one is on PATH (which finds nothing there); sourcing needs no exec bit,
    # so that hyde-shell is used rather than reported missing.
    out=$(run_block "$script" "$not_exec:$tools")
    status=$?
    [ "$status" -eq 0 ] && case "$out" in *sourced=1*) true ;; *) false ;; esac ||
        fail "$rel: a non-executable hyde-shell on PATH was not sourced (status $status): $out"

    for case_name in missing empty-path; do
        case $case_name in missing) path=$tools ;; empty-path) path="" ;; esac
        out=$(run_block "$script" "$path")
        status=$?
        [ "$status" -eq 1 ] || fail "$rel: hyde-shell $case_name exited $status, not 1: $out"
        case "$out" in
        *sourced=1*) fail "$rel: hyde-shell $case_name, yet something was sourced" ;;
        *hyde-shell*) ;;
        *) fail "$rel: hyde-shell $case_name gave no message: $out" ;;
        esac
    done
done

printf '    hyde-shell lookups checked\n'

finish
