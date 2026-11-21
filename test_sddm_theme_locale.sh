#!/usr/bin/env sh
# The bundled SDDM themes must show date and time in the system locale.
#
# Candy and Corners used to hardcode an English 12h format in theme.conf, so a
# 24h locale still got "05:05 PM" on the login screen. The formats are blank
# now; Candy's Clock.qml and Corners' DateTimePanel.qml fall back to Qt's
# locale-aware formats for a blank value. Qt renders a blank format as an
# empty string, so a Corners without that fallback would show no clock at all.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v tar >/dev/null 2>&1; then
    skip "tar is not installed"
    finish
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# value of KEY in a theme.conf with the quotes stripped; empty when the key is
# blank or absent (has_key tells the two apart)
conf_value() {
    sed -n "s/^$2=\"\{0,1\}\(.*[^\"]\|\)\"\{0,1\}\$/\1/p" "$1" | head -n 1
}

has_key() {
    grep -q "^$2=" "$1"
}

check_theme() { # <theme> <format keys...>
    theme=$1
    shift
    arc="$REPO_ROOT/Source/arcs/Sddm_$theme.tar.gz"

    if [ ! -f "$arc" ]; then
        fail "$arc is missing"
        return
    fi

    mkdir -p "$tmp/$theme"
    if ! tar -xzf "$arc" -C "$tmp/$theme" 2>/dev/null; then
        fail "$theme archive does not extract"
        return
    fi

    # theme.patch.sh and install_pst.sh both assume exactly one top-level
    # directory named after the theme
    top=$(tar -tzf "$arc" | cut -d/ -f1 | sort -u)
    [ "$top" = "$theme" ] || fail "$theme archive top level is '$top', expected '$theme'"

    conf="$tmp/$theme/$theme/theme.conf"
    if [ ! -f "$conf" ]; then
        fail "$theme archive has no theme.conf"
        return
    fi

    for key in "$@"; do
        if ! has_key "$conf" "$key"; then
            fail "$theme theme.conf lost the $key key"
        elif [ -n "$(conf_value "$conf" "$key")" ]; then
            fail "$theme theme.conf still hardcodes $key=$(conf_value "$conf" "$key")"
        fi
    done

    # No 12h token may survive in any format value, whatever the key is called
    if grep -Eqi '^[A-Za-z]*(Time|Hour|Date)Format="[^"]+"' "$conf"; then
        fail "$theme theme.conf still sets a time or date format: $(grep -Ei '^[A-Za-z]*(Time|Hour|Date)Format="[^"]+"' "$conf" | tr '\n' ' ')"
    fi

    # the files HyDE itself relies on must still be shipped
    for f in Main.qml the_hyde_project.conf; do
        [ -f "$tmp/$theme/$theme/$f" ] || fail "$theme archive lost $f"
    done
}

check_theme Candy HourFormat DateFormat
check_theme Corners TimeFormat DateFormat

# Candy: a blank value must reach Locale.ShortFormat / LongFormat
candy_qml="$tmp/Candy/Candy/Components/Clock.qml"
if [ -f "$candy_qml" ]; then
    grep -q 'Locale.ShortFormat' "$candy_qml" || fail "Candy Clock.qml has no ShortFormat fallback"
    grep -q 'Locale.LongFormat' "$candy_qml" || fail "Candy Clock.qml has no LongFormat fallback"
else
    fail "Candy archive has no Components/Clock.qml"
fi

# Corners: blank or missing config must not reach toLocale*String as-is
corners_qml="$tmp/Corners/Corners/components/DateTimePanel.qml"
if [ -f "$corners_qml" ]; then
    grep -q 'config.DateFormat ? config.DateFormat : Locale.LongFormat' "$corners_qml" ||
        fail "Corners date has no locale fallback for a blank DateFormat"
    grep -q 'config.TimeFormat ? config.TimeFormat : Locale.ShortFormat' "$corners_qml" ||
        fail "Corners time has no locale fallback for a blank TimeFormat"
    # the unguarded call is exactly what rendered an empty clock
    if grep -Eq 'toLocale(Date|Time)String\(Qt.locale\(\), config\.(Date|Time)Format\)' "$corners_qml"; then
        fail "Corners still passes the raw format to toLocale*String"
    fi
else
    fail "Corners archive has no components/DateTimePanel.qml"
fi

printf '    Candy and Corners archives checked\n'
finish
