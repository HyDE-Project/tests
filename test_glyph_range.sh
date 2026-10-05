#!/usr/bin/env sh
# A shipped config may only name glyphs the deployed fonts carry.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v python3 > /dev/null 2>&1; then
    skip "python3 is not installed"
    finish
fi

# The checker's own edges first: a range bug there would pass the repo scan
# below without finding anything.
PYTHONPATH="$TESTS_DIR/python" python3 - << 'EOF' || fail "check_glyph_range misclassifies a codepoint"
import check_glyph_range as c

cases = {
    "": [],                       # empty file
    "plain ascii only": [],
    "": [],                 # last Octicon, still shipped
    "": [(1, 0xF534)],      # first dead codepoint
    "": [(1, 0xF8FF)],      # end of the private-use area
    "豈": [(1, 0xF900)],      # first codepoint past it, still old MDI
    "婢": [(1, 0xFA80)],      # old volume-off, HyDE#2132
    "﵆": [(1, 0xFD46)],      # last old MDI codepoint
    "﵇": [],                 # just past the old set
    "\U000f0581": [],             # v3 volume-off
    "婢": [],                 # the CJK character U+FA80 falls back to
    r"婢": [(1, 0xFA80)],     # escaped, upper case
    r"婢": [(1, 0xFA80)],     # escaped, lower case
    r"": [],                # escaped Octicon
    r"\uZZZZ": [],                # malformed escape
    "ok\n婢 怜": [(2, 0xFA80), (2, 0xF9AC)],  # line numbers, several per line
}
bad = [(text, want, c.offenders(text)) for text, want in cases.items()
       if sorted(c.offenders(text)) != sorted(want)]
for text, want, got in bad:
    print(f"{text!r}: want {want}, got {got}")
raise SystemExit(1 if bad else 0)
EOF

# A checkout without Scripts (or Configs) must not pass as clean.
empty=$(mktemp -d)
mkdir "$empty/Configs"
if REPO_ROOT="$empty" python3 "$TESTS_DIR/python/check_glyph_range.py" 2> /dev/null; then
    fail "check_glyph_range passes a tree with no Scripts directory"
fi
rm -rf "$empty"

python3 "$TESTS_DIR/python/check_glyph_range.py" ||
    fail "a config names a glyph Nerd Fonts v3 dropped"

finish
