"""waybar.py must never treat its own layout backups as layouts.

backup_layout() copies config.jsonc into layouts/backup/ inside a layout
directory, and find_layout_files() used to walk into it. "backup/..." sorts
before most layout names, so the fallbacks that take layouts[0] or match
config.jsonc by hash could settle on a backup, and --next/--prev, which cycle
only real layouts, then crashed with "ValueError: '.../backup/unknown_...' is
not in list" (HyDE-Project/HyDE#2133). A backup can also legitimately be the
current layout (applied from the backup menu); navigation has to cope with
that too.
"""

from __future__ import annotations

import atexit
import importlib.util
import os
import shutil
import pathlib
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


work = pathlib.Path(tempfile.mkdtemp(prefix="waybar_nav_"))
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

cfg_layouts = work / "config/waybar/layouts"
data_layouts = work / "data/waybar/layouts"
backup_dir = cfg_layouts / "backup"


def write(path: pathlib.Path, text: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return str(path)


def reset(state: str | None = None, config: str | None = None) -> None:
    for d in (cfg_layouts, data_layouts):
        if d.exists():
            for p in sorted(d.rglob("*"), reverse=True):
                p.unlink() if p.is_file() else p.rmdir()
    wb.STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    wb.STATE_FILE.write_text(state or "")
    if config is None:
        wb.CONFIG_JSONC.unlink(missing_ok=True)
    else:
        write(wb.CONFIG_JSONC, config)


applied: list[str] = []
wb.set_layout = lambda layout: applied.append(layout)


def navigate(option: str) -> str | None:
    applied.clear()
    try:
        wb.handle_layout_navigation(option)
    except Exception as exc:  # the regression: ValueError out of .index()
        fail(f"{option} raised {type(exc).__name__}: {exc}")
        return None
    return applied[-1] if applied else None


# 1. discovery: backups are not layouts, unless explicitly asked for
reset()
a = write(data_layouts / "alpha.jsonc", '{"a":1}')
z = write(data_layouts / "zeta.jsonc", '{"z":1}')
nested = write(data_layouts / "themes/mid.jsonc", '{"m":1}')
bak = write(backup_dir / "unknown_20260918_205145.jsonc", '{"old":1}')
# only a directory named exactly "backup" is skipped
write(cfg_layouts / "backups/kept.jsonc", '{"k":1}')
kept = str(cfg_layouts / "backups/kept.jsonc")
found = wb.find_layout_files()
if bak in found:
    fail("find_layout_files() returned a backup")
for want in (a, z, nested, kept):
    if want not in found:
        fail(f"find_layout_files() lost {want}")
try:
    with_backups = wb.find_layout_files(include_backups=True)
except TypeError:
    with_backups = []
if bak not in with_backups:
    fail("find_layout_files(include_backups=True) dropped the backup")
listing = wb.list_layouts()
if [b["layout"] for b in listing["backups"]] != [bak]:
    fail(f"list_layouts() backups: {listing['backups']}")
if any(entry["layout"] == bak for entry in listing["layouts"]):
    fail("list_layouts() shows the backup as a normal layout")

# 2. the reported case: state points at a backup, --next/--prev must not crash
for option, expect in (("--next", "first"), ("--prev", "last")):
    reset(state=f"WAYBAR_LAYOUT_PATH={bak}\n")
    a = write(data_layouts / "alpha.jsonc", '{"a":1}')
    z = write(data_layouts / "zeta.jsonc", '{"z":1}')
    write(backup_dir / "unknown_20260918_205145.jsonc", '{"old":1}')
    got = navigate(option)
    want = a if expect == "first" else z
    if got != want:
        fail(f"state on a backup, {option}: applied {got}, expected {want}")

# 3. normal cycling still works, including wrap-around
reset(state=f"WAYBAR_LAYOUT_PATH={data_layouts / 'zeta.jsonc'}\n")
a = write(data_layouts / "alpha.jsonc", '{"a":1}')
z = write(data_layouts / "zeta.jsonc", '{"z":1}')
if navigate("--next") != a:
    fail("--next from the last layout does not wrap to the first")
if navigate("--prev") != a:
    fail("--prev from zeta does not go to alpha")

# 4. no state and a config.jsonc that matches only a backup: the fallback must
# pick a real layout, not the backup whose content it matches
reset(config='{"old":1}')
a = write(data_layouts / "alpha.jsonc", '{"a":1}')
bak = write(backup_dir / "aaa_20260101_000000.jsonc", '{"old":1}')
current = wb.get_current_layout_from_config()
if current == bak or "/backup/" in str(current):
    fail(f"get_current_layout_from_config() settled on a backup: {current}")
if "/backup/" in (wb.get_state_value("WAYBAR_LAYOUT_PATH") or ""):
    fail("state file now points at a backup")

# 5. no layouts at all (only a backup): navigation logs, does not crash
reset(state=f"WAYBAR_LAYOUT_PATH={backup_dir / 'x.jsonc'}\n")
write(backup_dir / "x.jsonc", "{}")
if navigate("--next") is not None:
    fail("--next applied something with no layouts")

# 6. state file without a layout entry: logs, does not crash
reset(state="WAYBAR_STYLE_PATH=/nowhere.css\n")
write(data_layouts / "alpha.jsonc", '{"a":1}')
navigate("--next")

# 7. a layout path containing "=" stays whole when read back from the state
reset()
a = write(data_layouts / "alpha.jsonc", '{"a":1}')
eq = write(data_layouts / "x=y/eq.jsonc", '{"e":1}')
z = write(data_layouts / "zeta.jsonc", '{"z":1}')
wb.STATE_FILE.write_text(f"WAYBAR_LAYOUT_PATH={eq}\n")
if navigate("--next") != z:
    fail("--next from a layout whose path contains '=' did not go to the next layout")

# 8. an empty WAYBAR_LAYOUT_PATH value: logs, applies nothing, no crash
reset(state="WAYBAR_LAYOUT_PATH=\n")
write(data_layouts / "alpha.jsonc", '{"a":1}')
if navigate("--next") is not None:
    fail("--next applied a layout from an empty state value")

# 9. no state file at all: logs, no crash (used to raise FileNotFoundError)
reset()
write(data_layouts / "alpha.jsonc", '{"a":1}')
wb.STATE_FILE.unlink()
navigate("--next")

# 10. only a "backup" directory below the layout root counts
root = work / "backup" / "home" / "layouts"  # the root itself sits under backup/
for path, expected in (
    (root / "a.jsonc", False),
    (root / "backup.jsonc", False),          # a file named backup
    (root / "backups" / "b.jsonc", False),   # a similar directory name
    (root / "Backup" / "c.jsonc", False),    # case matters, as for the walk
    (root / "backup" / "d.jsonc", True),
    (root / "themes" / "backup" / "e.jsonc", True),
):
    if getattr(wb, "in_backup_dir", lambda *_: None)(str(path), str(root)) != expected:
        fail(f"in_backup_dir({path.relative_to(work)}) is not {expected}")

# 11. a home that itself lies under a directory named backup: its layouts are
# still layouts, and navigation works
saved_dirs = wb.LAYOUT_DIRS
wb.LAYOUT_DIRS = [str(root)]
try:
    reset()
    ra = write(root / "alpha.jsonc", '{"a":1}')
    rz = write(root / "zeta.jsonc", '{"z":1}')
    rb = write(root / "backup" / "old.jsonc", '{"o":1}')
    listing = wb.list_layouts()
    names = sorted(e["layout"] for e in listing["layouts"] if not e.get("is_backup_entry"))
    if names != [ra, rz]:
        fail(f"layouts under a backup-named parent: {names}")
    if [b["layout"] for b in listing["backups"]] != [rb]:
        fail(f"backups under a backup-named parent: {listing['backups']}")
    wb.STATE_FILE.write_text(f"WAYBAR_LAYOUT_PATH={ra}\n")
    if navigate("--next") != rz:
        fail("--next under a backup-named parent did not reach zeta")
finally:
    wb.LAYOUT_DIRS = saved_dirs

# 12. no layouts and no state at all: the error names the missing layouts,
# not the state file
errors: list[str] = []
saved_error = wb.logger.error
wb.logger.error = lambda msg, *a, **k: errors.append(str(msg))
try:
    reset()
    wb.STATE_FILE.unlink()
    navigate("--next")
finally:
    wb.logger.error = saved_error
if not any("No layouts found" in e for e in errors):
    fail(f"no layouts and no state: logged {errors}, expected 'No layouts found'")

# 13. the saved layout is gone but config.jsonc still matches a real layout:
# that layout is the current one, so --next goes to the one after it, not
# back to the first
reset(config='{"m":1}')
a = write(data_layouts / "alpha.jsonc", '{"a":1}')
m = write(data_layouts / "mid.jsonc", '{"m":1}')
z = write(data_layouts / "zeta.jsonc", '{"z":1}')
wb.STATE_FILE.write_text(f"WAYBAR_LAYOUT_PATH={data_layouts / 'deleted.jsonc'}\n")
if navigate("--next") != z:
    fail("saved layout gone, config matches mid: --next did not go to zeta")

sys.exit(1 if failures else 0)
