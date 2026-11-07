"""Guard against icon-only Waybar glyphs bleeding into the next module.

A handful of Nerd Font glyphs HyDE's default modules use (the caffeine cup,
the media player drawer's previous/play-pause/next controls, and the eyecare
drawer's backlight icon) render wider than the logical advance width GTK
allocates them -- Pango reports their ink extent about 1.5x the logical
width at the bar's font size. With nothing after them, that overflow bleeds
into whichever module a layout places right after, which looked like
overlapping icons (#2206).

The fix is CSS padding (`defaults.css`), not a trailing space baked into the
module's `format` string: a trailing space becomes part of the label text,
so on a module with `"justify": "center"` (custom/caffeine) it skews the
glyph off-center the moment the label gets more width than its content
needs -- e.g. from a themed min-width (flagged in PR #2209 review by
kRHYME7). This check keeps both halves of that fix in sync: no module
regains a trailing space in its `format`, and `defaults.css` keeps a
`padding-right` rule for each affected CSS selector.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", "."))
MODULES_DIR = REPO_ROOT / "Configs" / ".local" / "share" / "waybar" / "modules"
DEFAULTS_CSS = REPO_ROOT / "Configs" / ".local" / "share" / "waybar" / "styles" / "defaults.css"

COMMENT = re.compile(r"//.*")

# (file, module key) -> CSS selector that must carry the padding instead
MODULE_SELECTORS = {
    ("custom-caffeine.jsonc", "custom/caffeine"): "#custom-caffeine",
    ("group-eyecare.jsonc", "backlight#eyecare"): "#backlight.eyecare",
    ("group-mediaplayer.jsonc", "custom/mediaplayer-play-pause"): "#custom-mediaplayer-play-pause",
    ("group-mediaplayer.jsonc", "custom/mediaplayer-next"): "#custom-mediaplayer-next",
    ("group-mediaplayer.jsonc", "custom/mediaplayer-previous"): "#custom-mediaplayer-previous",
}


def _selector_has_padding_right(css_text: str, selector: str) -> bool:
    # Selectors share one rule block (comma-separated), so just check the
    # selector token appears somewhere before the next "}" that also
    # contains a padding-right declaration.
    pattern = re.compile(
        re.escape(selector) + r"[^{]*\{[^}]*padding-right\s*:", re.DOTALL
    )
    return bool(pattern.search(css_text))


def main() -> int:
    if not MODULES_DIR.is_dir():
        print(f"no waybar modules directory under {REPO_ROOT}", file=sys.stderr)
        return 1

    failures = 0
    for (filename, module_key), selector in sorted(MODULE_SELECTORS.items()):
        path = MODULES_DIR / filename
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            failures += 1
            continue

        data = json.loads(COMMENT.sub("", text))
        fmt = data.get(module_key, {}).get("format", "")
        if fmt and fmt[-1].isspace():
            print(
                f"{path}: {module_key!r} format {fmt!r} ends in a space -- "
                f"the overflow gap belongs in defaults.css ({selector}), not "
                "in the label text, or centered modules skew off-center",
                file=sys.stderr,
            )
            failures += 1

    try:
        css_text = DEFAULTS_CSS.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"{DEFAULTS_CSS}: {exc}", file=sys.stderr)
        return 1

    for selector in sorted(set(MODULE_SELECTORS.values())):
        if not _selector_has_padding_right(css_text, selector):
            print(
                f"{DEFAULTS_CSS}: no padding-right rule for {selector!r}, so "
                "its icon's ink can bleed into the next module (#2206)",
                file=sys.stderr,
            )
            failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
