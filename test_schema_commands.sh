#!/usr/bin/env bash
# The config schema names the command each section configures, quoted like
# 'hyde-shell hyprlock select'. Those read as runnable commands, and some were
# wrong in a way that mattered: hyprlock.sh ignores the positional "select"
# and falls through to its default action, so running the documented command
# locked the screen instead of opening the layout selector. Others named
# scripts that no longer exist ('animation.sh select', 'cava.sh waybar').
#
# Every quoted command in schema.toml must run through hyde-shell, resolve to
# a script, and pass only arguments that script declares; the four schema
# files (schema.toml and the three generated from it) must quote the same
# commands. The checker runs against fixture trees first.

. "$(dirname -- "$0")/lib/common.sh"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 is not installed"
    finish
}

check() {
    python3 - "$1" <<'EOF'
import os, re, sys

root = sys.argv[1]
lib = os.path.join(root, "Configs/.local/lib/hyde")
schema = os.path.join(root, "Configs/.local/share/hyde/schema")
problems = []
QUOTED = re.compile(r"'((?:hyde-shell\s+)?[\w.-]+(?:\s+[^'\s]+)*)' configuration")

def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return None

def script_for(name):
    for ext in (".lua", ".sh", ".py"):
        path = os.path.join(lib, name + ext)
        if os.path.isfile(path):
            return path
    return None

def accepted(path):
    """Arguments a script declares, or None when it can't be told."""
    text = read(path) or ""
    if "shutils/argparse.sh" in text:
        words = set()
        for spec in re.findall(r'^\s*argparse\s+"([^"]+)"', text, re.M):
            words.update(spec.split(","))
        return words
    if path.endswith(".py"):
        # Subcommands: add_parser("x"), or a helper handed the subparsers
        # object and the name, like cava.py's create_client_parser(subparsers, "x").
        return set(re.findall(r'add_parser\(\s*"([\w-]+)"', text)) | \
            set(re.findall(r'\(\s*subparsers\s*,\s*"([\w-]+)"', text)) | \
            set(re.findall(r'add_argument\([^)]*?"(--?[\w-]+)"', text, re.S))
    if path.endswith(".lua") and "luautils.selector.common" in text:
        common = read(os.path.join(lib, "luautils/selector/common.lua")) or ""
        return set(re.findall(r'"(--[\w-]+)"', common))
    return None

source = read(os.path.join(schema, "schema.toml"))
if source is None:
    print("schema.toml: cannot read")
    sys.exit(1)
commands = sorted(set(QUOTED.findall(source)))
if not commands:
    problems.append("schema.toml: no quoted commands found")

for cmd in commands:
    words = cmd.split()
    if words[0] != "hyde-shell":
        problems.append(f"'{cmd}': not run through hyde-shell")
        continue
    if len(words) < 2:
        problems.append(f"'{cmd}': no script named")
        continue
    name, args = words[1], words[2:]
    path = script_for(name)
    if not path:
        problems.append(f"'{cmd}': no such script {name}")
        continue
    known = accepted(path)
    if known is None:
        continue
    for arg in args:
        if arg not in known:
            problems.append(f"'{cmd}': {os.path.basename(path)} does not accept '{arg}'")

for generated in ("config.toml", "config.toml.json", "config.md"):
    text = read(os.path.join(schema, generated))
    if text is None:
        problems.append(f"{generated}: cannot read")
        continue
    theirs = sorted(set(QUOTED.findall(text)))
    if theirs != commands:
        problems.append(f"{generated}: quotes {sorted(set(theirs) ^ set(commands))} differently from schema.toml")

print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
}

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
fx_lib="$fixture_root/Configs/.local/lib/hyde"
fx_schema="$fixture_root/Configs/.local/share/hyde/schema"

# $1 = the quoted command, written into all four schema files.
fixture() {
    rm -rf "${fixture_root:?}/Configs"
    mkdir -p "$fx_lib/luautils/selector" "$fx_schema"
    printf 'source "${LIB_DIR}/hyde/shutils/argparse.sh"\nargparse "background,--background" "" "x"\nargparse "--select,-S" "" "x"\n' >"$fx_lib/lock.sh"
    printf 'sub.add_parser("waybar")\nmake_client(subparsers, "stdout", "x")\nparser.add_argument("--json")\n' >"$fx_lib/viz.py"
    printf 'local common = require("luautils.selector.common")\n' >"$fx_lib/anims.lua"
    printf 'local flags = { "--select", "--set" }\n' >"$fx_lib/luautils/selector/common.lua"
    printf '#!/bin/sh\n' >"$fx_lib/plain.sh"
    local f
    for f in schema.toml config.toml config.toml.json config.md; do
        printf 'description = "%s configuration."\n' "$1" >"$fx_schema/$f"
    done
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

for ok in "'hyde-shell lock --select'" "'hyde-shell lock -S'" "'hyde-shell lock background'" \
    "'hyde-shell viz waybar'" "'hyde-shell viz stdout'" "'hyde-shell anims --select'" "'hyde-shell plain anything'"; do
    fixture "$ok"
    expect_ok "$ok"
done

fixture "'hyde-shell lock select'"
expect_problem "a positional the argparse.sh script ignores (the hyprlock bug)" "lock.sh does not accept 'select'"
fixture "'hyde-shell lock --selct'"
expect_problem "a misspelled flag" "does not accept '--selct'"
fixture "'hyde-shell viz nowhere'"
expect_problem "an unknown Python subcommand" "viz.py does not accept 'nowhere'"
fixture "'hyde-shell anims select'"
expect_problem "a Lua selector call without --" "anims.lua does not accept 'select'"
fixture "'hyde-shell gone --select'"
expect_problem "a script that doesn't exist" "no such script gone"
fixture "'lock.sh --select'"
expect_problem "a script called by filename" "not run through hyde-shell"

fixture "'hyde-shell lock --select'"
printf 'description = "%s configuration."\n' "'hyde-shell lock select'" >"$fx_schema/config.md"
expect_problem "a generated file that drifted from schema.toml" "config.md: quotes"

fixture "'hyde-shell lock --select'"
rm "$fx_schema/config.toml.json"
expect_problem "a missing generated file" "config.toml.json: cannot read"

fixture ""
printf 'description = "nothing quoted"\n' >"$fx_schema/schema.toml"
expect_problem "a schema without quoted commands" "no quoted commands"

# --- the shipped schema ---
out=$(check "$REPO_ROOT") || fail "schema commands:
$out"

printf '    commands quoted in the config schema checked\n'

finish
