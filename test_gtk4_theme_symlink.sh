#!/usr/bin/env bash
##
# confDir/gtk-4.0 used to be a whole-directory symlink into the theme, so any
# tool that wrote ~/.config/gtk-4.0/settings.ini (nwg-look, kde-gtk-config,
# ...) wrote into the theme's own copy instead of the user's. GTK 4 then read
# that back as the theme's settings.ini, and a stray
# gtk-application-prefer-dark-theme key there put some GTK 4 apps into an
# endless reload loop (HyDE-Project/HyDE#2200, upstream GNOME/gtk#8478).
#
# link_gtk4_theme() is extracted from theme.switch.sh and run for real
# against a private directory tree, the way test_theme_switch_hypr_vars.sh
# runs load_hypr_variables.
##

# shellcheck source=tests/lib/common.sh
. "$(dirname -- "$0")/lib/common.sh"

theme_switch="$REPO_ROOT/Configs/.local/lib/hyde/theme.switch.sh"
[ -f "$theme_switch" ] || {
    fail "missing ${theme_switch#"$REPO_ROOT"/}"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

sed -n '/^link_gtk4_theme() {/,/^}/p' "$theme_switch" >"$work_dir/fn.sh"
[ -s "$work_dir/fn.sh" ] || {
    fail "link_gtk4_theme not found in theme.switch.sh"
    finish
}

expect() {
    [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

conf_gtk4="$work_dir/conf-gtk-4.0"
theme_gtk4="$work_dir/theme-gtk-4.0"
old_gtk4="$work_dir/old-gtk-4.0"

##
# Clears the fixture paths before each case. Nothing under work_dir survives
# between cases, so one case's leftovers can never satisfy another's checks.
##
reset_fixture() {
    rm -rf "$conf_gtk4" "$theme_gtk4" "$old_gtk4"
}

##
# Runs link_gtk4_theme against $conf_gtk4/$theme_gtk4 and prints its exit
# status, so a case can assert the call itself never fails even when there is
# nothing useful for it to do (a missing theme, a dangling symlink, ...).
##
run_link() {
    bash -c ". '$work_dir/fn.sh'; link_gtk4_theme '$conf_gtk4' '$theme_gtk4'; echo \$?"
}

# --- fresh install: no prior conf/gtk-4.0, theme ships two files ---
reset_fixture
mkdir -p "$theme_gtk4"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
printf 'theme gtk-dark.css\n' >"$theme_gtk4/gtk-dark.css"
expect "0" "$(run_link)" "a fresh install exits 0"
[ -d "$conf_gtk4" ] && [ ! -L "$conf_gtk4" ] || fail "fresh install: conf/gtk-4.0 is not a real directory"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "fresh install: gtk.css is symlinked to the theme's file"
expect "$theme_gtk4/gtk-dark.css" "$(readlink -- "$conf_gtk4/gtk-dark.css")" \
    "fresh install: gtk-dark.css is symlinked to the theme's file"
[ -e "$conf_gtk4/settings.ini" ] && fail "fresh install: a settings.ini appeared out of nowhere"

# --- migrating off the old whole-directory symlink keeps a real settings.ini ---
reset_fixture
mkdir -p "$old_gtk4" "$theme_gtk4"
printf '[Settings]\ngtk-application-prefer-dark-theme=true\n' >"$old_gtk4/settings.ini"
printf 'old gtk.css\n' >"$old_gtk4/gtk.css"
ln -s "$old_gtk4" "$conf_gtk4"
printf 'new gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
[ -L "$conf_gtk4" ] && fail "migration: conf/gtk-4.0 is still the old whole-directory symlink"
[ -d "$conf_gtk4" ] || fail "migration: conf/gtk-4.0 is not a directory after migrating"
if [ -f "$conf_gtk4/settings.ini" ] && [ ! -L "$conf_gtk4/settings.ini" ]; then
    expect "[Settings]
gtk-application-prefer-dark-theme=true" "$(cat -- "$conf_gtk4/settings.ini")" \
        "migration: settings.ini keeps the content a tool wrote into the old symlink target"
else
    fail "migration: settings.ini is missing or still a symlink after migrating"
fi
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "migration: gtk.css now points at the new theme, not the old one"

# --- a theme's own settings.ini is never linked in, migration or not ---
reset_fixture
mkdir -p "$theme_gtk4"
printf '[Settings]\ngtk-application-prefer-dark-theme=true\n' >"$theme_gtk4/settings.ini"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
[ -e "$conf_gtk4/settings.ini" ] && fail "a theme-provided settings.ini was linked into conf/gtk-4.0"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "the theme's other files are still linked when its settings.ini is skipped"

# --- switching to a theme that drops a file removes the stale symlink ---
reset_fixture
mkdir -p "$conf_gtk4" "$old_gtk4/assets" "$theme_gtk4"
ln -s "$old_gtk4/assets" "$conf_gtk4/assets"
printf 'new gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
[ -e "$conf_gtk4/assets" ] && fail "a symlink the new theme does not provide was left behind"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "the new theme's file is linked after dropping the stale one"

# --- a missing theme directory never touches an existing real settings.ini ---
reset_fixture
mkdir -p "$conf_gtk4"
printf 'user prefs\n' >"$conf_gtk4/settings.ini"
rm -rf "$theme_gtk4"
expect "0" "$(run_link)" "a missing theme directory still exits 0"
expect "user prefs" "$(cat -- "$conf_gtk4/settings.ini")" \
    "a missing theme directory leaves an existing settings.ini untouched"

# --- settings.ini survives a normal (non-migrating) relink ---
reset_fixture
mkdir -p "$conf_gtk4" "$theme_gtk4"
printf 'user prefs\n' >"$conf_gtk4/settings.ini"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
expect "user prefs" "$(cat -- "$conf_gtk4/settings.ini")" \
    "settings.ini is unchanged when the theme is relinked, not migrated"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "gtk.css is linked alongside the untouched settings.ini"

# --- a dangling old symlink does not crash the migration ---
reset_fixture
mkdir -p "$theme_gtk4"
ln -s "$work_dir/does-not-exist" "$conf_gtk4"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
expect "0" "$(run_link)" "a dangling old symlink still exits 0"
[ -d "$conf_gtk4" ] && [ ! -L "$conf_gtk4" ] || fail "a dangling old symlink left conf/gtk-4.0 broken"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "the theme is linked after recovering from a dangling symlink"

# --- a settings.ini that is itself a symlink is never "migrated" as real content ---
reset_fixture
mkdir -p "$old_gtk4" "$theme_gtk4"
printf 'not the real file\n' >"$work_dir/elsewhere.ini"
ln -s "$work_dir/elsewhere.ini" "$old_gtk4/settings.ini"
ln -s "$old_gtk4" "$conf_gtk4"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
[ -e "$conf_gtk4/settings.ini" ] && fail "a symlinked settings.ini was migrated as if it were real content"

# --- a theme's subdirectory (assets/) is linked as one entry, reachable through it ---
reset_fixture
mkdir -p "$theme_gtk4/assets"
printf 'icon\n' >"$theme_gtk4/assets/icon.svg"
run_link >/dev/null
[ -L "$conf_gtk4/assets" ] || fail "assets/ was not linked as a symlinked directory"
expect "icon" "$(cat -- "$conf_gtk4/assets/icon.svg" 2>/dev/null)" \
    "a file inside the linked assets/ directory is reachable"

# --- a failed migration leaves the old symlink and the real file untouched ---
if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: a permission failure cannot be simulated"
else
    reset_fixture
    mkdir -p "$old_gtk4" "$theme_gtk4"
    printf 'precious prefs\n' >"$old_gtk4/settings.ini"
    chmod 000 "$old_gtk4/settings.ini"
    printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
    ln -s "$old_gtk4" "$conf_gtk4"
    expect "1" "$(run_link 2>/dev/null)" \
        "a migration that cannot read settings.ini fails instead of silently dropping it"
    [ -L "$conf_gtk4" ] || fail "a failed migration replaced the old symlink anyway"
    expect "$old_gtk4" "$(readlink -- "$conf_gtk4")" \
        "a failed migration leaves the old symlink pointing at the original directory"
    chmod 600 "$old_gtk4/settings.ini"
    expect "precious prefs" "$(cat -- "$old_gtk4/settings.ini")" \
        "a failed migration leaves the original settings.ini content intact"
    stray=$(find "$work_dir" -maxdepth 1 -name "$(basename -- "$conf_gtk4").settings.ini.*" 2>/dev/null)
    [ -z "$stray" ] || fail "a failed migration left a stray staged temp file: $stray"
fi

# --- a theme whose gtk-4.0 directory is itself a symlink is still followed ---
reset_fixture
real_theme_gtk4="$work_dir/theme-gtk-4.0-real"
rm -rf "$real_theme_gtk4"
mkdir -p "$real_theme_gtk4"
printf 'theme gtk.css\n' >"$real_theme_gtk4/gtk.css"
ln -s "$real_theme_gtk4" "$theme_gtk4"
expect "0" "$(run_link)" "a symlinked theme gtk-4.0 directory still exits 0"
expect "$theme_gtk4/gtk.css" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "a theme whose gtk-4.0 directory is itself a symlink is still followed and linked"
expect "theme gtk.css" "$(cat -- "$conf_gtk4/gtk.css" 2>/dev/null)" \
    "the file reached through the symlinked theme directory has the real content"

# --- running twice in a row is stable ---
reset_fixture
mkdir -p "$theme_gtk4"
printf 'theme gtk.css\n' >"$theme_gtk4/gtk.css"
run_link >/dev/null
first_target=$(readlink -- "$conf_gtk4/gtk.css")
expect "0" "$(run_link)" "running link_gtk4_theme again on the same theme exits 0"
expect "$first_target" "$(readlink -- "$conf_gtk4/gtk.css")" \
    "running link_gtk4_theme again on the same theme leaves gtk.css pointing at the same place"

finish
