#!/usr/bin/env bash
# Waybar runs click/scroll/menu commands through `sh -c` and never reports
# when one does nothing, so a broken action only shows up as "clicking it
# does nothing". This checks every command the shipped Waybar modules and
# layouts run, for the ways they were actually broken:
#
# - a menu item id with no matching "menu-actions" key ("Previous Layout":
#   `waybar-layout-prev` vs `waybar-layout-previous`, dunst "Close",
#   custom/clipboard "Delete", and the macOS preset's stale action list)
# - shell syntax errors (custom/cava's on-click had an unclosed quote)
# - a redirect to a numbered file, `1>2` for `>&2` (custom/swaync's exec-if
#   wrote into a file called "2" and passed /dev/null as a command)
# - `hyde-shell app` without `--` (runs nothing without systemd)
# - a hyde-shell subcommand that doesn't resolve to a script
# - a positional argument to a script using shutils/argparse.sh, which
#   ignores it (custom/cliphist "Manage Favorites" opened the main menu)
# - wallpaper changes without --global, which skip the theme cache and
#   wallbash colours that the keybinds and the HyDE menu apply
# - global wallpaper and theme changes run straight from Waybar: they end in a
#   reload that signals Waybar's whole cgroup and kills them midway (#2024),
#   so they have to go through `hyde-shell app -t scope --`
#
# The checker runs against fixture trees first -- a passing case and one per
# rule, plus malformed input -- so it can't pass by skipping what it can't read.

. "$(dirname -- "$0")/lib/common.sh"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 is not installed"
    finish
}

check() {
    python3 - "$1" <<'EOF'
import json, os, re, shlex, subprocess, sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
waybar = os.path.join(root, "Configs/.local/share/waybar")
menus = os.path.join(waybar, "menus")
lib = os.path.join(root, "Configs/.local/lib/hyde")
bindir = os.path.join(root, "Configs/.local/bin")
# Handled inside hyde-shell itself rather than by a script.
BUILTINS = {"app", "logout", "pypr", "uv", "luarocks", "wallbash", "help", "man",
            "reload", "init", "luainit", "pyinit", "completions", "--help", "-h"}
problems = []

def load_jsonc(path):
    text = open(path, encoding="utf-8").read()
    # Drop comments outside strings only: values such as "https://..." hold //.
    text = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/',
                  lambda m: m.group(1) or "", text, flags=re.S)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)

def leaf_ids(path):
    ids = set()
    for obj in ET.parse(path).iter("object"):
        if obj.get("class") != "GtkMenuItem" or not obj.get("id"):
            continue
        # GtkBuilder accepts both spellings for an item that opens a submenu.
        if any(p.get("name") == "submenu" for p in obj.findall("property")) or \
                any(c.get("type") == "submenu" for c in obj.findall("child")):
            continue
        ids.add(obj.get("id"))
    return ids

def resolve(name):
    """The script hyde-shell runs for name, or None."""
    for d in (lib, bindir):
        for ext in (".lua", ".sh", ".py"):
            if os.path.isfile(os.path.join(d, name + ext)):
                return os.path.join(d, name + ext)
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None

def check_command(where, cmd):
    if subprocess.run(["sh", "-n", "-c", cmd], capture_output=True).returncode != 0:
        problems.append(f"{where}: shell syntax error: {cmd}")
        return
    if re.search(r"(^|\s)\d*>\s*\d+(\s|;|$)", cmd):
        problems.append(f"{where}: redirects into a numbered file (meant >&N?): {cmd}")
    for part in re.split(r"&&|\|\||;|\|", cmd):
        try:
            words = shlex.split(part)
        except ValueError:
            continue
        if len(words) < 2 or words[0] != "hyde-shell":
            continue
        args = words[1:]
        scoped = False
        if args[0] == "app":
            if "--" not in args:
                problems.append(f"{where}: `hyde-shell app` without `--`: {cmd}")
                continue
            pre = args[1:args.index("--")]
            scoped = any(pre[i] == "-t" and i + 1 < len(pre) and pre[i + 1] in ("scope", "service")
                         for i in range(len(pre)))
            args = args[args.index("--") + 1:]
            if not args:
                problems.append(f"{where}: `hyde-shell app --` with no command: {cmd}")
                continue
        name, rest = args[0], args[1:]
        if name in BUILTINS:
            continue
        script = resolve(name)
        if not script:
            problems.append(f"{where}: hyde-shell {name}: no such script")
            continue
        base = os.path.basename(script)
        is_global = any(a == "--global" or re.fullmatch(r"-[A-Za-z]*G[A-Za-z]*", a) for a in rest)
        read_only = any(a in ("-g", "--get", "-j", "--json", "-h", "--help") for a in rest)
        if base.startswith("wallpaper.") and rest and not is_global and not read_only:
            problems.append(f"{where}: wallpaper change without --global: {cmd}")
        # A global wallpaper or theme change rewrites the colours, and HyDE's
        # reload hook then sends SIGUSR2 to every process in Waybar's cgroup
        # (systemctl kill on the unit), killing the change midway unless it
        # runs in its own unit (#2024).
        changes_theme = base in ("theme.switch.sh", "theme.select.sh") or \
            (base.startswith("wallpaper.") and is_global)
        if changes_theme and not scoped:
            problems.append(f"{where}: {base} runs inside Waybar's cgroup; "
                            f"start it through `hyde-shell app -t scope --`: {cmd}")
        try:
            uses_argparse = "shutils/argparse.sh" in open(script, encoding="utf-8").read()
        except UnicodeDecodeError:
            uses_argparse = False
        if uses_argparse and rest and not rest[0].startswith("-"):
            problems.append(f"{where}: positional argument '{rest[0]}' is ignored by {base}: {cmd}")

