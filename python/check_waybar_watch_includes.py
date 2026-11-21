"""--watch must generate the CSS includes that defaults.css imports.

Session autostart runs `waybar.py --watch` and nothing else. On a clean
install ~/.config/waybar/includes held no border-radius.css or global.css, so
the @imports in defaults.css failed, waybar exited 1 and systemd stopped
restarting it (HyDE-Project/HyDE#2160).
"""

from __future__ import annotations

import atexit
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", ".")).resolve()
LIB = REPO_ROOT / "Configs/.local/lib/hyde"

failures = 0


def fail(msg: str) -> None:
    global failures
    failures += 1
    print(f"FAIL: {msg}", file=sys.stderr)


work = pathlib.Path(tempfile.mkdtemp(prefix="waybar_watch_"))
atexit.register(shutil.rmtree, work, ignore_errors=True)
for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                 ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "run"), ("HOME", "home")):
    (work / sub).mkdir()
    os.environ[var] = str(work / sub)
os.environ.pop("WAYBAR_BORDER_RADIUS", None)
sys.path.insert(0, str(LIB))

spec = importlib.util.spec_from_file_location("waybar_under_test", LIB / "waybar.py")
wb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wb)

wb.is_waybar_running_for_current_user = lambda: False
launched = []
wb.subprocess.run = lambda cmd, *a, **k: launched.append(cmd)
wb.HAS_SYSTEMD = True

# The templates a deployed install has under $XDG_DATA_HOME.
template_dir = work / "data/waybar/includes"
template_dir.mkdir(parents=True)
shutil.copy(REPO_ROOT / "Configs/.local/share/waybar/includes/border-radius.css", template_dir)

includes = work / "config/waybar/includes"
css = (includes / "border-radius.css", includes / "global.css")


def reset(preexisting: bool = False) -> None:
    shutil.rmtree(includes, ignore_errors=True)
    launched.clear()
    if preexisting:
        includes.mkdir(parents=True)
        for f in css:
            f.write_text("/* user */\n")


# 1. clean install: both imported files exist before waybar is launched
reset()
wb.watch_waybar()
for f in css:
    if not f.is_file():
        fail(f"watch_waybar() left {f.name} missing")
if not launched:
    fail("watch_waybar() did not launch waybar")
# --collect lets systemd unload the unit immediately on start-limit-hit, so
# the next watch_waybar()/run_waybar() can recreate it under the same name
# (HyDE-Project/HyDE#2160 comment on the stuck `failed` unit).
elif "--collect" not in launched[-1]:
    fail("watch_waybar() launched waybar without --collect")

# 2. waybar already running: nothing is touched and nothing is launched
reset()
wb.is_waybar_running_for_current_user = lambda: True
wb.watch_waybar()
if includes.exists() or launched:
    fail("watch_waybar() acted although waybar is already running")
wb.is_waybar_running_for_current_user = lambda: False

# 3. repeated start keeps working and keeps existing files valid
reset(preexisting=True)
wb.watch_waybar()
wb.watch_waybar()
for f in css:
    if not f.is_file() or not f.read_text().strip():
        fail(f"{f.name} empty or missing after repeated watch_waybar()")

# 4. garbage radius from the environment must not stop the launch
reset()
os.environ["WAYBAR_BORDER_RADIUS"] = "not-a-number"
try:
    wb.watch_waybar()
except Exception as e:  # noqa: BLE001
    fail(f"watch_waybar() raised on a malformed border radius: {e!r}")
if not launched:
    fail("watch_waybar() skipped the launch on a malformed border radius")

# 5. radius boundaries and wrong types: always launches, and the value that is
#    written is a usable pt size (valid numbers applied, everything else falls
#    back to a positive default)
import re  # noqa: E402

