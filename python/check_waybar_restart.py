"""Switching layouts must restart Waybar once, from complete files.

restart_waybar() hot-reloaded Waybar with SIGUSR2. Even limited to the main
process (HyDE-Project/HyDE#2189), fast layout switching still broke the bar
(HyDE-Project/HyDE#2184): --set reloaded in _apply_layout() and again ~20 ms
later when main() fell through to its default refresh, the second round of
writes emptied config.jsonc/includes.json while Waybar was still reading them
("Error parsing JSON: Line 1, Column 1"), and a Waybar started a moment
earlier was killed by the signal before installing its handler.

This covers: under systemd, restart_waybar() restarts the unit (after
reset-failed) and only falls back to run_waybar() when the restart fails; the
non-systemd path keeps its SIGUSR2 reload; _atomic_write() replaces a file in
one step, keeps its mode, writes through a symlink and leaves nothing behind
on failure; and one --set refreshes the files and restarts Waybar once.
subprocess.run is mocked throughout, so no real unit is touched.
"""

from __future__ import annotations

import atexit
import importlib.util
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
from unittest import mock

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LIB = REPO_ROOT / "Configs/.local/lib/hyde"

failures = 0


def fail(msg: str) -> None:
    global failures
    failures += 1
    print(f"FAIL: {msg}", file=sys.stderr)


work = pathlib.Path(tempfile.mkdtemp(prefix="waybar_restart_"))
atexit.register(shutil.rmtree, work, ignore_errors=True)
for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                 ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
                 ("XDG_RUNTIME_DIR", "run"), ("HOME", "home")):
    (work / sub).mkdir()
    os.environ[var] = str(work / sub)
# waybar.py exits at import when no waybar binary is on PATH.
bindir = work / "bin"
bindir.mkdir()
(bindir / "waybar").write_text("#!/bin/sh\nexit 0\n")
(bindir / "waybar").chmod(stat.S_IRWXU)
os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}"
sys.path.insert(0, str(LIB))

