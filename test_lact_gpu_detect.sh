#!/usr/bin/env sh
# install.sh only offers LACT (and honors --lact) when lact_gpu_supported()
# finds a GPU lactd can actually report on: an NVIDIA card, or any GPU whose
# driver exposes a hwmon temperature sensor. A machine with just an Intel
# iGPU without one (Kaby Lake HD 620) got a module full of dashes
# (HyDE-Project/HyDE#2096 review).

. "$(dirname -- "$0")/lib/common.sh"

grep -q '^lact_gpu_supported()' "$REPO_ROOT/Scripts/global_fn.sh" || {
    skip "lact_gpu_supported is not in this checkout yet (HyDE-Project/HyDE#2096)"
    finish
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# Fake /sys/class/drm: card<N>/device/vendor plus optional hwmon temp sensor.
make_card() { # root card vendor with_temp
    mkdir -p "$1/$2/device"
    printf '%s\n' "$3" >"$1/$2/device/vendor"
    if [ "$4" = yes ]; then
        mkdir -p "$1/$2/device/hwmon/hwmon3"
        printf '45000\n' >"$1/$2/device/hwmon/hwmon3/temp1_input"
    fi
}

# nvidia_detect reads the host's real lspci; stub it so the result depends
# only on the fake sysfs, plus FAKE_LSPCI_NVIDIA for the "lspci sees an
# NVIDIA card no driver has bound yet" case (#2096 CodeRabbit review).
supported() { # drm root [lspci_nvidia] -> exit status of lact_gpu_supported
    LACT_DRM_ROOT="$1" FAKE_LSPCI_NVIDIA="${2:-}" bash -c '
        print_log() { :; }
        . "$REPO_ROOT/Scripts/global_fn.sh" >/dev/null 2>&1
        nvidia_detect() { [ -n "$FAKE_LSPCI_NVIDIA" ]; }
        lact_gpu_supported'
}

make_card "$work_dir/intel_igpu" card1 0x8086 no
# Connector entries share the card prefix and have no vendor file.
mkdir -p "$work_dir/intel_igpu/card1-eDP-1"
supported "$work_dir/intel_igpu" && fail "an Intel iGPU without a temperature sensor was treated as supported"

make_card "$work_dir/amd" card0 0x1002 yes
supported "$work_dir/amd" || fail "an AMD GPU with a hwmon temperature sensor was not treated as supported"

make_card "$work_dir/nvidia" card0 0x10de no
supported "$work_dir/nvidia" || fail "an NVIDIA GPU was not treated as supported"

make_card "$work_dir/hybrid" card1 0x8086 no
make_card "$work_dir/hybrid" card0 0x10de no
supported "$work_dir/hybrid" || fail "Intel iGPU + NVIDIA dGPU was not treated as supported"

mkdir -p "$work_dir/empty"
supported "$work_dir/empty" && fail "a machine with no DRM cards was treated as supported"
supported "$work_dir/empty" yes || fail "an NVIDIA GPU seen by lspci but not bound to a driver yet was not treated as supported"

finish
