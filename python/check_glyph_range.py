"""Guard against glyphs the pinned Nerd Fonts release no longer carries.

Nerd Fonts v3 moved the Material Design set from U+F500-U+FD46 to U+F0001 and
left U+F534 to U+FD46 empty. A config that still names a codepoint in that span
renders wrong on every fresh install, since the fonts the dots deploy are v3.
The old block is not simply reassigned: what is left of it below U+F534 belongs
to Octicons, which are still shipped, so the check names the empty span rather
than the whole former block.

The old set ran past the private-use area into the CJK compatibility and
presentation-form blocks (U+F900 onward). A glyph there does not render as a
box but as an unrelated real character, e.g. the old volume-off icon U+FA80
shows up as a CJK ideograph in the waybar mute state (HyDE-Project/HyDE#2132).
Those blocks hold nothing a HyDE config otherwise needs, so the whole span is
treated as dead.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

DEAD_FIRST = 0xF534
DEAD_LAST = 0xFD46

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", "."))
# Configs is what gets deployed; Scripts carries the installer's own terminal
# output, which is rendered in the same Nerd Font.
SCAN_DIRS = (REPO_ROOT / "Configs", REPO_ROOT / "Scripts")

ESCAPE = re.compile(r"\\u([0-9a-fA-F]{4})")


def dead(codepoint: int) -> bool:
    """Report whether a codepoint falls in the span v3 left unassigned."""
    return DEAD_FIRST <= codepoint <= DEAD_LAST


def offenders(text: str) -> list:
    """Collect the line numbers and codepoints a file names from that span.

    A glyph is written either as the character itself or as an escape the
    consumer expands, and both forms have to be read the same way.
    """
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        for match in ESCAPE.finditer(line):
            codepoint = int(match.group(1), 16)
            if dead(codepoint):
                found.append((number, codepoint))
        for char in line:
            if dead(ord(char)):
                found.append((number, ord(char)))
    return found


def main() -> int:
    """Walk the shipped configuration and report every dead glyph in it."""
    missing = [d for d in SCAN_DIRS if not d.is_dir()]
    if missing:
        for directory in missing:
            print(f"no {directory.name} directory under {REPO_ROOT}", file=sys.stderr)
        return 1

    failures = 0
    paths = sorted(p for d in SCAN_DIRS for p in d.rglob("*"))
    for path in paths:
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, codepoint in offenders(text):
            failures += 1
            relative = path.relative_to(REPO_ROOT)
            print(
                f"{relative}:{number}: U+{codepoint:04X} is not in Nerd Fonts v3",
                file=sys.stderr,
            )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
