-- Run with: REPO_ROOT=/path/to/HyDE sh tests/run.sh staterc
-- test_staterc.sh sets XDG_STATE_HOME to a private directory, LIB_DIR to the
-- checkout and LUA_CPATH to wherever lfs lives before starting this.
--
-- staterc_set() rewrote staterc with io.open(path, "w"), unlocked, next to
-- waybar.py and set_conf() doing the same (HyDE-Project/HyDE#2194). It now
-- goes through staterc.sh: locked, atomic, escaped, and it refuses a key
-- that is not a shell variable name.
local lib = assert(os.getenv('REPO_ROOT'), 'REPO_ROOT is not set') .. '/Configs/.local/lib/hyde/'
package.path = lib .. '?.lua;' .. lib .. '?/init.lua;' .. package.path
local state = require('luautils.global.state')

local staterc = assert(os.getenv('XDG_STATE_HOME'), 'XDG_STATE_HOME is not set') .. '/hyde/staterc'
local failures = 0
local function fail(msg)
    failures = failures + 1
    io.stderr:write('FAIL: ' .. msg .. '\n')
end
local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local value = f:read('*a'); f:close(); return value
end

-- 1. fresh install: no hyde/ directory yet
os.remove(staterc)
state.staterc_set('HYPR_SHADER', 'disable')
if state.staterc_get('HYPR_SHADER') ~= 'disable' then fail('fresh install: staterc_get does not return the value') end
if read(staterc) ~= 'HYPR_SHADER="disable"\n' then fail('fresh install content: ' .. tostring(read(staterc))) end

-- 2. a value with a quote, slash, ampersand and backslash comes back unchanged
local value = [[it's a/b&c\d]]
state.staterc_set('K', value)
if state.staterc_get('K') ~= value then fail('literal value: got ' .. tostring(state.staterc_get('K'))) end

-- 3. a key that is not a shell variable name is refused, file untouched
local before = read(staterc)
local ok = pcall(state.staterc_set, '1bad', 'v')
if ok then fail('staterc_set accepted the key 1bad') end
if read(staterc) ~= before then fail('a refused key changed staterc') end

-- 4. staterc.sh escapes \ " $ and the backtick so `source` runs nothing
-- (HyDE-Project/HyDE#2197); staterc_get undoes it
local pwned = os.tmpname(); os.remove(pwned)
local values = { 'a"b', '$(touch ' .. pwned .. ')', '`touch ' .. pwned .. '`',
    [[a\b]], [[\]], [[a\]], '"', '$HOME', [[x\$y]], '' }
for _, v in ipairs(values) do
    state.staterc_set('K', v)
    local got = state.staterc_get('K')
    if got ~= v then fail('escaped value ' .. v .. ': got ' .. tostring(got)) end
end
if pcall(state.staterc_set, 'K', 'a\nb') then fail('staterc_set accepted a value with a newline') end

-- 5. a line written by an older HyDE, with a raw backslash, reads as `source` reads it
local function write(path, text)
    local f = assert(io.open(path, 'w')); f:write(text); f:close()
end
write(staterc, 'K="back\\slash"\n')
if state.staterc_get('K') ~= [[back\slash]] then fail('old raw line: got ' .. tostring(state.staterc_get('K'))) end

-- 6. an unquoted line (older waybar.py) reads back as it is
write(staterc, 'K=plain\n')
if state.staterc_get('K') ~= 'plain' then fail('unquoted line: got ' .. tostring(state.staterc_get('K'))) end

if failures > 0 then os.exit(1) end
