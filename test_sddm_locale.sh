#!/usr/bin/env sh
# The bundled SDDM themes must show date and time in the system locale.
#
# Candy and Corners hardcode an English 12h format in theme.conf. HyDE lays a
# patched copy (blank formats, plus a QML fallback for Corners) over the
# extracted theme with sddm.locale.sh. These cases cover the shipped overlay
# and the script's behaviour on missing, malformed and hostile input.

. "$(dirname -- "$0")/lib/common.sh"

overlay_root="$REPO_ROOT/Configs/.local/share/hyde/sddm"
helper="$REPO_ROOT/Configs/.local/lib/hyde/sddm.locale.sh"

if [ ! -x "$helper" ]; then
    fail "sddm.locale.sh is missing or not executable"
    finish
fi

tmp=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# value of KEY in a theme.conf, quotes stripped; empty when the key is absent
conf_value() {
    sed -n "s/^$2=\"\{0,1\}\(.*[^\"]\|\)\"\{0,1\}\$/\1/p" "$1" | head -n 1
}

has_key() {
    grep -q "^$2=" "$1"
}

# ---- the shipped overlay ------------------------------------------------

for key in HourFormat DateFormat; do
    f="$overlay_root/Candy/theme.conf"
    if ! has_key "$f" "$key"; then
        fail "Candy overlay lost the $key key"
    elif [ -n "$(conf_value "$f" "$key")" ]; then
        fail "Candy overlay still hardcodes $key"
    fi
done

for key in TimeFormat DateFormat; do
    f="$overlay_root/Corners/theme.conf"
    if ! has_key "$f" "$key"; then
        fail "Corners overlay lost the $key key"
    elif [ -n "$(conf_value "$f" "$key")" ]; then
        fail "Corners overlay still hardcodes $key"
    fi
done

# A blank format renders as an empty string in Qt, so Corners' QML must map a
# blank (or missing) value to the locale-aware format.
qml="$overlay_root/Corners/components/DateTimePanel.qml"
grep -q 'config.DateFormat ? config.DateFormat : Locale.LongFormat' "$qml" ||
    fail "Corners date has no locale fallback for a blank DateFormat"
grep -q 'config.TimeFormat ? config.TimeFormat : Locale.ShortFormat' "$qml" ||
    fail "Corners time has no locale fallback for a blank TimeFormat"

# The overlay must not drop settings the vendor theme.conf defines: compare
# the key sets against the shipped archives.
if command -v tar >/dev/null 2>&1; then
    for theme in Candy Corners; do
        arc="$REPO_ROOT/Source/arcs/Sddm_$theme.tar.gz"
        [ -f "$arc" ] || continue
        tar -xzOf "$arc" "$theme/theme.conf" 2>/dev/null |
            sed -n 's/^\([A-Za-z0-9_]*\)=.*/\1/p' | sort -u >"$tmp/vendor.keys"
        sed -n 's/^\([A-Za-z0-9_]*\)=.*/\1/p' "$overlay_root/$theme/theme.conf" |
            sort -u >"$tmp/overlay.keys"
        [ -s "$tmp/vendor.keys" ] || {
            fail "could not read the $theme theme.conf from its archive"
            continue
        }
        diff -q "$tmp/vendor.keys" "$tmp/overlay.keys" >/dev/null ||
            fail "$theme overlay theme.conf keys differ from the vendor file"
    done
fi

# ---- sddm.locale.sh -----------------------------------------------------

make_theme() { # <root> <name>: a theme dir holding a stale 12h config
    mkdir -p "$1/$2"
    printf '[General]\nHourFormat="hh:mm A"\nDateFormat="dddd, d of MMMM"\n' >"$1/$2/theme.conf"
    printf 'Rectangle {}\n' >"$1/$2/Main.qml"
}

run_helper() { # <theme dir> [env assignments are inherited]
    HYDE_SDDM_OVERLAY="$overlay_root" sh "$helper" "$1" >/dev/null 2>&1
}

# applies the overlay, leaves unrelated theme files alone
make_theme "$tmp/a" Candy
if ! run_helper "$tmp/a/Candy"; then
    fail "helper failed on a normal Candy theme"
fi
[ -z "$(conf_value "$tmp/a/Candy/theme.conf" HourFormat)" ] ||
    fail "Candy HourFormat was not blanked"
[ -z "$(conf_value "$tmp/a/Candy/theme.conf" DateFormat)" ] ||
    fail "Candy DateFormat was not blanked"
grep -q 'Rectangle' "$tmp/a/Candy/Main.qml" || fail "helper touched an unrelated theme file"

