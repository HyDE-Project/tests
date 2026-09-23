#!/usr/bin/env sh
# The glyphs moved from Nerd Fonts v2 to v3 must name the same icon as before.
# v3 moved Material Design from U+F500 to U+F0001, but not by one constant
# offset: the old set had gaps, so an arithmetic mapping lands on a neighbour
# for part of it (U+FD15 comment_question became clover, U+FBE6 lightbulb_on
# became laptop_off). Each entry pins the v3 codepoint of the icon the v2
# codepoint named, as listed in Nerd Fonts' glyphnames.json (v3.4.0) and
# css/nerd-fonts-generated.css (v2.3.3).

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 > /dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

python3 - "$REPO_ROOT" <<'EOF' || fail "a replaced v2 glyph names a different icon in v3"
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
# file, text on the line, v3 codepoint, v3 name (v2 codepoint it replaced)
PINS = [
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Next<", 0xF04AD, "md-skip_next (F9AC)"),
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Previous<", 0xF04AE, "md-skip_previous (F9AD)"),
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Stop<", 0xF04DB, "md-stop (F9DA)"),
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Repeat Once<", 0xF0458, "md-repeat_once (F957)"),
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Repeat<", 0xF0456, "md-repeat (F955)"),
    ("Configs/.local/share/waybar/menus/mediaplayer.xml", "Disable loop<", 0xF0457, "md-repeat_off (F956)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Next<", 0xF04AD, "md-skip_next (F9AC)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Previous<", 0xF04AE, "md-skip_previous (F9AD)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Stop<", 0xF04DB, "md-stop (F9DA)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Repeat Once<", 0xF0458, "md-repeat_once (F957)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Repeat<", 0xF0456, "md-repeat (F955)"),
    ("Configs/.local/share/waybar/menus/spotify.xml", "Disable loop<", 0xF0457, "md-repeat_off (F956)"),
    ("Configs/.local/share/waybar/modules/pulseaudio.jsonc", '"format-muted"', 0xF0581, "md-volume_off (FA80)"),
    ("Configs/.local/share/waybar/modules/group-volumecontrol.jsonc", '"format-muted"', 0xF0581, "md-volume_off (FA80)"),
    ("Configs/.local/lib/hyde/hyprlock.sh", '["vlc"]', 0xF057C, "md-vlc (FA7B)"),
    ("Configs/.local/lib/hyde/keybinds_hint.sh", "Description", 0xF0817, "md-comment_question (FD15)"),
    ("Configs/.local/lib/hyde/sensorsinfo.py", "Powers:", 0xF0427, "md-power_socket (F926)"),
    ("Scripts/chaotic_aur.sh", "--install [fresh]", 0xF06E8, "md-lightbulb_on (FBE6)"),
    ("Scripts/chaotic_aur.sh", "--uninstall ", 0xF06E8, "md-lightbulb_on (FBE6)"),
    ("Scripts/chaotic_aur.sh", "--revert ", 0xF06E8, "md-lightbulb_on (FBE6)"),
]

failures = 0
for path, anchor, codepoint, name in PINS:
    try:
        lines = [l for l in (root / path).read_text(encoding="utf-8").splitlines() if anchor in l]
    except (OSError, UnicodeDecodeError) as err:
        print(f"{path}: unreadable ({err})", file=sys.stderr)
        failures += 1
        continue
    # A missing anchor means the line moved or was reworded: re-pin it rather
    # than pass silently.
    if not lines:
        print(f"{path}: no line with {anchor!r}", file=sys.stderr)
        failures += 1
        continue
    for line in lines:
        # Exactly the pinned glyph: its neighbours are what the off-by-one
        # mapping produced, and the old v2 codepoint is what v3 dropped.
        glyphs = [ord(c) for c in line if 0xF0000 <= ord(c) <= 0xFFFFD or 0xF500 <= ord(c) <= 0xFD46]
        if glyphs != [codepoint]:
            found = ", ".join(f"U+{g:04X}" for g in glyphs) or "none"
            print(f"{path}: {anchor!r} has {found}, expected U+{codepoint:04X} {name}", file=sys.stderr)
            failures += 1

sys.exit(1 if failures else 0)
EOF

finish
