local root = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
package.path = root .. "../../Configs/.local/lib/hyde/?.lua;" .. package.path
local lact = require("lact")
local json = require("luautils.json")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("    fail: " .. message)
    end
end

local work_dir = os.getenv("LACT_TEST_WORK_DIR") or os.getenv("GPUINFO_TEST_WORK_DIR")
assert(work_dir, "LACT_TEST_WORK_DIR must be set by the test wrapper")

-- format_temperature: locale-independent when a fahrenheit flag is passed
-- explicitly (real usage lets it fall back to `locale -k LC_MEASUREMENT`,
-- which these unit tests must not depend on).
check(lact.format_temperature(0, true) == "32°F", "Fahrenheit conversion was incorrect")
check(lact.format_temperature(100, false) == "100°C", "Celsius formatting was incorrect")
check(lact.format_temperature(nil) == "–", "a nil temperature did not render as a dash")
check(lact.format_temperature("[N/A]") == "–", "a literal [N/A] string did not render as a dash")
check(lact.format_temperature("not-a-number", false) == "not-a-number", "a non-numeric string should pass through unchanged")

-- map_floor: same threshold-selection contract as gpuinfo.lua's version.
check(lact.map_floor("85:hot, 45:mid, cold", 90) == "hot", "map_floor did not pick the highest cleared threshold")
check(lact.map_floor("85:hot, 45:mid, cold", 50) == "mid", "map_floor did not pick the middle threshold")
check(lact.map_floor("85:hot, 45:mid, cold", 0) == "cold", "map_floor did not fall back to the default")
check(lact.map_floor("85:hot, 45:mid, cold", nil) == "cold", "map_floor did not degrade a nil value to the default")

