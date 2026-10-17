#!/usr/bin/env bash
##
# Wallpaper daemons never hold a caller's output open.
#
# The installer runs `theme.switch.sh -q`, which used to capture wallpaper.sh
# with "$(...)". A substitution only returns once every process holding its
# pipe has exited, and on a fresh install the backend starts its daemon in the
# background, so the daemon inherited the pipe and the installer froze for
# good after printing the theme status (HyDE-Project/HyDE#2156).
#
# Each backend that starts a daemon is run for real against stubs, inside a
# substitution as theme.switch.sh did. The stub daemons record where their
# stdout and stderr point and then stay alive for a while: one still on the
# capture pipe fails the case, and so does a capture that only returned once
# the daemon went away. The quiet branch of theme.switch.sh is then run
# against a backend that leaves such a process behind on purpose, so a future
# backend with the same mistake cannot freeze the installer either.
##

. "$(dirname -- "$0")/lib/common.sh"

lib_dir="$REPO_ROOT/Configs/.local/lib/hyde"
global_control="$lib_dir/globalcontrol.sh"
theme_switch="$lib_dir/theme.switch.sh"

for required in "$global_control" "$theme_switch"; do
    [ -f "$required" ] || {
        fail "missing ${required#"$REPO_ROOT"/}"
        finish
    }
done

[ -d /proc/self/fd ] || {
    skip "no /proc/self/fd to read a daemon's descriptors from"
    finish
}

# How long a stub daemon stays alive, and how long a capture may take before
# it counts as waiting on one. The hyprpaper backend sleeps 1s by itself.
hold=6
limit=4

