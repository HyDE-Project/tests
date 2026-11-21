#!/usr/bin/env bash
# mediaplayer.py is the only script in Configs/.local/lib/hyde that imports
# `gi` (PyGObject) directly. PyGObject is declared only under the optional
# "wayland" extra in pyproject.toml, so the managed uv venv
# (include-system-site-packages = false) does not have it unless something
# pulls it in first -- every other optional-dependency consumer in this repo
# (e.g. amdgpu.py + pyamdgpuinfo/"amd") goes through python_env.v_import()
# for exactly this reason, which auto-installs the extra on first use instead
# of crashing. A bare `import gi` before that call reintroduces the
# ModuleNotFoundError reported in #1552 (reproduced live: `hyde-shell
# mediaplayer --player spotify`, the exact invocation custom-spotify.jsonc
# uses, crashed with "No module named 'gi'" while `hyde-shell mediaplayer.py`
# happened to work by accident -- that invocation bypasses the venv entirely
# and runs the file directly via its shebang, picking up the system Python).

. "$(dirname -- "$0")/lib/common.sh"

script="$REPO_ROOT/Configs/.local/lib/hyde/mediaplayer.py"

if [ ! -f "$script" ]; then
    fail "mediaplayer.py not found at $script"
    finish
fi

python3 - "$script" <<'EOF'
import ast
import sys

path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)

v_import_line = None
bare_import_line = None

for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        is_v_import = (
            (isinstance(func, ast.Attribute) and func.attr == "v_import")
            or (isinstance(func, ast.Name) and func.id == "v_import")
        )
        if is_v_import and any(
            isinstance(arg, ast.Constant) and arg.value == "gi" for arg in node.args
        ):
            v_import_line = node.lineno
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name == "gi" and bare_import_line is None:
                bare_import_line = node.lineno

if bare_import_line is None:
    print("no `import gi` found at all -- test is stale, update it")
    sys.exit(1)
if v_import_line is None:
    print("no python_env.v_import(\"gi\", ...) call found before `import gi`")
    sys.exit(1)
if v_import_line >= bare_import_line:
    print(f"v_import(\"gi\") at line {v_import_line} does not run before "
          f"`import gi` at line {bare_import_line}")
    sys.exit(1)
EOF

if [ $? -ne 0 ]; then
    fail "mediaplayer.py imports gi without going through python_env.v_import first (#1552 regression)"
fi

finish