-- parse_lact_output: never raises, always returns a list.
check(#lact.parse_lact_output("") == 0, "empty output did not degrade to zero devices")
check(#lact.parse_lact_output("not json at all") == 0, "garbage output did not degrade to zero devices")
check(#lact.parse_lact_output("null") == 0, "a JSON null did not degrade to zero devices")
check(#lact.parse_lact_output('{"devices": "not-a-list"}') == 0, "a non-list devices field did not degrade to zero devices")
check(#lact.parse_lact_output('{"no_devices_key": true}') == 0, "a missing devices key did not degrade to zero devices")
local mixed = lact.parse_lact_output('{"devices": [{"primary_gpu": "Real GPU"}, "garbage", 42, null]}')
check(#mixed == 1 and mixed[1].primary_gpu == "Real GPU", "a devices list with non-table entries mixed in was not filtered down to the real device(s)")

-- generate_json: zero devices must still be valid, well-formed JSON.
local empty_json = lact.generate_json({})
local ok0, decoded0 = pcall(json.decode, empty_json)
check(ok0, "generate_json with zero devices did not produce valid JSON")
check(ok0 and decoded0.text:find("–", 1, true) ~= nil, "zero devices did not render as a dash in the bar text")
-- HyDE#2096 review: the module is labelled as GPU monitoring with the
-- md-expansion_card glyph (U+F08AE), not with the daemon's name.
check(ok0 and decoded0.tooltip:sub(1, #"\u{f08ae} GPU") == "\u{f08ae} GPU", "the tooltip does not start with the GPU icon and label")
check(ok0 and decoded0.text:sub(1, #"\u{f08ae}") == "\u{f08ae}", "the bar text does not start with the GPU icon")
check(ok0 and not decoded0.tooltip:find("LACT", 1, true), "the tooltip header still says LACT")
-- HyDE#2096 review: the 🧪 marker and the German "Testphase" label are gone.
check(ok0 and not (decoded0.text .. decoded0.tooltip):find("🧪", 1, true), "the removed 🧪 test marker is back")
check(ok0 and not decoded0.tooltip:find("Testphase", 1, true), "the removed German \"Testphase\" label is back")

-- generate_json: nil/non-table devices argument must degrade the same way,
-- not raise.
local ok_nil, nil_json = pcall(lact.generate_json, nil)
check(ok_nil, "generate_json(nil) raised instead of degrading to zero devices")
local ok0b, decoded0b = pcall(json.decode, ok_nil and nil_json or "")
check(ok0b and decoded0b.percentage == 0, "generate_json(nil) did not produce the zero-device percentage")

-- generate_json: one fully-populated device.
local full = lact.generate_json({
    {
        primary_gpu = "Radeon RX 7800",
        vendor = "AMD",
        family = "RDNA3",
        temperature = 62,
        utilization = 45,
        current_clock_speed = 1800,
        max_clock_speed = 2600,
        power_usage = 180,
        power_limit = 250,
    },
})
local ok1, decoded1 = pcall(json.decode, full)
check(ok1, "generate_json with a full field set did not produce valid JSON")
check(ok1 and decoded1.tooltip:find("AMD RDNA3 Radeon RX 7800", 1, true) ~= nil, "vendor/family/name were not combined in the tooltip label")
check(ok1 and decoded1.tooltip:find("1800 / 2600 MHz", 1, true) ~= nil, "clock speed segment was missing/wrong")
check(ok1 and decoded1.tooltip:find("180 / 250 W", 1, true) ~= nil, "power usage segment was missing/wrong")
-- 62°C is normal GPU operating temperature under the recalibrated scale
-- (see the TEMP_COLOR_BANDS comment): it must stay uncolored, not just
-- "any color".
check(ok1 and not decoded1.text:find("<span", 1, true), "62°C (normal GPU load) should not be colorized")
check(ok1 and decoded1.tooltip:sub(1, #"\u{f08ae} GPU\n\n") == "\u{f08ae} GPU\n\n", "the GPU header is missing above the device blocks")
check(ok1 and decoded1.percentage == 62, "percentage did not reflect the single device's temperature")

-- A genuinely hot reading (above the recalibrated "normal" band) must be
-- colorized -- this is the whole point of per-GPU inline Pango coloring.
local hot = lact.generate_json({{primary_gpu = "Toasty GPU", temperature = 90}})
local okh, decodedh = pcall(json.decode, hot)
check(okh, "generate_json for a hot GPU did not produce valid JSON")
check(okh and decodedh.text:find("<span color=", 1, true) ~= nil, "a 90°C GPU (hot under the recalibrated scale) was not colorized")

-- generate_json: missing fields on an otherwise real device must render as
-- a dash, not raise or produce "nil"/"N/A" text (HyDE#2096 review).
local sparse = lact.generate_json({{primary_gpu = "Bare GPU"}})
local ok2, decoded2 = pcall(json.decode, sparse)
check(ok2, "generate_json with a mostly-empty device did not produce valid JSON")
check(ok2 and decoded2.tooltip:find("Temperature: –", 1, true) ~= nil, "a missing temperature was not rendered as a dash")
check(ok2 and decoded2.tooltip:find("Utilization: –", 1, true) ~= nil, "a missing utilization was not rendered as a dash")
check(ok2 and decoded2.tooltip:find("Clock Speed: – / – MHz", 1, true) ~= nil, "missing clocks were not rendered as dashes")
check(ok2 and decoded2.tooltip:find("Power Usage: – / – W", 1, true) ~= nil, "missing power values were not rendered as dashes")
check(ok2 and not decoded2.tooltip:find("N/A", 1, true), "N/A leaked into the tooltip instead of a dash")
check(ok2 and not decoded2.text:find("<span", 1, true), "a device with no real temperature should not be colorized")

-- generate_json: daemon-supplied strings (vendor/family/name) are rendered
-- as Pango markup by Waybar (custom/lact.jsonc doesn't set "escape": true),
-- so raw '<', '>' and '&' must come out as literal entities, not markup.
local hostile = lact.generate_json({
    {primary_gpu = "AMD & Co <Test>", vendor = "Ry<zen>", family = "RDNA & 3", temperature = 50},
})
local ok3, decoded3 = pcall(json.decode, hostile)
check(ok3, "generate_json with special-character device strings did not produce valid JSON")
check(
    ok3 and decoded3.tooltip:find("Ry&lt;zen&gt; RDNA &amp; 3 AMD &amp; Co &lt;Test&gt;", 1, true) ~= nil,
    "special characters in vendor/family/name were not pango-escaped: " .. tostring(ok3 and decoded3.tooltip)
)
check(
    ok3 and not decoded3.tooltip:find("<Test>", 1, true) and not decoded3.tooltip:find("<zen>", 1, true),
    "raw angle brackets from daemon strings leaked into the tooltip unescaped"
)

-- generate_json: out-of-spec numeric input (negative, absurdly high,
-- non-numeric string) must clamp/degrade instead of raising or producing an
-- invalid percentage.
local bad_ok, bad_json = pcall(lact.generate_json, {
    {primary_gpu = "Glitchy GPU", temperature = -50, utilization = "[N/A]"},
})
check(bad_ok, "a negative temperature raised instead of clamping")
local ok3, decoded3 = pcall(json.decode, bad_ok and bad_json or "")
check(ok3 and decoded3.percentage == 0, "a negative temperature was not clamped to 0%%: got " .. tostring(ok3 and decoded3.percentage))

local huge_ok, huge_json = pcall(lact.generate_json, {
    {primary_gpu = "Absurd GPU", temperature = 999999},
})
check(huge_ok, "an absurdly high temperature raised instead of clamping")
local ok4, decoded4 = pcall(json.decode, huge_ok and huge_json or "")
check(ok4 and decoded4.percentage == 100, "an absurd temperature was not clamped to 100%%: got " .. tostring(ok4 and decoded4.percentage))

local nonnum_ok = pcall(lact.generate_json, {
    {primary_gpu = "Stringy GPU", temperature = "not-a-number"},
})
check(nonnum_ok, "a non-numeric temperature string raised instead of degrading to N/A")

-- generate_json: multiple GPUs are combined, not toggled between -- the
-- 2026-09-13 "combined display" decision this module exists to implement.
local multi = lact.generate_json({
    {primary_gpu = "Hot GPU", temperature = 90},
    {primary_gpu = "Cool GPU", temperature = 35},
})
local ok5, decoded5 = pcall(json.decode, multi)
check(ok5, "generate_json with multiple devices did not produce valid JSON")
check(ok5 and decoded5.text:find("/", 1, true) ~= nil, "multiple GPUs were not joined with a separator in the bar text")
local span_count = 0
if ok5 then
    local _, count = decoded5.text:gsub("<span color=", "")
    span_count = count
end
-- Only the hot GPU is colored: below 75°C the text keeps the theme color
-- (HyDE#2096 review: the former cold blue was unreadable on dark themes).
check(span_count == 1, "only the hot GPU should carry a color span in a multi-GPU bar, got " .. tostring(span_count))
check(ok5 and not decoded5.text:find("#4169e1", 1, true), "the removed cold blue is back")
check(ok5 and decoded5.tooltip:find("Hot GPU", 1, true) ~= nil and decoded5.tooltip:find("Cool GPU", 1, true) ~= nil, "both GPUs' names were not present in the tooltip")
check(ok5 and decoded5.percentage == 90, "the hottest GPU should drive the overall percentage/class bucket, got " .. tostring(ok5 and decoded5.percentage))

-- HyDE#2096 review/NVIDIA test: every sensor gets its own tooltip line with
-- the thermometer icon, the bar keeps the one main reading, power is whole
-- watts, a stopped fan says so, and the critical red is readable on dark
-- themes (not the former #8b0000).
local sensors = lact.generate_json({
    {
        primary_gpu = "RTX 2070",
        temperature = 37,
        temperatures = {
            {label = "GPU", value = 37.0},
            {label = "GPU Hotspot", value = 53.0},
            {label = "VRAM", value = 96.0},
            {label = "Broken", value = "garbage"},
        },
        power_usage = 60.014,
        power_limit = 175.0,
        fan_speed = 0,
    },
})
local ok8, decoded8 = pcall(json.decode, sensors)
check(ok8, "generate_json with several temperature sensors did not produce valid JSON")
check(ok8 and decoded8.text == "\u{f08ae} 37°C", "the bar did not show just the main temperature: " .. tostring(ok8 and decoded8.text))
check(ok8 and decoded8.tooltip:find("\u{f050f} GPU: 37°C\n\u{f050f} GPU Hotspot: 53°C\n\u{f050f} VRAM: <span color='#ff2020'>96°C</span>", 1, true) ~= nil,
    "the sensors were not listed one per line with icon and color: " .. tostring(ok8 and decoded8.tooltip))
check(ok8 and not decoded8.tooltip:find("Broken", 1, true), "a sensor with a non-numeric value was rendered")
check(ok8 and not decoded8.tooltip:find("Temperature:", 1, true), "the generic Temperature line was shown although sensors were listed")
check(ok8 and decoded8.tooltip:find("Power Usage: 60 / 175 W", 1, true) ~= nil, "power was not rounded to whole watts")
check(ok8 and decoded8.tooltip:find("Fan Speed: 0 RPM (stopped)", 1, true) ~= nil, "a stopped fan was not labelled as stopped")
check(ok8 and not decoded8.tooltip:find("#8b0000", 1, true), "the removed dark red is back")
check(ok1 and decoded1.tooltip:find("Temperature: 62°C", 1, true) ~= nil, "a device without a sensor list lost its Temperature line")

-- generate_json: a garbage (non-table) entry inside an otherwise valid
-- devices list must be skipped, not crash the whole render.
local garbage_ok, garbage_json = pcall(lact.generate_json, {
    {primary_gpu = "Real GPU", temperature = 50},
    "not-a-device-table",
})
check(garbage_ok, "a non-table device entry raised instead of being skipped")
local ok6 = garbage_ok and pcall(json.decode, garbage_json)
check(ok6, "a devices list with a garbage entry mixed in did not produce valid JSON")

-- cli_main end to end: a call with a fixed lact_output produces exactly
-- one JSON line.
local lines = {}
local code = lact.cli_main({}, {
    print_fn = function(s) lines[#lines + 1] = s end,
    lact_output = '{"devices":[{"primary_gpu":"Test GPU","temperature":55}]}',
})
check(code == 0, "a normal cli_main call did not return 0")
check(#lines == 1, "cli_main printed something other than exactly one line: " .. tostring(#lines))
local ok7 = pcall(json.decode, lines[1] or "")
check(ok7, "cli_main's single printed line was not valid JSON")

-- HyDE#2096 review: the --emoji/--reset click actions (and their state
-- file) were dropped, so they are now just unknown flags.
check(lact.state_path == nil, "the removed state-file helpers are back")

-- An unrecognized flag must warn, not crash the render.
local warn_lines = {}
local unknown_ok = pcall(lact.cli_main, {"--bogus"}, {
    print_fn = function() end,
    warn_fn = function(s) warn_lines[#warn_lines + 1] = s end,
    lact_output = "{}",
})
check(unknown_ok, "an unrecognized CLI flag raised instead of warning and continuing")
check(#warn_lines > 0, "an unrecognized CLI flag was silently ignored instead of warned about")

os.exit(failures == 0 and 0 or 1)