work_dir=$(mktemp -d)
cleanup() {
    local pid_file
    for pid_file in "$work_dir"/pids/*; do
        [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null
    done
    rm -rf "$work_dir"
}
trap cleanup EXIT

home="$work_dir/home"
bin="$work_dir/bin"
mkdir -p "$home/.config" "$home/.local/share" "$home/.cache" \
    "$home/.local/state/hyde" "$home/run" "$bin" "$work_dir/fds" "$work_dir/pids"
wall="$work_dir/wall.png"
: >"$wall"

##
# Writes a stub daemon that records its stdout and stderr, marks itself as
# up, and stays alive for $hold seconds holding whatever it inherited.
#
# Arguments:
#   $1  command name of the stub
##
stub_daemon() {
    cat >"$bin/$1" <<STUB
#!/bin/sh
printf 'fd1=%s\nfd2=%s\n' "\$(readlink /proc/\$\$/fd/1)" "\$(readlink /proc/\$\$/fd/2)" >"$work_dir/fds/$1"
printf '%s\n' "\$\$" >"$work_dir/pids/$1"
: >"$work_dir/$1.up"
exec sleep $hold
STUB
    chmod +x "$bin/$1"
}

##
# Writes a stub wallpaper client whose `query` only succeeds once its daemon
# is up, like awww and swww.
#
# Arguments:
#   $1  command name of the client
#   $2  command name of its daemon
##
stub_client() {
    cat >"$bin/$1" <<STUB
#!/bin/sh
[ "\$1" = query ] && { [ -e "$work_dir/$2.up" ]; exit \$?; }
exit 0
STUB
    chmod +x "$bin/$1"
}

stub_daemon awww-daemon
stub_daemon swww-daemon
stub_daemon hyprpaper
stub_client awww awww-daemon
stub_client swww swww-daemon

cat >"$bin/waydeeper" <<STUB
#!/bin/sh
[ "\$1" = daemon ] && exec "$bin/waydeeper-daemon"
exit 0
STUB
stub_daemon waydeeper-daemon

# Nothing else is under test: the compositor, notifications, the systemd
# user manager (so hyprpaper falls back to starting itself) and app.sh.
printf '#!/bin/sh\nexit 0\n' >"$bin/hyprctl"
printf '#!/bin/sh\nexit 0\n' >"$bin/notify-send"
printf '#!/bin/sh\nexit 0\n' >"$bin/app.sh"
printf '#!/bin/sh\nexit 1\n' >"$bin/systemctl"
printf '#!/bin/sh\n[ "$1" = init ] && printf "%%s\\n" ". %q"\n' "$global_control" >"$bin/hyde-shell"
chmod +x "$bin/waydeeper" "$bin/hyprctl" "$bin/notify-send" "$bin/app.sh" "$bin/systemctl" "$bin/hyde-shell"

for backend in awww:awww-daemon swww:swww-daemon hyprpaper:hyprpaper waydeeper:waydeeper-daemon; do
    name=${backend%%:*}
    daemon=${backend#*:}
    script="$lib_dir/wallpaper.$name.sh"
    [ -f "$script" ] || {
        fail "missing ${script#"$REPO_ROOT"/}"
        continue
    }

    started=$SECONDS
    output=$(env -i HOME="$home" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_DATA_HOME="$home/.local/share" \
        XDG_CACHE_HOME="$home/.cache" \
        XDG_STATE_HOME="$home/.local/state" \
        XDG_RUNTIME_DIR="$home/run" \
        PATH="$bin:/usr/bin:/bin" \
        bash "$script" "$wall" 2>&1)
    elapsed=$((SECONDS - started))

    # A detached daemon may not have recorded itself yet when the backend
    # returns.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$work_dir/fds/$daemon" ] && break
        sleep 0.2
    done
    if [ ! -f "$work_dir/fds/$daemon" ]; then
        fail "wallpaper.$name.sh never started $daemon, so the case checked nothing: $output"
        continue
    fi
    case "$(cat "$work_dir/fds/$daemon")" in
    *pipe:*) fail "wallpaper.$name.sh starts $daemon on the caller's output, so \"\$(wallpaper.sh ...)\" waits for the daemon to exit: $(tr '\n' ' ' <"$work_dir/fds/$daemon")" ;;
    esac
    [ "$elapsed" -lt "$limit" ] ||
        fail "capturing wallpaper.$name.sh took ${elapsed}s, it waited for $daemon instead of returning"
done

# The quiet branch of theme.switch.sh, against a backend that leaves a process
# holding its output behind, exits with a painting failure and says so.
stand="$work_dir/switch"
mkdir -p "$stand/lib/hyde"
cat >"$stand/lib/hyde/wallpaper.sh" <<STUB
#!/bin/sh
sleep $hold &
printf '%s\n' "\$!" >"$work_dir/pids/leaky-backend"
printf 'painted\n'
printf 'backend noise on stderr\n' >&2
exit 2
STUB
chmod +x "$stand/lib/hyde/wallpaper.sh"

quiet_branch=$(sed -n '/^if \[ "\$quiet" = true \]; then$/,/^fi$/p' "$theme_switch")
case "$quiet_branch" in
*wallpaper.sh*) ;;
*)
    fail "the quiet wallpaper call was not found in theme.switch.sh"
    finish
    ;;
esac

cat >"$stand/run.sh" <<STAND
#!/usr/bin/env bash
LIB_DIR="$stand/lib"
quiet=true
theme_wallpaper="$wall"
wallpaper_status=0
$quiet_branch
printf 'status=%s\n' "\$wallpaper_status"
printf 'output=%s\n' "\$wallpaper_output"
STAND

started=$SECONDS
output_switch=$(bash "$stand/run.sh" 2>&1)
elapsed=$((SECONDS - started))

[ "$elapsed" -lt "$limit" ] ||
    fail "the quiet theme switch took ${elapsed}s, it waited for a process the backend left running instead of returning"
case "$output_switch" in
*'status=2'*) ;;
*) fail "the backend's exit status was not carried out of the quiet theme switch: $output_switch" ;;
esac
case "$output_switch" in
*painted*'backend noise on stderr'*) ;;
*) fail "the quiet theme switch lost the backend's output, which is printed when it fails: $output_switch" ;;
esac

finish