spec = importlib.util.spec_from_file_location("waybar_under_test", LIB / "waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

UNIT = "hyde-test-bar.service"
wb.UNIT_NAME = UNIT


def restart_calls(has_systemd: bool, running: bool, restart_rc: int = 0):
    """Run restart_waybar(); return (subprocess argvs, signals sent, run_waybar called)."""
    wb.HAS_SYSTEMD = has_systemd

    def fake_run(argv, *args, **kwargs):
        rc = restart_rc if argv[:3] == ["systemctl", "--user", "restart"] else 0
        return subprocess.CompletedProcess(argv, rc, b"", b"")

    with mock.patch.object(wb.subprocess, "run", side_effect=fake_run) as run, \
         mock.patch.object(wb, "is_waybar_running_for_current_user", return_value=running), \
         mock.patch.object(wb, "_signal_waybar") as signal_mock, \
         mock.patch.object(wb, "run_waybar") as run_mock:
        wb.restart_waybar()
    return ([c.args[0] for c in run.call_args_list],
            [c.args[0] for c in signal_mock.call_args_list],
            run_mock.called)


# 1. systemd, Waybar running: reset-failed, then restart the unit. No SIGUSR2.
argvs, signals, started = restart_calls(has_systemd=True, running=True)
if signals:
    fail(f"systemd: restart_waybar() still signals Waybar: {signals}")
if ["systemctl", "--user", "restart", UNIT] not in argvs:
    fail(f"systemd: restart_waybar() does not restart the unit: {argvs}")
elif ["systemctl", "--user", "reset-failed", UNIT] not in argvs[:argvs.index(
        ["systemctl", "--user", "restart", UNIT])]:
    fail(f"systemd: no reset-failed before the restart, so fast switching can "
         f"hit the start limit: {argvs}")
if started:
    fail("systemd: restart_waybar() also called run_waybar() after a successful restart")

# 2. systemd, Waybar not running: restart starts an inactive unit too, so the
# same commands run; nothing is signalled.
argvs, signals, started = restart_calls(has_systemd=True, running=False)
if signals or ["systemctl", "--user", "restart", UNIT] not in argvs:
    fail(f"systemd, not running: expected a unit restart, got {argvs}, signals {signals}")

# 3. systemd, restart fails (the transient unit was collected): fall back to
# run_waybar(), which recreates it.
argvs, signals, started = restart_calls(has_systemd=True, running=False, restart_rc=5)
if not started:
    fail("systemd: restart_waybar() does not fall back to run_waybar() when the restart fails")

# 4. no systemd: unchanged, SIGUSR2 when running, a plain start otherwise.
argvs, signals, started = restart_calls(has_systemd=False, running=True)
if signals != ["SIGUSR2"] or started:
    fail(f"non-systemd, running: expected one SIGUSR2 reload, got {signals}, started={started}")
argvs, signals, started = restart_calls(has_systemd=False, running=False)
if signals or not started:
    fail(f"non-systemd, not running: expected a start, got {signals}, started={started}")

# 5. _atomic_write() / _atomic_copy()
def check_atomic_write() -> None:
    adir = work / "atomic"
    adir.mkdir()
    target = adir / "style.css"
    target.write_text("old")
    target.chmod(0o640)
    wb._atomic_write(str(target), "new ✓")
    if target.read_text(encoding="utf-8") != "new ✓":
        fail("_atomic_write() did not write the new content")
    if stat.S_IMODE(target.stat().st_mode) != 0o640:
        fail(f"_atomic_write() changed the file mode to {oct(stat.S_IMODE(target.stat().st_mode))}")

    fresh = adir / "includes.json"
    wb._atomic_write(str(fresh), b'{"include": []}')
    if fresh.read_bytes() != b'{"include": []}':
        fail("_atomic_write() did not write bytes as-is")
    if stat.S_IMODE(fresh.stat().st_mode) != 0o644:
        fail(f"a new file is {oct(stat.S_IMODE(fresh.stat().st_mode))}, not 0644 (mkstemp's 0600 leaked)")

    # A symlinked config (dotfiles managers) stays a symlink; the file behind it changes.
    real = adir / "dotfiles" / "config.jsonc"
    real.parent.mkdir()
    real.write_text("{}")
    link = adir / "config.jsonc"
    link.symlink_to(real)
    src = adir / "layout.jsonc"
    src.write_text('{"layer": "top"}')
    wb._atomic_copy(str(src), str(link))
    if not link.is_symlink():
        fail("_atomic_copy() replaced a symlinked config with a regular file")
    if real.read_text() != '{"layer": "top"}':
        fail("_atomic_copy() did not write through the symlink")

    # A failed write leaves the old file intact and no temp file behind.
    before = sorted(p.name for p in adir.iterdir())
    with mock.patch.object(wb.os, "replace", side_effect=OSError("disk full")):
        try:
            wb._atomic_write(str(target), "half")
            fail("_atomic_write() swallowed an error from os.replace()")
        except OSError:
            pass
    if target.read_text(encoding="utf-8") != "new ✓":
        fail("a failed _atomic_write() changed the target")
    if sorted(p.name for p in adir.iterdir()) != before:
        fail(f"a failed _atomic_write() left files behind: {sorted(p.name for p in adir.iterdir())}")


if hasattr(wb, "_atomic_write") and hasattr(wb, "_atomic_copy"):
    check_atomic_write()
else:
    fail("waybar.py has no _atomic_write()/_atomic_copy(); its files are still written in place")

# 6. one --set refreshes the files and restarts Waybar once. main() used to
# fall through to its default refresh after _apply_layout(), restarting twice.
layout = work / "data/waybar/layouts/alpha.jsonc"
layout.parent.mkdir(parents=True)
layout.write_text('{"a": 1}')
style = work / "data/waybar/styles/alpha.css"
style.parent.mkdir(parents=True)
style.write_text("* {}")
wb.STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
wb.STATE_FILE.write_text(f"WAYBAR_LAYOUT_PATH={layout}\nWAYBAR_LAYOUT_NAME=alpha\n")
listing = {"layouts": [{"layout": str(layout), "name": "alpha", "style": str(style)}],
           "backups": []}

counts = {name: 0 for name in ("restart_waybar", "generate_includes", "update_global_css")}


def counter(name):
    def bump(*args, **kwargs):
        counts[name] += 1
    return bump


with mock.patch.object(wb, "list_layouts", return_value=listing), \
     mock.patch.object(wb, "restart_waybar", side_effect=counter("restart_waybar")), \
     mock.patch.object(wb, "generate_includes", side_effect=counter("generate_includes")), \
     mock.patch.object(wb, "update_global_css", side_effect=counter("update_global_css")), \
     mock.patch.object(wb, "update_icon_size"), \
     mock.patch.object(wb, "update_border_radius"), \
     mock.patch.object(wb, "update_style"), \
     mock.patch.object(wb.notify, "send"), \
     mock.patch.object(sys, "argv", ["waybar.py", "--set", "alpha"]):
    try:
        wb.main()
    except SystemExit:
        pass
for name, n in counts.items():
    if n != 1:
        fail(f"--set ran {name}() {n} time(s), expected once")

sys.exit(1 if failures else 0)
