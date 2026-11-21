"""waybar.py's search directories must all be absolute.

The system entries of MODULE_DIRS, LAYOUT_DIRS and INCLUDES_DIRS were built
as os.path.join("usr", "share", ...), without a leading "/". They resolved
against the current directory, so system-wide layouts, modules and includes
were never found, and a ./usr/share/waybar tree in whatever directory
waybar.py ran from was read instead.
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

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LIB = REPO_ROOT / "Configs/.local/lib/hyde"

failures = 0


def fail(msg: str) -> None:
    global failures
    failures += 1
    print(f"FAIL: {msg}", file=sys.stderr)


work = pathlib.Path(tempfile.mkdtemp(prefix="waybar_dirs_"))
atexit.register(shutil.rmtree, work, ignore_errors=True)
for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                 ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "run"), ("HOME", "home")):
    (work / sub).mkdir()
    os.environ[var] = str(work / sub)
# A relative XDG value is invalid per the spec; the default (absolute) must win.
os.environ["XDG_DATA_HOME"] = "relative/data"
bindir = work / "bin"
bindir.mkdir()
(bindir / "waybar").write_text("#!/bin/sh\nexit 0\n")
(bindir / "waybar").chmod(stat.S_IRWXU)
os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}"
sys.path.insert(0, str(LIB))

# Import from a directory holding a decoy ./usr/share/waybar tree.
decoy = work / "cwd"
for kind in ("layouts", "modules", "includes"):
    for prefix in ("usr/share", "usr/local/share"):
        (decoy / prefix / "waybar" / kind).mkdir(parents=True)
(decoy / "usr/share/waybar/layouts/decoy.jsonc").write_text("{}")
(decoy / "usr/local/share/waybar/layouts/decoy-local.jsonc").write_text("{}")
os.chdir(decoy)

spec = importlib.util.spec_from_file_location("waybar_under_test", LIB / "waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

lists = {name: getattr(wb, name) for name in ("MODULE_DIRS", "LAYOUT_DIRS", "INCLUDES_DIRS", "STYLE_DIRS")}

# 1. every search directory is absolute, including with a relative XDG value
for name, dirs in lists.items():
    if not dirs:
        fail(f"{name} is empty")
    for d in dirs:
        if not os.path.isabs(d):
            fail(f"{name} has a relative entry: {d}")

# 2. the system entries point at /usr/local/share and /usr/share, in that order
for name, kind in (("MODULE_DIRS", "modules"), ("LAYOUT_DIRS", "layouts"), ("INCLUDES_DIRS", "includes")):
    expected = [f"/usr/local/share/waybar/{kind}", f"/usr/share/waybar/{kind}"]
    system = [d for d in lists[name] if d.startswith("/usr/")]
    if system != expected:
        fail(f"{name} system entries {system}, expected {expected}")

# 3. the decoy tree in the current directory is never read
found = wb.find_layout_files()
for decoy_file in ("decoy.jsonc", "decoy-local.jsonc"):
    if any(pathlib.Path(f).name == decoy_file for f in found):
        fail(f"find_layout_files() read {decoy_file} from the current directory")

# 4. the user's own layouts are still found next to the system entries
user_layout = pathlib.Path(wb.LAYOUT_DIRS[0]) / "mine.jsonc"
user_layout.parent.mkdir(parents=True, exist_ok=True)
user_layout.write_text("{}")
if str(user_layout) not in wb.find_layout_files():
    fail("find_layout_files() lost a layout in the user's config directory")

sys.exit(1 if failures else 0)