wb.get_value_from_hypr_theme = lambda *a, **k: None
wb.HYPRLAND.HyprctlWrapper.getoption = staticmethod(lambda *a, **k: (_ for _ in ()).throw(OSError("no ipc")))
for raw, expected in (("8", 8), ("", 2), ("0", 2), ("-5", 2), ("8.5", 2), (" 8 ", 8), ("1", 1),
                      ("999999", 999999), ("0x10", 2), ("١٢", 12)):
    reset()
    os.environ["WAYBAR_BORDER_RADIUS"] = raw
    try:
        wb.watch_waybar()
    except Exception as e:  # noqa: BLE001
        fail(f"watch_waybar() raised for WAYBAR_BORDER_RADIUS={raw!r}: {e!r}")
        continue
    if not launched:
        fail(f"no launch for WAYBAR_BORDER_RADIUS={raw!r}")
    sizes = set(re.findall(r"(\d+)pt", css[0].read_text())) if css[0].is_file() else set()
    if sizes != {str(expected)}:
        fail(f"WAYBAR_BORDER_RADIUS={raw!r}: border-radius.css uses {sorted(sizes)}, expected {expected}pt")
os.environ.pop("WAYBAR_BORDER_RADIUS", None)

# 6. a corrupt includes.json from an older run must not block the launch
for junk in ("", "{not json", "[]", "null", '{"include": 5}'):
    reset(preexisting=True)
    (includes / "includes.json").write_text(junk)
    try:
        wb.watch_waybar()
    except Exception as e:  # noqa: BLE001
        fail(f"watch_waybar() raised on includes.json={junk!r}: {e!r}")
        continue
    if not launched:
        fail(f"no launch with includes.json={junk!r}")

# 7. no border-radius template anywhere: global.css is still written and
#    waybar is still launched
saved = wb.INCLUDES_DIRS
wb.INCLUDES_DIRS = []
reset()
try:
    wb.watch_waybar()
except Exception as e:  # noqa: BLE001
    fail(f"watch_waybar() raised without a border-radius template: {e!r}")
if not launched:
    fail("no launch without a border-radius template")
if not (includes / "global.css").is_file():
    fail("global.css missing when the border-radius template is absent")
# the imported file must still exist (a missing @import kills Waybar), and a
# later run with the template present must regenerate it properly
if not (includes / "border-radius.css").is_file():
    fail("border-radius.css missing when its template is absent; defaults.css import would fail")
wb.INCLUDES_DIRS = saved
os.environ["WAYBAR_BORDER_RADIUS"] = "6"
wb.watch_waybar()
if "6pt" not in (includes / "border-radius.css").read_text():
    fail("a stub border-radius.css was not replaced once the template reappeared")
os.environ.pop("WAYBAR_BORDER_RADIUS", None)
wb.INCLUDES_DIRS = saved

# 8. files that are not valid UTF-8 (includes.json, border-radius.css) are
#    replaced or tolerated, never fatal
reset(preexisting=True)
(includes / "includes.json").write_bytes(b"\xff\xfe{\x80")
css[0].write_bytes(b"\xff\xfe garbage \x80")
try:
    wb.watch_waybar()
except Exception as e:  # noqa: BLE001
    fail(f"watch_waybar() raised on non-UTF-8 includes: {e!r}")
if not launched:
    fail("no launch with non-UTF-8 includes")
if "pt" not in css[0].read_text(encoding="utf-8", errors="replace"):
    fail("a non-UTF-8 border-radius.css was not replaced from the template")

# 9. an unwritable includes directory must not block the launch (skipped as
#    root, which ignores permissions)
if os.geteuid() != 0:
    reset(preexisting=True)
    (includes / "includes.json").write_text("{}")
    for f in (*css, includes / "includes.json"):
        f.chmod(0o400)
    includes.chmod(0o500)
    try:
        wb.watch_waybar()
    except Exception as e:  # noqa: BLE001
        fail(f"watch_waybar() raised in a read-only includes directory: {e!r}")
    if not launched:
        fail("no launch in a read-only includes directory")
    includes.chmod(0o700)

# 10. run_waybar()'s systemd-run fallback (used by restart_waybar(), i.e.
# `hyde-shell reload` / `waybar --update`) must also --collect, or a unit
# stuck `failed` from a prior start-limit-hit blocks the recreate with
# "Unit already exists" (HyDE-Project/HyDE#2160).
class _FailedStart:
    returncode = 1


launched.clear()
wb.subprocess.run = lambda cmd, *a, **k: (launched.append(cmd), _FailedStart())[1]
wb.run_waybar()
if not launched or "--collect" not in launched[-1]:
    fail("run_waybar()'s systemd-run fallback is missing --collect")

sys.exit(1 if failures else 0)