ACTION_KEY = re.compile(r"^(on-(click|scroll)[a-z-]*|exec|exec-if)$")

for dirpath, _, files in sorted(os.walk(waybar)):
    for name in sorted(files):
        if not name.endswith((".json", ".jsonc")):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        try:
            data = load_jsonc(path)
        except (ValueError, UnicodeDecodeError) as e:
            problems.append(f"{rel}: cannot parse ({e})")
            continue
        if not isinstance(data, dict):
            continue
        for module, conf in data.items():
            if not isinstance(conf, dict):
                continue
            # Only custom modules run these as shell commands; built-in modules
            # use some of the same keys for internal action names.
            if module.startswith("custom/") or module.startswith("hyprland/workspaces"):
                for key, value in conf.items():
                    if ACTION_KEY.match(key) and isinstance(value, str) and value.strip():
                        check_command(f"{rel} [{module}] {key}", value)
            if "menu-actions" not in conf:
                continue
            actions = conf["menu-actions"]
            for key, value in actions.items():
                if isinstance(value, str):
                    check_command(f"{rel} [{module}] menu-actions.{key}", value)
            menu_file = conf.get("menu-file")
            if not menu_file:
                problems.append(f"{rel} [{module}]: menu-actions without a menu-file")
                continue
            xml = os.path.join(menus, os.path.basename(menu_file))
            if not os.path.isfile(xml):
                problems.append(f"{rel} [{module}]: menu file {os.path.basename(menu_file)} not found")
                continue
            try:
                ids = leaf_ids(xml)
            except ET.ParseError as e:
                problems.append(f"{os.path.relpath(xml, root)}: cannot parse ({e})")
                continue
            for missing in sorted(ids - set(actions)):
                problems.append(f"{rel} [{module}]: menu item '{missing}' has no action")

print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
}

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
fx_lib="$fixture_root/Configs/.local/lib/hyde"

# Builds a fixture tree: $1 = module jsonc content, $2 = menu xml content
# (empty = no menu file at all). A few stub scripts stand in for the real ones.
fixture() {
    rm -rf "${fixture_root:?}/Configs"
    local w="$fixture_root/Configs/.local/share/waybar"
    mkdir -p "$w/modules" "$w/menus" "$fx_lib"
    printf '%s\n' "$1" >"$w/modules/custom-test.jsonc"
    [ -n "$2" ] && printf '%s\n' "$2" >"$w/menus/test.xml"
    printf '#!/bin/sh\n' >"$fx_lib/plain.sh"
    printf '#!/bin/sh\n. "${LIB_DIR}/hyde/shutils/argparse.sh"\n' >"$fx_lib/parsed.sh"
    printf '#!/bin/sh\n' >"$fx_lib/wallpaper.sh"
    printf '#!/bin/sh\n' >"$fx_lib/theme.switch.sh"
    printf '#!/bin/sh\n' >"$fx_lib/theme.select.sh"
    chmod +x "$fx_lib/wallpaper.sh" "$fx_lib/theme.switch.sh" "$fx_lib/theme.select.sh"
    printf '#!/bin/sh\n' >"$fx_lib/tool.sh"
    chmod +x "$fx_lib/tool.sh"
    return 0
}

# $1 = one command as a JSON string value; wraps it in an on-click.
cmd_fixture() {
    fixture "{ \"custom/test\": { \"on-click\": $1 } }" ""
}

expect_ok() {
    local out
    out=$(check "$fixture_root") || fail "$1 was reported: $out"
}

expect_problem() {
    local out
    out=$(check "$fixture_root") && fail "$1 passed"
    case "$out" in *"$2"*) ;; *) fail "$1 was not reported as '$2': $out" ;; esac
}

