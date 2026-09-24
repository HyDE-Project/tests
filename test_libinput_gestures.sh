#!/usr/bin/env bash
# The shipped libinput-gestures.conf had stopped working entirely: its
# commands called HyDE scripts by filename (volumecontrol.sh, cliphist.sh,
# ...), which no longer live in PATH, used `hyprctl dispatch exec ...`, which
# Hyprland's Lua config rejects, and relied on a shell that libinput-gestures
# never starts -- it splits the command like a shell but runs it directly, so
# `a || b` and trailing `# comments` were passed on as arguments.
#
# This parses the file the way libinput-gestures does and checks each command.
# The checker runs against fixture files first: a valid file, and one case per
# rule plus malformed lines (unbalanced quote, a gesture with no command).

. "$(dirname -- "$0")/lib/common.sh"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 is not installed"
    finish
}

check() {
    python3 - "$1" "$2" <<'EOF'
import os, re, shlex, subprocess, sys

conf, root = sys.argv[1], sys.argv[2]
lib = os.path.join(root, "Configs/.local/lib/hyde")
problems = []
OPERATORS = {"||", "&&", "|", ";", "&", ">", ">>", "<", "2>", "2>&1"}

def resolves(name):
    for ext in (".lua", ".sh", ".py"):
        if os.path.isfile(os.path.join(lib, name + ext)):
            return True
    path = os.path.join(lib, name)
    return os.path.isfile(path) and os.access(path, os.X_OK)

def check_hyde_shell(where, words):
    for i, w in enumerate(words[:-1]):
        if w == "hyde-shell" and not resolves(words[i + 1]):
            problems.append(f"{where}: hyde-shell {words[i + 1]}: no such script")

def check_command(where, cmd):
    try:
        words = shlex.split(cmd)
    except ValueError as e:
        problems.append(f"{where}: cannot split command ({e}): {cmd}")
        return
    if not words:
        problems.append(f"{where}: gesture has no command")
        return
    if words[0] in ("sh", "bash") and len(words) >= 3 and words[1] == "-c":
        script = words[2]
        if subprocess.run(["sh", "-n", "-c", script], capture_output=True).returncode != 0:
            problems.append(f"{where}: shell syntax error in sh -c: {script}")
        for part in re.split(r"\|\||&&|;|\|", script):
            try:
                check_hyde_shell(where, shlex.split(part))
            except ValueError:
                pass
        return
    for w in words:
        if w.startswith("#"):
            problems.append(f"{where}: trailing comment is passed as arguments: {cmd}")
            break
    for w in words:
        if w in OPERATORS:
            problems.append(f"{where}: shell operator '{w}' without a shell (use sh -c): {cmd}")
            break
    if re.search(r"\.(sh|py)$", words[0]) and not words[0].startswith("/"):
        problems.append(f"{where}: HyDE script called by filename, not via hyde-shell: {words[0]}")
    if words[0] == "hyprctl" and len(words) >= 3 and words[1] == "dispatch" \
            and not words[2].startswith("hl."):
        problems.append(f"{where}: hyprctl dispatch needs Lua (hl.dsp...) under the Lua config: {cmd}")
    check_hyde_shell(where, words)

try:
    lines = open(conf, encoding="utf-8").read().split("\n")
except (OSError, UnicodeDecodeError) as e:
    print(f"{conf}: cannot read ({e})")
    sys.exit(1)

gestures = 0
for i, line in enumerate(lines, 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("gesture"):
        gestures += 1
        # gesture <type> <motion> [fingers] <command>
        fields = line.split(None, 3)
        rest = fields[3] if len(fields) > 3 else ""
        m = re.match(r"(\d+)\s+(.*)", rest)
        cmd = m.group(2) if m else ("" if re.fullmatch(r"\d*", rest) else rest)
        check_command(f"line {i}", cmd)
if gestures == 0:
    problems.append("no gestures found")

print("\n".join(problems))
sys.exit(1 if problems else 0)
EOF
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
fixture_root="$work_dir/root"
mkdir -p "$fixture_root/Configs/.local/lib/hyde"
: >"$fixture_root/Configs/.local/lib/hyde/volumecontrol.sh"
: >"$fixture_root/Configs/.local/lib/hyde/cliphist.sh"
conf="$work_dir/gestures.conf"

expect_ok() {
    local out
    out=$(check "$conf" "$fixture_root") || fail "$1 was reported: $out"
}

expect_problem() {
    local out
    out=$(check "$conf" "$fixture_root") && fail "$1 passed"
    case "$out" in *"$2"*) ;; *) fail "$1 was not reported as '$2': $out" ;; esac
}

printf '%s\n' '# a comment line' '' 'swipe_threshold 0' \
    'gesture pinch clockwise 4 hyde-shell volumecontrol -o i 10' \
    "gesture swipe up 4 hyprctl dispatch 'hl.dsp.window.fullscreen()'" \
    "gesture swipe right sh -c 'pkill -x rofi || hyde-shell cliphist -c'" \
    'gesture swipe left 4 dunstctl history-pop' >"$conf"
expect_ok "a valid file (with and without a finger count)"

printf '%s\n' 'gesture pinch in 4 volumecontrol.sh -o d' >"$conf"
expect_problem "a HyDE script called by filename" "not via hyde-shell"

printf '%s\n' 'gesture swipe down 4 hyprctl dispatch exec screenshot' >"$conf"
expect_problem "a legacy hyprctl dispatch" "needs Lua"

printf '%s\n' 'gesture swipe right 4 pkill rofi || hyde-shell cliphist -c' >"$conf"
expect_problem "a shell operator without a shell" "shell operator '||'"

printf '%s\n' 'gesture swipe down 4 hyde-shell cliphist -c  # open history' >"$conf"
expect_problem "a trailing comment" "trailing comment"

printf '%s\n' 'gesture swipe down 4 hyde-shell no-such-script' >"$conf"
expect_problem "an unknown hyde-shell subcommand" "no such script"

printf '%s\n' "gesture swipe down 4 sh -c 'pkill -x rofi || hyde-shell nope'" >"$conf"
expect_problem "an unknown hyde-shell subcommand inside sh -c" "hyde-shell nope: no such script"

printf '%s\n' "gesture swipe down 4 sh -c 'if true; then'" >"$conf"
expect_problem "a syntax error inside sh -c" "shell syntax error"

printf '%s\n' "gesture swipe down 4 hyde-shell cliphist -c 'unclosed" >"$conf"
expect_problem "an unbalanced quote" "cannot split"

printf '%s\n' 'gesture swipe down 4' >"$conf"
expect_problem "a gesture with no command" "no command"

printf '%s\n' '# only comments' 'swipe_threshold 0' >"$conf"
expect_problem "a file without gestures" "no gestures found"

expect_missing() {
    local out
    out=$(check "$work_dir/missing.conf" "$fixture_root") && fail "a missing file passed"
    case "$out" in *"cannot read"*) ;; *) fail "a missing file was not reported: $out" ;; esac
}
expect_missing

# --- the shipped file ---
out=$(check "$REPO_ROOT/Configs/.config/libinput-gestures.conf" "$REPO_ROOT") ||
    fail "broken gesture commands:
$out"

printf '    libinput-gestures commands checked\n'

finish
