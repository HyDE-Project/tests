#!/usr/bin/env bash
##
# User [hyprland] overrides in the wallbash Lua ui state.
#
# color/hypr.sh writes the ui state that color/dconf.lua copies into gsettings,
# which is where GTK3 apps (Firefox, blueman) read their theme from. It has to
# honour the override in the state hyprland.conf the same way theme.switch.sh
# does, otherwise the override only reaches the GTK4 symlink, see HyDE#2132.
# The script is executed for real against a private home.
##

. "$(dirname -- "$0")/lib/common.sh"

command -v hyq >/dev/null 2>&1 || {
    skip "hyq is not installed"
    finish
}

color_hypr="$REPO_ROOT/Configs/.local/lib/hyde/color/hypr.sh"
global_control="$REPO_ROOT/Configs/.local/lib/hyde/globalcontrol.sh"
[ -f "$color_hypr" ] || {
    fail "missing ${color_hypr#"$REPO_ROOT"/}"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

##
# Runs color/hypr.sh in a private home and prints one field of the ui state.
#
# Arguments:
#   $1  contents of the state hyprland.conf, "-" for no such file
#   $2  field to print from the generated ui.lua
#   $3  contents of the theme's hypr.theme
# Outputs:
#   The field's value, empty when it is not written
##
ui_field() {
    local home
    home=$(mktemp -d "$work_dir/home.XXXXXX")
    mkdir -p "$home/.local/state/hyde/lua_state" "$home/.config/hyde/themes/T"
    printf '%s\n' "$3" >"$home/.config/hyde/themes/T/hypr.theme"
    [ "$1" = "-" ] || printf '%s\n' "$1" >"$home/.local/state/hyde/hyprland.conf"
    env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
        XDG_STATE_HOME="$home/.local/state" PATH="/usr/bin:/bin" \
        HYDE_SHELL_INIT=1 HYDE_THEME=T \
        bash -c ". '$global_control' >/dev/null 2>&1; . '$color_hypr'" >/dev/null 2>&1
    sed -n "s/^ *$2 = \(.*\),\$/\1/p" "$home/.local/state/hyde/lua_state/ui.lua" |
        sed 's/^"\(.*\)"$/\1/'
}

expect() {
    [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

theme='$GTK_THEME = WhiteSur-Dark
$ICON_THEME = Tela'

expect "WhiteSur-Dark" "$(ui_field - gtk_theme "$theme")" \
    "no state file keeps the theme's GTK theme"
expect "Wallbash-Gtk" "$(ui_field '$GTK_THEME = Wallbash-Gtk' gtk_theme "$theme")" \
    "the state override wins over the theme"
expect "30" "$(ui_field '$CURSOR_SIZE = 30' cursor_size "$theme")" \
    "an integer override reaches the ui state"
expect "24" "$(ui_field - cursor_size '$CURSOR_SIZE = 24')" \
    "an integer theme value reaches the ui state"
expect "Tela" "$(ui_field '$GTK_THEME = Wallbash-Gtk' icon_theme "$theme")" \
    "a variable the state does not define keeps the theme's value"
expect "WhiteSur-Dark" "$(ui_field '$GTK_THEME =' gtk_theme "$theme")" \
    "an empty override does not blank the theme's value"
expect "WhiteSur-Dark" "$(ui_field '' gtk_theme "$theme")" \
    "an empty state file keeps the theme's value"
expect "WhiteSur-Dark" "$(ui_field 'garbage {{{ not a config' gtk_theme "$theme")" \
    "a malformed state file keeps the theme's value"
expect "Wallbash-Gtk" "$(ui_field '$GTK_THEME = Wallbash-Gtk' gtk_theme '')" \
    "an override applies to a theme that defines nothing"
expect 'My "Quoted" Theme' "$(ui_field '$GTK_THEME = My "Quoted" Theme' gtk_theme "$theme" | sed 's/\\"/"/g')" \
    "an override containing quotes is written as a valid Lua string"
expect "Second" "$(ui_field '$GTK_THEME = First
$GTK_THEME = Second' gtk_theme "$theme")" \
    "a repeated override resolves like theme.switch.sh (last one wins)"

# Values are data, never shell code: hyq does not escape $(...), backticks or
# quotes, so an eval of its output ran them (CWE-78). Covers a downloaded
# theme's hypr.theme and the config.toml override alike.
marker="$work_dir/injected"
payload='a$(touch '"$marker"')b`touch '"$marker"'`c"; touch '"$marker"'; "'
rm -f "$marker"
got=$(ui_field "\$GTK_THEME = $payload" gtk_theme "$theme")
[ -e "$marker" ] && fail "a command in a state file value was executed"
expect "a\$(touch $marker)b\`touch $marker\`c\\\"; touch $marker; \\\"" "$got" \
    "a state file value with shell syntax is kept literally"
rm -f "$marker"
got=$(ui_field - gtk_theme "\$GTK_THEME = $payload")
[ -e "$marker" ] && fail "a command in a theme file value was executed"
expect "a\$(touch $marker)b\`touch $marker\`c\\\"; touch $marker; \\\"" "$got" \
    "a theme file value with shell syntax is kept literally"

# Sizes are written unquoted into the Lua state, so only plain integers may
# pass; anything else would end up in ui.lua as code.
for bad in '1, os.execute("x")' '-5' '2.5' 'abc' '12 13'; do
    expect "20" "$(ui_field "\$CURSOR_SIZE = $bad" cursor_size '$CURSOR_SIZE = 20')" \
        "a non-integer size override '$bad' keeps the theme's size"
done
expect "nil" "$(ui_field - cursor_size '$CURSOR_SIZE = 1, os.execute("x")')" \
    "a non-integer theme size is dropped"

finish
