#!/usr/bin/env bash
##
# theme.switch.sh reads theme variables as data.
#
# load_hypr_variables used to eval hyq's `--export env` output, which does not
# escape $(...), backticks or quotes, so a downloaded theme's hypr.theme could
# run commands when the theme was applied (CWE-78). The function is extracted
# from the script and executed for real, in the order the script calls it: the
# theme first, then the state hyprland.conf on top.
##

. "$(dirname -- "$0")/lib/common.sh"

command -v hyq >/dev/null 2>&1 || {
    skip "hyq is not installed"
    finish
}

theme_switch="$REPO_ROOT/Configs/.local/lib/hyde/theme.switch.sh"
[ -f "$theme_switch" ] || {
    fail "missing ${theme_switch#"$REPO_ROOT"/}"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

sed -n '/^load_hypr_variables() {/,/^}/p' "$theme_switch" >"$work_dir/fn.sh"
[ -s "$work_dir/fn.sh" ] || {
    fail "load_hypr_variables not found in theme.switch.sh"
    finish
}

##
# Loads a theme file and then a state file the way theme.switch.sh does.
#
# Arguments:
#   $1  contents of hypr.theme, "-" for no such file
#   $2  contents of the state hyprland.conf, "-" for no such file
#   $3  variable to print
##
resolved() {
    local theme="$work_dir/hypr.theme" state="$work_dir/hyprland.conf"
    rm -f "$theme" "$state"
    [ "$1" = "-" ] || printf '%s\n' "$1" >"$theme"
    [ "$2" = "-" ] || printf '%s\n' "$2" >"$state"
    bash -c ". '$work_dir/fn.sh'
        load_hypr_variables '$theme'
        load_hypr_variables '$state'
        printf '%s' \"\${$3}\"" 2>/dev/null
}

expect() {
    [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

expect "Tela" "$(resolved '$ICON_THEME = Tela' - ICON_THEME)" \
    "a theme value is read"
expect "24" "$(resolved '$CURSOR_SIZE = 24' - CURSOR_SIZE)" \
    "an integer value is read"
expect "Mine" "$(resolved '$GTK_THEME = Theirs' '$GTK_THEME = Mine' GTK_THEME)" \
    "the state file overrides the theme"
expect "Theirs" "$(resolved '$GTK_THEME = Theirs' '$FONT = X' GTK_THEME)" \
    "a state file that does not define the variable keeps the theme's value"
expect "" "$(resolved - - GTK_THEME)" \
    "no theme and no state file leave the variable empty"
expect "" "$(resolved '' '' GTK_THEME)" \
    "empty files leave the variable empty"
expect "" "$(resolved 'garbage {{{ not a config' - GTK_THEME)" \
    "a malformed theme leaves the variable empty"
expect "" "$(resolved '$GTK_THEME =' - GTK_THEME)" \
    "an empty value leaves the variable empty"
expect "" "$(resolved '$FONT_STYLE = Bold' '$FONT = X' FONT_STYLE)" \
    "FONT_STYLE is not inherited from the theme"

marker="$work_dir/injected"
payload='a$(touch '"$marker"')b`touch '"$marker"'`c"; touch '"$marker"'; "'
rm -f "$marker"
got=$(resolved "\$GTK_THEME = $payload" - GTK_THEME)
[ -e "$marker" ] && fail "a command in a theme value was executed"
expect "a\$(touch $marker)b\`touch $marker\`c\"; touch $marker; \"" "$got" \
    "a theme value with shell syntax is kept literally"
rm -f "$marker"
got=$(resolved - "\$GTK_THEME = $payload" GTK_THEME)
[ -e "$marker" ] && fail "a command in a state value was executed"
expect "a\$(touch $marker)b\`touch $marker\`c\"; touch $marker; \"" "$got" \
    "a state value with shell syntax is kept literally"

# Sizes are spliced into sed commands and config files, so only plain integers
# may pass; a value with a newline or shell/sed syntax counts as not set.
for bad in '1, os.execute("x")' '-5' '2.5' 'abc' '12 13' '1/e touch x'; do
    expect "" "$(resolved "\$CURSOR_SIZE = $bad" - CURSOR_SIZE)" \
        "a non-integer size '$bad' is treated as not set"
done
expect "20" "$(resolved '$CURSOR_SIZE = 20' '$CURSOR_SIZE = 9x' CURSOR_SIZE)" \
    "an invalid state size keeps the theme's size"

finish
