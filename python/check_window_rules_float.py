"""File-manager dialogs must float while their main windows tile.

window_rules.lua listed org.kde.dolphin (and org.kde.ark) in the floating
class rule, then ended with a "filemanagers-fullscreen" rule setting
float = false for every dolphin/nemo/nautilus/ark window to undo it. Being the
last match, that rule also won over the title rules meant for Dolphin's
dialogs ("Properties for.*", "Copying — Dolphin", ...), so they tiled
(HyDE-Project/HyDE#2211). The same rule's `opaque = true` must stay on the
file managers' own app ids.

The rules are loaded from the shipped file against a stubbed `hl` and
evaluated like Hyprland does for a static property: every match field must
fully match, and the last matching rule that sets the property wins. These
expectations were checked against a live Hyprland 0.56 session.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LUA_DIR = REPO_ROOT / "Configs/.local/share/hypr/lua"

# Dumps each hl.window_rule call as tab-separated lines:
#   R <name> <float: true|false|nil> <opaque: true|false|nil>
#   M <field> <pattern or boolean>
DUMP = r"""
local lua_dir = os.getenv("HYDE_LUA_DIR")
_G.hl = {
  window_rule = function(rule)
    print(string.format("R\t%s\t%s\t%s", rule.name or "", tostring(rule.float), tostring(rule.opaque)))
    for key, value in pairs(rule.match or {}) do
      print(string.format("M\t%s\t%s", key, tostring(value)))
    end
  end,
}
dofile(lua_dir .. "/hyde/utils.lua")
dofile(lua_dir .. "/window_rules.lua")
"""

# (class, title, expected floating). Every expectation, including the
# boundaries below, was observed on a live Hyprland 0.56 session.
CASES = [
    # #2211: Dolphin's main window tiles, its dialogs float.
    ("org.kde.dolphin", "Home — Dolphin", False),
    ("org.kde.dolphin", "Properties for foo.txt — Dolphin", True),
    ("org.kde.dolphin", "Copying — Dolphin", True),
    ("org.kde.dolphin", "Progress Dialog — Dolphin", True),
    ("org.kde.dolphin", "File Already Exists — Dolphin", True),
    # Title rules are anchored and case-sensitive.
    ("org.kde.dolphin", "Properties for", True),
    ("org.kde.dolphin", "properties for foo.txt — Dolphin", False),
    ("org.kde.dolphin", "XProperties for foo.txt", False),
    ("org.kde.dolphin", "Copying — Dolphin 2", False),
    ("org.kde.dolphin", "X Copying — Dolphin", False),
    ("org.kde.dolphin", "Open", True),
    ("org.kde.dolphin", "Open — Dolphin", False),
    # A file name with non-ASCII or regex metacharacters is plain text.
    ("org.kde.dolphin", "Properties for ü (1).txt — Dolphin", True),
    ("org.kde.dolphin", "Properties for (.*[ — Dolphin", True),
    # Near-miss classes stay tiled.
    ("dolphin", "Home — Dolphin", False),
    ("org.kde.dolphinX", "Home", False),
    ("dolphin-emu", "Dolphin", False),
    # Ark kept its tiled main window when it left floating.class.
    ("org.kde.ark", "Ark", False),
    ("org.kde.ark", "Extract — Ark", False),
    ("org.kde.ark", "Properties for a.zip", True),
    # Other file managers.
    ("nemo", "Home - Nemo", False),
    ("org.gnome.Nautilus", "Home", False),
    ("org.gnome.Nautilus", "Choose Files", True),
    ("pcmanfm-qt", "Home", False),
    # Unrelated floating rules are unaffected.
    ("vlc", "VLC", True),
    ("VLC", "VLC", False),
    ("kitty-x", "Properties for foo.txt — Dolphin", True),
]


# (class, expected opaque): filemanagers-fullscreen must hit the file
# managers' own app ids only. Its old `.*ark.*` / `.*dolphin.*` / `.*nemo.*`
# also made darktable, dolphin-emu, anemone, ... opaque.
OPAQUE_CASES = [
    ("org.kde.dolphin", True),
    ("dolphin", True),
    ("org.kde.ark", True),
    ("ark", True),
    ("nemo", True),
    ("Nemo", True),
    ("org.gnome.Nautilus", True),
    ("Nautilus", True),
    ("org.gnome.nautilus", True),
    ("pcmanfm-qt", True),
    ("org.darktable.darktable", False),
    ("dolphin-emu", False),
    ("anemone", False),
    ("org.gnome.NautilusPreviewer", False),
    ("markdown-viewer", False),
    ("org.kde.dolphinX", False),
    ("xorg.kde.dolphin", False),
    ("pcmanfm", False),
]


def load_rules() -> list[dict]:
    out = subprocess.run(
        ["lua", "-e", DUMP],
        env={**os.environ, "HYDE_LUA_DIR": str(LUA_DIR)},
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        print(out.stderr, file=sys.stderr)
        sys.exit("FAIL: window_rules.lua did not load against the stub")

    rules: list[dict] = []
    for line in out.stdout.splitlines():
        kind, key, *values = line.split("\t")
        if kind == "R":
            rules.append({"name": key, "float": values[0], "opaque": values[1], "match": {}})
        else:
            rules[-1]["match"][key] = values[0]
    # A file that loads but registers nothing would make every "tile" case
    # pass vacuously.
    if not any(rule["float"] != "nil" for rule in rules):
        sys.exit("FAIL: window_rules.lua registered no float rules")
    if not any(rule["opaque"] != "nil" for rule in rules):
        sys.exit("FAIL: window_rules.lua registered no opaque rules")
    for rule in rules:
        for key, pattern in rule["match"].items():
            try:
                re.compile(pattern)
            except re.error as err:
                sys.exit(f"FAIL: rule {rule['name']!r} has an invalid {key} regex: {err}")
    return rules


def prop(rules: list[dict], cls: str, title: str, name: str = "float") -> bool:
    window = {"class": cls, "title": title, "initial_title": title}
    result = False
    for rule in rules:
        if rule[name] == "nil":
            continue
        matched = True
        for key, pattern in rule["match"].items():
            if key not in window:
                # modal = true, tag = ...: never true for these plain windows.
                matched = False
                break
            if not re.fullmatch(pattern, window[key]):
                matched = False
                break
        if matched:
            result = rule[name] == "true"
    return result


def floating(rules: list[dict], cls: str, title: str) -> bool:
    return prop(rules, cls, title, "float")


def main() -> int:
    rules = load_rules()
    failures = 0
    for cls, title, expected in CASES:
        got = floating(rules, cls, title)
        if got != expected:
            failures += 1
            want = "float" if expected else "tile"
            print(f"FAIL: {cls} '{title}' should {want}", file=sys.stderr)
    for cls, expected in OPAQUE_CASES:
        if prop(rules, cls, "x", "opaque") != expected:
            failures += 1
            want = "be" if expected else "not be"
            print(f"FAIL: {cls} should {want} opaque", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