# Corners also gets the QML fallback, inside its components/ subdirectory
make_theme "$tmp/b" Corners
mkdir -p "$tmp/b/Corners/components"
printf 'old\n' >"$tmp/b/Corners/components/DateTimePanel.qml"
run_helper "$tmp/b/Corners" || fail "helper failed on a normal Corners theme"
grep -q 'Locale.ShortFormat' "$tmp/b/Corners/components/DateTimePanel.qml" ||
    fail "Corners DateTimePanel.qml was not replaced"

# idempotent: a second run changes nothing
cp "$tmp/a/Candy/theme.conf" "$tmp/once.conf"
run_helper "$tmp/a/Candy" || fail "second helper run failed"
cmp -s "$tmp/once.conf" "$tmp/a/Candy/theme.conf" || fail "helper is not idempotent"

# a trailing slash on the theme path still resolves the theme name
make_theme "$tmp/c" Candy
run_helper "$tmp/c/Candy/" || fail "helper rejected a trailing slash"
[ -z "$(conf_value "$tmp/c/Candy/theme.conf" HourFormat)" ] ||
    fail "trailing-slash path was not patched"

# a theme without an overlay is left untouched and is not an error
make_theme "$tmp/d" Sugar
cp "$tmp/d/Sugar/theme.conf" "$tmp/sugar.conf"
run_helper "$tmp/d/Sugar" || fail "helper failed on a theme without an overlay"
cmp -s "$tmp/sugar.conf" "$tmp/d/Sugar/theme.conf" || fail "helper modified a theme it has no overlay for"

# missing overlay root: nothing to do, not an error
make_theme "$tmp/e" Candy
HYDE_SDDM_OVERLAY="$tmp/does-not-exist" sh "$helper" "$tmp/e/Candy" >/dev/null 2>&1 ||
    fail "helper failed when the overlay root does not exist"
[ "$(conf_value "$tmp/e/Candy/theme.conf" HourFormat)" = "hh:mm A" ] ||
    fail "helper changed a theme with no overlay root"

# an empty HYDE_SDDM_OVERLAY falls back to the default instead of using ""
make_theme "$tmp/f" Candy
HOME="$tmp/nohome" XDG_DATA_HOME="" HYDE_SDDM_OVERLAY="" sh "$helper" "$tmp/f/Candy" >/dev/null 2>&1 ||
    fail "helper failed with an empty HYDE_SDDM_OVERLAY"

# bad arguments fail loudly instead of copying somewhere unexpected
if sh "$helper" >/dev/null 2>&1; then fail "helper accepted no argument"; fi
if sh "$helper" "" >/dev/null 2>&1; then fail "helper accepted an empty argument"; fi
if sh "$helper" "$tmp/missing" >/dev/null 2>&1; then fail "helper accepted a missing directory"; fi
: >"$tmp/plainfile"
if sh "$helper" "$tmp/plainfile" >/dev/null 2>&1; then fail "helper accepted a regular file"; fi

# theme names that could escape the overlay root, or break quoting, are refused
for bad in 'sp ace' 'semi;colon' '$(x)' 'wild*card'; do
    mkdir -p "$tmp/g/$bad"
    if HYDE_SDDM_OVERLAY="$overlay_root" sh "$helper" "$tmp/g/$bad" >/dev/null 2>&1; then
        fail "helper accepted the theme name '$bad'"
    fi
done
mkdir -p "$tmp/h/sub"
if HYDE_SDDM_OVERLAY="$overlay_root" sh "$helper" "$tmp/h/sub/.." >/dev/null 2>&1; then
    fail "helper accepted a '..' theme directory"
fi

# an unwritable theme directory goes through sudo (stubbed here; skipped as
# root, where permissions are not enforced)
if [ "$(id -u)" -ne 0 ]; then
    make_theme "$tmp/i" Candy
    mkdir -p "$tmp/bin"
    printf '#!/bin/sh\necho called >> "%s/sudo.log"\nexec "$@"\n' "$tmp" >"$tmp/bin/sudo"
    chmod +x "$tmp/bin/sudo"
    chmod a-w "$tmp/i/Candy"
    PATH="$tmp/bin:$PATH" HYDE_SDDM_OVERLAY="$overlay_root" sh "$helper" "$tmp/i/Candy" >/dev/null 2>&1 || :
    chmod u+w "$tmp/i/Candy"
    [ -f "$tmp/sudo.log" ] || fail "an unwritable theme directory did not fall back to sudo"
fi

# ---- wiring -------------------------------------------------------------

grep -q 'sddm.locale.sh' "$REPO_ROOT/Scripts/install_pst.sh" ||
    fail "install_pst.sh does not apply the SDDM locale overlay"
grep -q 'sddm.locale.sh' "$REPO_ROOT/Configs/.local/lib/hyde/theme.patch.sh" ||
    fail "theme.patch.sh does not apply the SDDM locale overlay"

printf '    SDDM locale overlay checked\n'
finish
