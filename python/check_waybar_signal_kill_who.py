"""restart_waybar()'s SIGUSR2 hot-reload must only signal Waybar itself.

_signal_waybar() used to run `systemctl --user kill -s <sig> <unit>` with no
--kill-who. That defaults to "all", which signals every process in the
unit's cgroup -- not just Waybar: bwrap sandboxes, image loaders, module
scripts and anything else a module's on-click started are all still in that
cgroup when the reload fires, and most of them don't handle SIGUSR2 and get
killed along with the reload, leaving the bar crashed, frozen or hidden
(HyDE-Project/HyDE#2184). Restricting to --kill-who=main targets only the
main process (Waybar itself, for the Type=exec unit waybar.py starts it as).

This covers: both call sites that go through _signal_waybar (restart_waybar's
SIGUSR2 hot-reload, and SIGUSR1 as used by --hide), the non-systemd pkill
fallback (must stay unaffected), and that restart_waybar() takes the reload
path only when Waybar is already running, falling back to a plain start
otherwise -- a change that keeps the shape but breaks the behaviour, like an
accidentally dropped --kill-who or a flag landing after the unit name instead
of before it, should fail this.
"""

from __future__ import annotations

import atexit
import importlib.util
import os
import pathlib
import shutil
import stat
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


work = pathlib.Path(tempfile.mkdtemp(prefix="waybar_signal_"))
atexit.register(shutil.rmtree, work, ignore_errors=True)

# waybar.py exits at import when no waybar binary is on PATH.
bindir = work / "bin"
bindir.mkdir()
(bindir / "waybar").write_text("#!/bin/sh\nexit 0\n")
(bindir / "waybar").chmod(stat.S_IRWXU)
os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}"
sys.path.insert(0, str(LIB))

spec = importlib.util.spec_from_file_location("waybar", LIB / "waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

wb.UNIT_NAME = "hyde-Hyprland-bar.service"


def calls_for(sig: str, has_systemd: bool) -> list[list[str]]:
    wb.HAS_SYSTEMD = has_systemd
    with mock.patch.object(wb.subprocess, "run") as run:
        wb._signal_waybar(sig)
    return [call.args[0] for call in run.call_args_list]


# 1. systemd path, SIGUSR2 (the reload signal restart_waybar sends): must
# carry --kill-who=main, not just a bare `kill -s SIGUSR2 <unit>`.
calls = calls_for("SIGUSR2", has_systemd=True)
if len(calls) != 1:
    fail(f"SIGUSR2/systemd should run exactly one command, ran {len(calls)}: {calls}")
else:
    argv = calls[0]
    if "--kill-who=main" not in argv:
        fail(f"SIGUSR2/systemd does not pass --kill-who=main, so the signal still "
             f"reaches the whole cgroup, not just Waybar: {argv}")
    if argv[:3] != ["systemctl", "--user", "kill"]:
        fail(f"SIGUSR2/systemd does not start with `systemctl --user kill`: {argv}")
    if "SIGUSR2" not in argv or argv[argv.index("SIGUSR2") - 1] != "-s":
        fail(f"SIGUSR2/systemd does not pass the signal via -s SIGUSR2: {argv}")
    if argv[-1] != wb.UNIT_NAME:
        fail(f"SIGUSR2/systemd does not target the unit as the last argument: {argv}")

# 2. systemd path, SIGUSR1 (the --hide toggle's call site): same guarantee,
# since both call sites share _signal_waybar -- the fix must hold for both,
# not just the one the issue happened to reproduce with.
calls = calls_for("SIGUSR1", has_systemd=True)
if not calls or "--kill-who=main" not in calls[0]:
    fail(f"SIGUSR1/systemd does not pass --kill-who=main: {calls}")

# 3. non-systemd path: --kill-who is a systemctl flag and must never leak
# into the pkill fallback, which takes positional signal/uid/name arguments.
calls = calls_for("SIGUSR2", has_systemd=False)
if calls != [["pkill", "-SIGUSR2", "-u", str(os.getuid()), "-x", "waybar"]]:
    fail(f"non-systemd fallback changed shape or gained --kill-who: {calls}")

# 4. a non-signal string is passed through as-is: _signal_waybar does not
# validate its argument, so a caller passing a bad value (a typo'd signal
# name, a bare number) is this test's job to catch if it starts mattering --
# documented here, not silently assumed.
calls = calls_for("not-a-signal", has_systemd=True)
if not calls or "not-a-signal" not in calls[0]:
    fail(f"an arbitrary sig string is not forwarded verbatim: {calls}")

# 5. restart_waybar() must take the reload path (_signal_waybar) only when
# Waybar is already running, and start_waybar() otherwise -- the --kill-who
# fix is pointless if a currently-running check regression made it call the
# wrong branch.
wb.HAS_SYSTEMD = True
with mock.patch.object(wb, "is_waybar_running_for_current_user", return_value=True), \
     mock.patch.object(wb, "_signal_waybar") as signal_mock, \
     mock.patch.object(wb, "run_waybar") as run_mock:
    wb.restart_waybar()
    if signal_mock.call_args != mock.call("SIGUSR2"):
        fail(f"restart_waybar() did not hot-reload via SIGUSR2 while Waybar was running: "
             f"{signal_mock.call_args}")
    if run_mock.called:
        fail("restart_waybar() started a second Waybar although one was already running")

with mock.patch.object(wb, "is_waybar_running_for_current_user", return_value=False), \
     mock.patch.object(wb, "_signal_waybar") as signal_mock, \
     mock.patch.object(wb, "run_waybar") as run_mock:
    wb.restart_waybar()
    if signal_mock.called:
        fail("restart_waybar() signalled a non-running Waybar instead of starting it")
    if not run_mock.called:
        fail("restart_waybar() did not start Waybar when it was not running")

sys.exit(1 if failures else 0)
