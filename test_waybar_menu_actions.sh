#!/usr/bin/env bash
# Waybar maps a clicked menu item to a command by looking up the item's `id`
# from the menu's GtkBuilder XML in the module's "menu-actions". An id with no
# matching key does nothing -- no error, no log line -- so a renamed id or key
# silently breaks the entry: "Previous Layout" (`waybar-layout-prev` vs
# `waybar-layout-previous`), dunst "Close" (`close` vs `close-all`) and the
# custom/clipboard "Delete" entry (`delete-history` vs `delete`).
#
# Every clickable menu item (one that doesn't just open a submenu) must have an
# action in every module that uses that menu. The checker itself is run
# against small fixture trees first: a mismatched id, a submenu parent, `//`
# inside a JSON string, a malformed module file, a missing menu file and a
# module without a menu-file, so it can't pass by skipping what it can't read.

. "$(dirname -- "$0")/lib/common.sh"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 is not installed"
    finish
}

check() {
    python3 - "$1" <<'EOF'
import json, os, re, sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
waybar = os.path.join(root, "Configs/.local/share/waybar")
menus = os.path.join(waybar, "menus")
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
            if not isinstance(conf, dict) or "menu-actions" not in conf:
                continue
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
            for missing in sorted(ids - set(conf["menu-actions"])):
                problems.append(f"{rel} [{module}]: menu item '{missing}' has no action")

print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
}

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

# Builds a fixture tree: $1 = module jsonc content, $2 = menu xml content
# (empty = no menu file at all).
fixture() {
    rm -rf "${fixture_root:?}/Configs"
    local w="$fixture_root/Configs/.local/share/waybar"
    mkdir -p "$w/modules" "$w/menus"
    printf '%s\n' "$1" >"$w/modules/custom-test.jsonc"
    [ -n "$2" ] && printf '%s\n' "$2" >"$w/menus/test.xml"
    return 0
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
# and a // inside a string is not taken for a comment ---
fixture '{ "custom/test": { // a comment
  "menu-file": "$XDG_DATA_HOME/waybar/menus/test.xml",
  "menu-actions": { "go-previous": "xdg-open https://example.org", },
} }' "$menu_xml"
out=$(check "$fixture_root") || fail "a matching menu was reported: $out"

# --- the shape of the original bug: id and action key differ ---
fixture '{ "custom/test": {
  "menu-file": "test.xml",
  "menu-actions": { "go-prev": "true" }
} }' "$menu_xml"
out=$(check "$fixture_root") && fail "a menu item without an action was not reported"
case "$out" in
*"'go-previous' has no action"*) ;;
*) fail "the mismatched id was not named: $out" ;;
esac

# --- a module file it can't parse fails instead of being skipped ---
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": { ' "$menu_xml"
out=$(check "$fixture_root") && fail "a malformed module file passed"
case "$out" in *"cannot parse"*) ;; *) fail "a malformed module file was not reported: $out" ;; esac

# --- a menu-file that doesn't exist, or none at all ---
fixture '{ "custom/test": { "menu-file": "missing.xml", "menu-actions": { "a": "true" } } }' ""
out=$(check "$fixture_root") && fail "a missing menu file passed"
case "$out" in *"not found"*) ;; *) fail "a missing menu file was not reported: $out" ;; esac

fixture '{ "custom/test": { "menu-actions": { "a": "true" } } }' ""
out=$(check "$fixture_root") && fail "menu-actions without a menu-file passed"
case "$out" in *"without a menu-file"*) ;; *) fail "a missing menu-file key was not reported: $out" ;; esac

# --- an empty menu-actions against a real menu reports every item ---
fixture '{ "custom/test": { "menu-file": "test.xml", "menu-actions": {} } }' "$menu_xml"
out=$(check "$fixture_root") && fail "an empty menu-actions passed"

# --- the shipped menus and modules ---
out=$(check "$REPO_ROOT") || fail "menu items without an action:
$out"

printf '    waybar menu item ids checked against menu-actions\n'

finish