menu_xml='<interface><object class="GtkMenu" id="menu">
  <child><object class="GtkMenuItem" id="parent">
    <property name="submenu"><object class="GtkMenu" id="sub">
      <child><object class="GtkMenuItem" id="go-previous"/></child>
    </object></property>
  </object></child>
  <child><object class="GtkMenuItem" id="parent2">
    <child type="submenu"><object class="GtkMenu" id="sub2"/></child>
  </object></child>
  <child><object class="GtkSeparatorMenuItem" id="sep"/></child>
</object></interface>'

# --- a matching setup passes: submenu parents and separators need no action,
# a // inside a string is not a comment, and valid commands of each shape
# (2>&1, app with --, an executable script by filename, -G combined flags) ---
fixture '{ "custom/test": { // a comment
  "exec-if": "hyde-shell plain --x >/dev/null 2>&1",
  "on-click": "hyde-shell app -t scope -- tool.sh --y",
  "on-click-right": "hyde-shell app -t scope -- wallpaper.sh -Gn",
  "on-click-middle": "hyde-shell wallpaper --get",
  "on-scroll-up": "hyde-shell parsed --flag; pkill -RTMIN+1 waybar",
  "menu-file": "$XDG_DATA_HOME/waybar/menus/test.xml",
  "menu-actions": { "go-previous": "xdg-open https://example.org", },
} }' "$menu_xml"
expect_ok "a valid module"

# --- menu item id and action key differ (the "Previous Layout" bug) ---
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": { "go-prev": "true" } } }' "$menu_xml"
expect_problem "a menu item without an action" "'go-previous' has no action"

# --- an empty menu-actions against a real menu reports its items ---
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": {} } }' "$menu_xml"
expect_problem "an empty menu-actions" "has no action"

# --- a menu-file that doesn't exist, or none at all ---
fixture '{ "custom/test": { "menu-file": "missing.xml", "menu-actions": { "a": "true" } } }' ""
expect_problem "a missing menu file" "not found"
fixture '{ "custom/test": { "menu-actions": { "a": "true" } } }' ""
expect_problem "menu-actions without a menu-file" "without a menu-file"

# --- a module file or menu it can't parse fails instead of being skipped ---
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": { ' "$menu_xml"
expect_problem "a malformed module file" "cannot parse"
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": { "a": "true" } } }' '<interface><object'
expect_problem "a malformed menu file" "cannot parse"

# --- commands ---
cmd_fixture "\"pkill -f 'cava.py waybar\""
expect_problem "an unclosed quote" "shell syntax error"
cmd_fixture '"swaync-client --count 1>2 /dev/null"'
expect_problem "a redirect into a numbered file" "numbered file"
cmd_fixture '"hyde-shell app -t scope tool.sh --use x"'
expect_problem "hyde-shell app without --" "without \`--\`"
cmd_fixture '"hyde-shell app -t scope --"'
expect_problem "hyde-shell app -- with nothing after it" "no command"
cmd_fixture '"hyde-shell does-not-exist --x"'
expect_problem "an unknown hyde-shell subcommand" "no such script"
cmd_fixture "\"hyde-shell parsed 'Manage Favorites'\""
expect_problem "a positional argument to an argparse.sh script" "is ignored by parsed.sh"
cmd_fixture '"hyde-shell wallpaper -n"'
expect_problem "a wallpaper change without --global" "without --global"
cmd_fixture '"sleep 0.1 && hyde-shell wallpaper --select"'
expect_problem "a chained wallpaper change without --global" "without --global"
cmd_fixture '"hyde-shell wallpaper --global -n"'
expect_problem "a global wallpaper change run directly from Waybar" "runs inside Waybar's cgroup"
cmd_fixture '"hyde-shell app -- wallpaper.sh --global -n"'
expect_problem "a global wallpaper change through app without a unit type" "runs inside Waybar's cgroup"
cmd_fixture '"hyde-shell app -t scope -- theme.switch.sh -n; pkill -RTMIN+19 waybar"'
expect_ok "a scoped theme switch followed by a Waybar refresh"
cmd_fixture '"hyde-shell app -t service -- theme.select.sh"'
expect_ok "a theme selection in its own service"
cmd_fixture '"sleep 0.1 && hyde-shell theme.select.sh"'
expect_problem "a theme selection run directly from Waybar" "theme.select.sh runs inside Waybar's cgroup"
cmd_fixture '"hyde-shell wallpaper --json"'
expect_ok "a read-only wallpaper query"

# --- the shipped modules, layouts and menus ---
out=$(check "$REPO_ROOT") || fail "broken Waybar actions:
$out"

printf '    waybar menu ids and action commands checked\n'

finish
