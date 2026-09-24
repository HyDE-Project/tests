#!/usr/bin/env bash
# getopt (and Python's argparse) accept any unambiguous prefix of a long
# option: the wallpaper keybind passed `--prev` to wallpaper.sh, which only
# defines `--previous`, and worked only because nothing else starts with
# "prev". Adding any such option later would silently break the keybind, and
# a caller passing an option the script doesn't define at all fails only when
# someone presses that key.
#
# So every long option a shipped caller passes to a getopt-based shell script
# or a Python argparse script must be spelled exactly as the script defines
# it. Callers are Hyprland Lua keybinds (`hyde.sh.<name>(...)`, resolved
# through dispatcher.lua's command map), Waybar configs and scripts.
#
# The checker runs against fixture trees first: an exact option, an
# abbreviation, an unknown option, `--opt=value`, a bare `--`, a commented-out
# Lua line, a dispatcher-mapped name, and a Python script.

. "$(dirname -- "$0")/lib/common.sh"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 is not installed"
    finish
}

check() {
    python3 - "$1" <<'EOF'
import os, re, sys

root = sys.argv[1]
configs = os.path.join(root, "Configs")
lib = os.path.join(configs, ".local/lib/hyde")
problems = []

def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        return None

# name -> set of long options, for getopt shell scripts and argparse scripts.
defined = {}
for name in sorted(os.listdir(lib)) if os.path.isdir(lib) else []:
    path = os.path.join(lib, name)
    text = read(path) if os.path.isfile(path) else None
    if not text:
        continue
    base, ext = os.path.splitext(name)
    if ext == ".sh":
        m = re.search(r'(?:LONGOPTS|longopts|long_opts)="([^"]*)"', text)
        if m:
            defined[base] = {o.rstrip(":") for o in m.group(1).split(",") if o}
    elif ext == ".py":
        opts = set(re.findall(r'add_argument\([^)]*?"--([a-z0-9][\w-]*)"', text, re.S))
        if opts:
            defined[base] = opts

def check_args(where, name, args):
    opts = defined.get(name)
    if opts is None:
        return
    for arg in args:
        if arg == "--":
            break
        m = re.fullmatch(r"--([a-z0-9][\w-]*)(=.*)?", arg)
        if not m or m.group(1) in opts or m.group(1) == "help":
            continue
        full = sorted(o for o in opts if o.startswith(m.group(1)))
        if full:
            problems.append(f"{where}: {name} {arg} is an abbreviation of --{full[0]}")
        else:
            problems.append(f"{where}: {name} has no option {arg}")

# Hyprland Lua: hyde.sh.<key>(...) runs the dispatcher's command for <key>
# (or <key> itself) with the call's string arguments appended.
dispatcher = os.path.join(configs, ".local/share/hypr/lua/hyde/dispatcher.lua")
cmap = dict(re.findall(r'\[\s*"([^"]+)"\s*\]\s*=\s*"([^"]+)"', read(dispatcher) or ""))

names = "|".join(re.escape(n) for n in sorted(defined, key=len, reverse=True)) or "(?!)"
shell_call = re.compile(r"(?:^|[\s\"'`(;|&])(?:hyde-shell\s+)?(" + names + r")(?:\.sh|\.py)?\s+([^\"'`;|&\n)]*)")

for dirpath, _, files in os.walk(configs):
    for fname in sorted(files):
        path = os.path.join(dirpath, fname)
        text = read(path)
        if text is None:
            continue
        rel = os.path.relpath(path, root)
        for i, line in enumerate(text.split("\n"), 1):
            stripped = line.lstrip()
            if fname.endswith(".lua"):
                if stripped.startswith("--"):
                    continue
                for key, raw in re.findall(r"hyde\.(?:sh|dsp|shell)\.([\w.]+)\(([^)]*)\)", line):
                    command = cmap.get(key, key).split()
                    args = command[1:] + re.findall(r'"([^"]*)"', raw)
                    check_args(f"{rel}:{i}", re.sub(r"\.(sh|py)$", "", command[0]), args)
                continue
            if stripped.startswith("#"):
                continue
            for name, rest in shell_call.findall(line):
                check_args(f"{rel}:{i}", name, rest.split())

print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
}

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

# Builds a fixture tree with a getopt script "wall" (--next, --previous,
# --set:), a Python script "bar" (--hide), and $1 as the keybind Lua file.
fixture() {
    rm -rf "${fixture_root:?}/Configs"
    local lib="$fixture_root/Configs/.local/lib/hyde" lua="$fixture_root/Configs/.local/share/hypr/lua"
    mkdir -p "$lib" "$lua/hyde"
    printf 'LONGOPTS="next,previous,set:,global"\n' >"$lib/wall.sh"
    printf 'parser.add_argument("--hide", action="store_true")\n' >"$lib/bar.py"
    printf '[ "menu.walls" ] = "wall --global",\n' >"$lua/hyde/dispatcher.lua"
    printf '%s\n' "$1" >"$lua/key_binds.lua"
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

fixture 'hl.bind("A", hl.dsp.exec_cmd(hyde.sh.wall("--previous")), _F)
hl.bind("B", hl.dsp.exec_cmd(hyde.sh.wall("--set=foo.png")), _F)
hl.bind("C", hl.dsp.exec_cmd(hyde.sh.wall("--next", "--", "--anything")), _F)
hl.bind("D", hl.dsp.exec_cmd(hyde.sh.bar("--hide")), _F)
-- hl.bind("E", hl.dsp.exec_cmd(hyde.sh.wall("--prev")), _F)'
expect_ok "exact options, --opt=value, options after --, and a commented-out line"

fixture 'hl.bind("A", hl.dsp.exec_cmd(hyde.sh.wall("--prev")), _F)'
expect_problem "an abbreviated option (the keybind bug)" "wall --prev is an abbreviation of --previous"

fixture 'hl.bind("A", hl.dsp.exec_cmd(hyde.sh.wall("--bogus")), _F)'
expect_problem "an unknown option" "wall has no option --bogus"

fixture 'hl.bind("A", hl.dsp.exec_cmd(hyde.sh.menu.walls("--prev")), _F)'
expect_problem "an abbreviation through a dispatcher-mapped name" "is an abbreviation of --previous"

fixture 'hl.bind("A", hl.dsp.exec_cmd(hyde.sh.bar("--hid")), _F)'
expect_problem "an abbreviation for a Python script" "bar --hid is an abbreviation of --hide"

fixture ''
printf '"on-click": "hyde-shell wall --glob -n"\n' >"$fixture_root/Configs/waybar.jsonc"
expect_problem "an abbreviation in a non-Lua caller" "wall --glob is an abbreviation of --global"

# --- the shipped callers ---
out=$(check "$REPO_ROOT") || fail "long options not spelled out exactly:
$out"

printf '    long options passed to getopt/argparse scripts checked\n'

finish
