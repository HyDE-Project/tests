"""waybar.py must write staterc under the shared lock, and atomically.

set_state_value() read staterc and rewrote it with open(..., "w"), unlocked.
A writer that read it during that truncation saw an empty file and wrote
back only its own key, so two layout switches at once wiped staterc down to
one line (HyDE-Project/HyDE#2194). Now waybar.py takes the same flock on
staterc.lock as staterc.sh (set_conf, Lua) and replaces the file with a
rename.

This covers: a fresh install, duplicate keys, Python and bash writers
running at the same time losing nothing, a failed replace leaving staterc
intact, ensure_state_file() not deadlocking on the lock it reaches through
get_current_layout_from_config(), and the file's mode being kept.
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
import threading
from unittest import mock

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LIB = REPO_ROOT / "Configs/.local/lib/hyde"
HELPER = LIB / "staterc.sh"

failures = 0


def fail(msg: str) -> None:
    global failures
    failures += 1
    print(f"FAIL: {msg}", file=sys.stderr)


work = pathlib.Path(tempfile.mkdtemp(prefix="staterc_waybar_"))
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

state_dir = wb.STATE_FILE.parent

# A separate interpreter per writer, so the lock is exercised across processes.
PY_WRITER = """
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("wb", sys.argv[1] + "/waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)
wb.set_state_value(sys.argv[2], sys.argv[3])
"""


def reset(content: str | None) -> None:
    shutil.rmtree(state_dir, ignore_errors=True)
    if content is not None:
        state_dir.mkdir(parents=True)
        wb.STATE_FILE.write_text(content)


def leftovers() -> list[str]:
    return sorted(p.name for p in state_dir.glob(".staterc.*")) if state_dir.exists() else []


# 1. fresh install: no hyde/ directory yet
reset(None)
wb.set_state_value("A", "1")
if not wb.STATE_FILE.exists() or wb.STATE_FILE.read_text() != "A=1\n":
    fail(f"fresh install: {wb.STATE_FILE.read_text() if wb.STATE_FILE.exists() else 'no file'!r}")

# 2. a key present twice ends up once, other keys kept
reset('A=1\nB="2"\nA=3\n')
wb.set_state_value("A", "2")
lines = wb.STATE_FILE.read_text().splitlines()
if lines.count("A=2") != 1 or any(l.startswith("A=") and l != "A=2" for l in lines) or 'B="2"' not in lines:
    fail(f"duplicate key: {lines}")

# 3. Python and bash writers at the same time lose nothing
reset("".join(f'S{i}="s{i}"\n' for i in range(8)))
procs = []
for i in range(20):
    procs.append(subprocess.Popen([sys.executable, "-I", "-c", PY_WRITER, str(LIB), f"P{i}", f"v{i}"],
                                  env=os.environ.copy()))
    procs.append(subprocess.Popen(["bash", str(HELPER), "set", f"B{i}", f"v{i}"], env=os.environ.copy()))
for p in procs:
    p.wait(timeout=60)
text = wb.STATE_FILE.read_text().splitlines()
missing = ([f"S{i}" for i in range(8) if f'S{i}="s{i}"' not in text]
           + [f"P{i}" for i in range(20) if f"P{i}=v{i}" not in text]
           + [f"B{i}" for i in range(20) if f'B{i}="v{i}"' not in text])
if missing:
    fail(f"concurrent writers lost {len(missing)} key(s): {missing}")
if leftovers():
    fail(f"temp files left after concurrent writes: {leftovers()}")

# 4. a failed replace raises and leaves staterc as it was
reset('A="1"\nB="2"\n')
with mock.patch.object(wb.os, "replace", side_effect=OSError("disk full")):
    try:
        wb.set_state_value("A", "9")
        fail("set_state_value() swallowed a failed replace")
    except OSError:
        pass
if wb.STATE_FILE.read_text() != 'A="1"\nB="2"\n':
    fail(f"staterc changed by a failed replace: {wb.STATE_FILE.read_text()!r}")
if leftovers():
    fail(f"temp files left after a failed replace: {leftovers()}")

# 5. ensure_state_file() reaches set_state_value() through
# get_current_layout_from_config(); it must not hold the lock around that.
reset(None)


def current_layout():
    wb.set_state_value("WAYBAR_LAYOUT_PATH", "/x/a.jsonc")
    return "/x/a.jsonc"


with mock.patch.object(wb, "get_current_layout_from_config", side_effect=current_layout), \
     mock.patch.object(wb, "resolve_style_path", return_value="/x/a.css"):
    runner = threading.Thread(target=wb.ensure_state_file, daemon=True)
    runner.start()
    runner.join(2)
if runner.is_alive():
    fail("ensure_state_file() is still running after 2s (deadlocked on the staterc lock?)")
else:
    got = wb.STATE_FILE.read_text().splitlines() if wb.STATE_FILE.exists() else []
    for want in ("WAYBAR_LAYOUT_PATH=/x/a.jsonc", "WAYBAR_LAYOUT_NAME=a", "WAYBAR_STYLE_PATH=/x/a.css"):
        if got.count(want) != 1:
            fail(f"ensure_state_file() on a missing file: {want} not there exactly once in {got}")

# 6. an existing file keeps its mode
reset("A=1\n")
wb.STATE_FILE.chmod(0o600)
wb.set_state_value("A", "2")
if stat.S_IMODE(wb.STATE_FILE.stat().st_mode) != 0o600:
    fail(f"staterc mode changed to {oct(stat.S_IMODE(wb.STATE_FILE.stat().st_mode))}")

sys.exit(1 if failures else 0)
