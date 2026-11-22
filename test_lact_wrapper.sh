#!/usr/bin/env sh
# Checks lact.lua's standalone formatting/parsing logic: malformed, missing,
# negative, and out-of-range LACT daemon values must all degrade to valid
# Waybar JSON instead of crashing the module.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v lua >/dev/null 2>&1; then
    skip "lua is not installed"
    finish
fi

# lact.lua only exists on HyDE-Project/HyDE#2096, not yet merged to dev, so a
# checkout of dev has no module for this spec to load (HyDE-Project/tests#5).
# Same gap test_shader_default.sh already guards against for its own module.
lact_module="$REPO_ROOT/Configs/.local/lib/hyde/lact.lua"
[ -f "$lact_module" ] || {
    skip "lact.lua is not in this checkout yet (HyDE-Project/HyDE#2096)"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# Own XDG_RUNTIME_DIR so nothing the module might write lands on the real
# machine, same approach test_gpuinfo_lua_e2e.sh uses for gpuinfo.lua.
mkdir -p "$work_dir/runtime"
LACT_TEST_WORK_DIR="$work_dir" XDG_RUNTIME_DIR="$work_dir/runtime" \
    lua "$TESTS_DIR/lua/lact_spec.lua" || fail "lact_spec reported defects"

# lact_gpuinfo.py's max clock per vendor table (HyDE-Project/HyDE#2096
# review). The Intel answer is lactd's real device_clocks_info reply for a
# Kaby Lake HD 620, which has no gpu_clock_range and used to show "N/A".
if command -v python3 >/dev/null 2>&1; then
    python3 - "$REPO_ROOT/Configs/.local/lib/hyde" <<'PY' || fail "lact_gpuinfo.py did not read the max clock or power from the vendor's reply"
import sys
sys.path.insert(0, sys.argv[1])
import lact_gpuinfo as g

def fields_for(table, **top):
    replies = {"device_info": {}, "device_stats": {}, "device_clocks_info": {"table": table, **top}}
    g.optional_request = lambda payload: replies[payload["command"]]
    return g.device_fields("id", "GPU")

intel = {"type": "intel", "value": {"gt_freq": [300, 1000], "rpn_freq": 300, "rpe_freq": 300, "rp0_freq": 1000}}
nvidia = {"type": "nvidia", "value": {"gpu_clock_range": [210, 2100]}}
assert fields_for(intel)["max_clock_speed"] == 1000, fields_for(intel)
assert fields_for(nvidia)["max_clock_speed"] == 2100, fields_for(nvidia)
# AMD: lactd reports the maximum as top-level max_sclk, not in the table.
assert fields_for({"type": "amd", "value": {}}, max_sclk=2615)["max_clock_speed"] == 2615
assert fields_for(nvidia, max_sclk=999)["max_clock_speed"] == 2100
assert fields_for({})["max_clock_speed"] is None

# Power: instantaneous first, hwmon's average only when that is missing.
def power_for(power):
    replies = {"device_info": {}, "device_stats": {"power": power}, "device_clocks_info": {}}
    g.optional_request = lambda payload: replies[payload["command"]]
    return g.device_fields("id", "GPU")["power_usage"]

assert power_for({"average": 45.0}) == 45.0
assert power_for({"current": 0.0, "average": 45.0}) == 0.0
assert power_for({"current": 60.0, "average": 45.0}) == 60.0
assert power_for({}) is None
PY

    # Which temperature the bar shows: lactd's real RTX 2070 answer marks
    # GPU, GPU Hotspot and VRAM all "primary"; only GPU is not display_only.
    # Listed here with Hotspot first so the old "first primary wins" logic
    # would pick the wrong one (HyDE-Project/HyDE#2096 NVIDIA test).
    python3 - "$REPO_ROOT/Configs/.local/lib/hyde" <<'PY' || fail "lact_gpuinfo.py picked the wrong main temperature or dropped sensors"
import sys
sys.path.insert(0, sys.argv[1])
import lact_gpuinfo as g

temps = {
    "GPU Hotspot": {"current": 53.0, "primary": True, "display_only": True},
    "GPU": {"current": 37.0, "primary": True, "display_only": False},
    "VRAM": {"current": 53.0, "primary": True, "display_only": True},
    "Broken": {"current": None, "primary": True, "display_only": False},
}
replies = {"device_info": {}, "device_stats": {"temps": temps}, "device_clocks_info": {}}
g.optional_request = lambda payload: replies[payload["command"]]
fields = g.device_fields("id", "GPU")
assert fields["temperature"] == 37.0, fields
assert [t["label"] for t in fields["temperatures"]] == ["GPU", "GPU Hotspot", "VRAM"], fields

replies["device_stats"] = {"temps": {"edge": {"current": 41.0}}}
assert g.device_fields("id", "GPU")["temperature"] == 41.0

replies["device_stats"] = {}
fields = g.device_fields("id", "GPU")
assert fields["temperature"] is None and fields["temperatures"] == [], fields
PY
fi

finish
