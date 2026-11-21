"""Integration check: run_waybar()'s systemd-run fallback must survive a
unit that failed on its previous run.

Without --collect, a transient unit that lands in `failed` (e.g.
start-limit-hit) keeps its name until it is manually `reset-failed` or
garbage-collected later, so the next systemd-run with the same --unit name
is rejected ("Unit ... was already loaded or has a fragment file"),
and waybar never comes back (HyDE-Project/HyDE#2160).

This drives the real systemd --user manager (swapping the "waybar" argv
for "false"/"true" so nothing waybar-specific has to exist), not a mock,
because the thing under test is systemd's own unit-collection behaviour.
Skips (exit 0) where no user session is reachable, e.g. a container-based
CI runner.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys
import time

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LIB = REPO_ROOT / "Configs/.local/lib/hyde"

try:
    running = subprocess.run(
        ["systemctl", "--user", "is-system-running"],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip()
except Exception:
    running = ""
if running not in ("running", "degraded"):
    print(f"skip: no reachable systemd --user session (saw {running!r})")
    sys.exit(0)

sys.path.insert(0, str(LIB))
spec = importlib.util.spec_from_file_location("waybar_under_test", LIB / "waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

failures = 0


def fail(msg: str) -> None:
    global failures
    failures += 1
    print(f"FAIL: {msg}", file=sys.stderr)


unit = f"hyde-test-collect-{os.getpid()}.service"
wb.UNIT_NAME = unit
wb.is_waybar_running_for_current_user = lambda: False

real_run = subprocess.run
payloads = ["false", "true"]  # first launch fails fast, second must succeed
systemd_run_results = []


def tap(cmd, *a, **k):
    if cmd[:3] == ["systemctl", "--user", "start"]:
        class FailedStart:
            returncode = 1
        return FailedStart()
    if cmd and cmd[0] == "systemd-run":
        payload = payloads.pop(0)
        cmd = [payload if c == "waybar" else c for c in cmd]
        result = real_run(cmd, capture_output=True, text=True)
        systemd_run_results.append(result)
        return result
    return real_run(cmd, *a, **k)


wb.subprocess.run = tap

try:
    wb.run_waybar()  # launches "false" under `unit`; systemd marks it failed
    if systemd_run_results[-1].returncode != 0:
        fail(f"first systemd-run (the one meant to fail) didn't even launch: {systemd_run_results[-1].stderr}")

    # Wait for a terminal state, not just "not activating anymore": Type=exec
    # reports "active" the instant the payload starts, before it has actually
    # exited and failed. Proceeding on "active" races the real --collect
    # behaviour under test, not just the bar it stands in for.
    terminal_states = {"failed", "inactive"}
    state = ""
    for _ in range(100):
        state = real_run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True).stdout.strip()
        if state in terminal_states:
            break
        time.sleep(0.1)
    else:
        fail(f"unit {unit} did not reach a terminal state within 10s (stuck at {state!r})")

    wb.run_waybar()  # same `unit` name again, while the failed one may still be loaded
    recreate = systemd_run_results[-1]
    if recreate.returncode != 0:
        fail(
            "run_waybar() could not recreate the unit after a prior failure "
            f"(missing --collect?): {recreate.stderr.strip()}"
        )
finally:
    real_run(["systemctl", "--user", "reset-failed", unit], capture_output=True)

sys.exit(1 if failures else 0)
