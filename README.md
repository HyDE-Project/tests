# Tests

Structural checks over the shipped configuration and scripts. They read the
tree, never the machine: no Hyprland session, no installed HyDE, nothing
outside the repository is touched.

## Running

```sh
sh tests/run.sh          # every case
sh tests/run.sh binds    # only cases whose name contains "binds"
```

Each case is an executable `tests/test_*.sh` that prints its own diagnostics
and exits non-zero on failure. `tests/run.sh` discovers them, so adding a case
is adding a file.

## Cases

| Case | Checks |
| --- | --- |
| `test_app_wrapper.sh` | Launching through either `app.sh` execution path does not leak an unrelated non-boolean `DEBUG` value into app2unit or xdg-terminal-exec |
| `test_binds.sh` | Loads the Lua keybinds against a stubbed Hyprland API: no two binds share a combination once modifiers are folded to what Hyprland matches on, no keysym sits in a modifier position, no bind uses the `code:NN` form the Lua parser rejects, every bind has a description, every `hyde-shell` command it runs exists. Touchpad gestures are checked in the same pass: a valid finger count, a direction and action Hyprland accepts, and no two gestures on the same finger count and direction |
| `test_git.sh` | The tree holds no gitlink without a matching `.gitmodules` entry, which would break `git submodule` and anything walking submodules |
| `test_dots.sh` | Every installer metafile under `Scripts/dots` parses, declares the keys the installer needs, uses a known action, and declares a usable `source` where it has one. A local entry's `source_root` and its non-glob paths have to exist inside the checkout; an entry backed by a remote `source` is exempt from those checks, since its files come from an archive the installer downloads, but its path types are still checked. It also keeps Grimblast on the fixed official source |
| `test_shaders.sh` | Shader consent, preview coalescing, cancellation and rollback; rejects unknown/empty names, invalid hooks and compositor values; sanitizes menu metadata and preserves state on file/IPC failures |
| `test_rofi_pos.sh` | Cursor-follow menu fit and overflow on both axes, exact-fit and midpoint boundaries, oversized windows, margins, reserved areas, scaling, rotation and missing compositor data |
| `test_lua_syntax.sh` | Every shipped Lua file parses |
| `test_schema.sh` | Generated schema artifacts use the current Lua battery notification daemon rather than the removed shell implementation |
| `test_screenshot_wrapper.sh` | Satty receives a compatible default GTK renderer while preserving explicit renderer overrides |
| `test_shell.sh` | Every shipped shell script parses, and shellcheck finds no error-severity problem |
| `test_colour_pass.sh` | The functions the colour state depends on are executed against stubs. The wallpaper hand-off runs the colour pass before it returns, links the generated thumbnails only after it succeeds, reports a failed pass and a failed thumbnail cache under their own statuses and with their output, and does not reach the colour pass once caching failed. Those two statuses stop a theme switch; a backend that only failed to paint does not. The template renderer writes a plain target, leaves a discard target untouched, refuses a target it cannot write and says so, skips a template whose dependency directory is absent, and leaves no temporary behind |
| `test_theme_state.sh` | The generated theme colour state is produced in every mode. The shared helpers are executed against private homes: the state directories are created, the configuration flavour is taken from the deployed entry point when no session names one, the completeness probe reads what that flavour consumes, and both helpers reach child processes. The call sites are read as well: the colour pass runs in the foreground with its result checked, every hand-off carries its status outwards rather than flattening it, session start skips the pass only on a complete state, the theme switch generates the state and fails loudly when it cannot, a discard target is not written onto, template failures are counted rather than dropped, and the installer neither hides a failed theme switch nor finishes green after one |
| `test_rofi_selector.sh` | The generic rofi dmenu selector's follow-cursor overflow estimate is read from the resolved theme's own `.rasi` window size, with a safe fallback to the shared dropdown themes' 23em x 30em window when the file is missing, empty, or only partially declares its size; an explicit `min_width_em`/`min_height_em` override still wins |
| `test_waybar_actions.sh` | Every clickable Waybar menu item has a `menu-actions` entry in each module using that menu, and every command the shipped modules and layouts run is sound: shell syntax, no redirect into a numbered file, `hyde-shell app` with `--`, known `hyde-shell` subcommands, no positional arguments `argparse.sh` would ignore, and wallpaper changes with `--global` |
| `test_lockscreen_select.sh` | `lockscreen --select` hands over to a wrapper that offers a layout selector and otherwise fails clearly, never starting a lock; covers missing and selector-less wrappers, the short flag, an empty override, a lockscreen command with arguments and combined `--get`/`--select` |
| `test_getopt_long_options.sh` | Every long option a shipped caller (Lua keybinds through the dispatcher map, Waybar configs, scripts) passes to a getopt shell script or argparse Python script is spelled out exactly, since both accept unambiguous abbreviations |
| `test_libinput_gestures.sh` | `libinput-gestures.conf` parsed the way libinput-gestures runs it (split, no shell): no HyDE script called by filename, no legacy `hyprctl dispatch`, no shell operator or trailing comment outside `sh -c`, and only known `hyde-shell` subcommands |
| `test_schema_commands.sh` | Every command quoted in the config schema runs through `hyde-shell`, resolves to a script and passes only arguments that script declares, and the generated schema files quote the same commands |

## Dependencies

| Tool | Used by | Missing |
| --- | --- | --- |
| `lua`, `luac` | bind and Lua syntax checks | case is skipped |
| Lua 5.3+ with `lfs`, `socket`, `argparse`, `dkjson` | shader behavior checks | missing modules fail the case |
| `python3` 3.11+ | metafile check | case is skipped |
| `shellcheck` | shell check | only the parse half runs |

A skipped case is reported as such and does not fail the run, so the suite
stays usable on a machine without the full toolchain. CI installs everything,
so nothing is skipped there.

The shader and rofi position regression cases target HyDE-Project/HyDE#2113.
To test a separate HyDE checkout, run
`REPO_ROOT=/path/to/HyDE sh /path/to/tests/run.sh`.
On Debian/Ubuntu, the shader modules are provided by `lua-filesystem`,
`lua-socket`, `lua-argparse`, and `lua-dkjson`; install them for the Lua
interpreter used by the runner.
