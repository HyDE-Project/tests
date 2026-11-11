#!/usr/bin/env bash
# wallbash-generated text must stay legible against its own background
# (HyDE-Project/HyDE#2185).
#
# Two independent gaps, two independent checks:
#
# - wallbash.sh picked dcol_txt*'s direction (and, separately, a dedicated
#   ANSI black/white pair for kitty.dcol's color0/7/8/15) from a raw gray-mean
#   brightness check with no safety margin and no verification that the
#   result actually contrasted with its background. A mid-luminance
#   background could land on a hue-tinted text color that still read poorly.
#   luminance()/contrast_ratio() implement the WCAG formula directly, and a
#   synthetic wallpaper built around a known borderline color (found by
#   scanning -- see the inline values below) exercises the real fallback this
#   check feeds.
#
# - color.set.sh's substitution must not regress a .dcol file that predates
#   this fix (a stale per-wallpaper cache, or a static theme's theme.dcol):
#   this repo's own installed themes have no dcol_ansi_black/white field, and
#   without a fallback chain <wallbash_ansi_black/white> is left unsubstituted
#   in kitty.conf, which kitty can't parse -- worse than the bug being fixed.

. "$(dirname -- "$0")/lib/common.sh"

wallbash_sh="$REPO_ROOT/Configs/.local/lib/hyde/wallbash.sh"
color_set="$REPO_ROOT/Configs/.local/lib/hyde/color.set.sh"
kitty_dcol="$REPO_ROOT/Configs/.local/share/wallbash/theme/kitty.dcol"

for required in "$wallbash_sh" "$color_set" "$kitty_dcol"; do
    [ -f "$required" ] || {
        fail "missing ${required#"$REPO_ROOT"/}"
        finish
    }
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

##
# WCAG math (luminance/contrast_ratio): pure awk, no ImageMagick needed, so
# this part always runs, CI included.
##

# shellcheck disable=SC1090
source <(sed -n '/^luminance() {/,/^}/p;/^contrast_ratio() {/,/^}/p' "$wallbash_sh")

check_ratio() {
    local got="$1" want="$2" label="$3"
    awk -v g="$got" -v w="$want" -v l="$label" \
        'BEGIN { d = g - w; if (d < 0) d = -d; exit !(d < 0.02) }' ||
        fail "$label: got $got, expected ~$want"
}

check_ratio "$(contrast_ratio FFFFFF 000000)" 21.000 "white/black contrast"
check_ratio "$(contrast_ratio FFFFFF FFFFFF)" 1.000 "white/white contrast"
check_ratio "$(contrast_ratio 000000 000000)" 1.000 "black/black contrast"
# 767676 on white is the commonly-cited WCAG AA boundary (~4.5:1); a formula
# bug that inverts the hi/lo luminance pick, or drops the +0.05 offset, moves
# this noticeably.
check_ratio "$(contrast_ratio 767676 FFFFFF)" 4.542 "767676/white contrast (WCAG AA boundary)"
# order must not matter
check_ratio "$(contrast_ratio FFFFFF 767676)" 4.542 "767676/white contrast is symmetric"
# sRGB gamma piecewise boundary (0.03928): a one-branch-off error here is a
# classic WCAG implementation bug and would not show up at the extremes.
check_ratio "$(luminance 0A0A0A)" 0.003035 "luminance just below the gamma linear/power threshold"

##
# dcol_txt* borderline cases: found by scanning backgrounds where the old
# fx_brightness-only pick (no contrast verification) produced < 4.5:1 --
# 907060 and 907858 below are two such backgrounds, confirmed against the
# pre-fix wallbash.sh (txt landed at FEFEFE/4.456 and FFFFFF/4.189). Also
# covers three plainly non-borderline cases (near-black, near-white,
# saturated mid-tone) so the fix is checked for not over-correcting them too.
##

if ! command -v magick >/dev/null 2>&1; then
    skip "ImageMagick is not installed, cannot build a synthetic wallpaper to drive wallbash.sh end to end"
else
    build_wallpaper() {
        # A 2x2 image with four distinct, well-separated colors so wallbash's
        # 4-color k-means extraction is deterministic; $1 is the color under
        # test, placed as the plurality (3 of 4 pixels) so it is dcolHex[0].
        local under_test="$1" out="$2"
        magick -size 2x2 xc:"#$under_test" \
            -fill "#$under_test" -draw "point 1,0" \
            -fill "#$under_test" -draw "point 0,1" \
            -fill "#101010" -draw "point 1,1" \
            "$out"
    }

    check_wallpaper_contrast() {
        local bg="$1" label="$2"
        local wall="$work_dir/$bg.png" out="$work_dir/$bg"
        build_wallpaper "$bg" "$wall"
        bash "$wallbash_sh" "$wall" "$out" >/dev/null 2>&1
        [ -f "$out.dcol" ] || {
            fail "$label: wallbash.sh did not produce $out.dcol"
            return
        }
        # shellcheck disable=SC1090
        source "$out.dcol"
        local pry="dcol_pry1" txt="dcol_txt1"
        [ -n "${!pry:-}" ] && [ -n "${!txt:-}" ] || {
            fail "$label: dcol_pry1/dcol_txt1 missing from $out.dcol"
            return
        }
        local ratio
        ratio=$(contrast_ratio "${!txt}" "${!pry}")
        awk -v r="$ratio" 'BEGIN { exit !(r >= 4.5) }' ||
            fail "$label: dcol_txt1 (${!txt}) on dcol_pry1 (${!pry}) is $ratio:1, below WCAG AA (4.5:1)"
    }

    check_wallpaper_contrast 907060 "known pre-fix failure (was FEFEFE, 4.456:1)"
    check_wallpaper_contrast 907858 "known pre-fix failure (was FFFFFF, 4.189:1)"
    check_wallpaper_contrast 0E0102 "near-black background (already passed pre-fix)"
    check_wallpaper_contrast FDF5F3 "near-white background (already passed pre-fix)"
    check_wallpaper_contrast B42341 "saturated mid-tone background (already passed pre-fix)"

    # dcol_ansi_black/white: must exist and clear WCAG AAA (7:1) against each
    # other for every background above, regardless of its own luminance --
    # these are the kitty.dcol color0/7/8/15 source, used together by any
    # app's light-text-on-dark or dark-text-on-light widget state.
    for bg in 907060 907858 0E0102 FDF5F3 B42341; do
        out="$work_dir/$bg"
        [ -f "$out.dcol" ] || continue
        # shellcheck disable=SC1090
        source "$out.dcol"
        [ -n "${dcol_ansi_black:-}" ] && [ -n "${dcol_ansi_white:-}" ] || {
            fail "$bg: dcol_ansi_black/white missing from the generated .dcol"
            continue
        }
        ratio=$(contrast_ratio "$dcol_ansi_black" "$dcol_ansi_white")
        awk -v r="$ratio" 'BEGIN { exit !(r >= 7) }' ||
            fail "$bg: dcol_ansi_black ($dcol_ansi_black) vs dcol_ansi_white ($dcol_ansi_white) is $ratio:1, below WCAG AAA (7:1)"
    done
fi

##
# color.set.sh substitution fallback: pure bash/sed, no ImageMagick needed.
# "Falsche Werte" -- a .dcol sourced here may be missing the new fields
# entirely (pre-fix cache or a static theme.dcol), or even the older
# dcol_1xa1/dcol_4xa9 fields it falls back to; in every case the rendered
# kitty.dcol must contain real hex, never a literal unresolved placeholder.
##

# shellcheck disable=SC1090
source <(sed -n '/^create_wallbash_substitutions() {/,/^}/p' "$color_set")
rgba_to_rgb() { :; } # unrelated helper referenced only outside this function

render_kitty_ansi_lines() {
    local use_inverted="${1:-false}" sed_script
    sed_script=$(create_wallbash_substitutions "$use_inverted")
    sed -E "$sed_script" "$kitty_dcol" | grep -E "^color(0|7|8|15)"
}

assert_no_placeholder() {
    local label="$1" rendered="$2"
    case "$rendered" in
    *wallbash_*)
        fail "$label: a <wallbash_*> placeholder was left unsubstituted in kitty.conf -- kitty cannot parse this:
$rendered"
        ;;
    esac
    [ -n "$rendered" ] || fail "$label: color0/7/8/15 did not render at all"
}

# 1. full post-fix .dcol: must use the real, contrast-verified pair.
unset "${!dcol_@}"
dcol_ansi_black="1a1a1a"
dcol_ansi_white="eaeaea"
rendered=$(render_kitty_ansi_lines)
assert_no_placeholder "full .dcol" "$rendered"
case "$rendered" in
*"#1a1a1a"*) ;;
*) fail "full .dcol: color0/8 did not use dcol_ansi_black: $rendered" ;;
esac
case "$rendered" in
*"#eaeaea"*) ;;
*) fail "full .dcol: color7/15 did not use dcol_ansi_white: $rendered" ;;
esac

# 2. pre-fix cached wallpaper .dcol or static theme.dcol: dcol_ansi_black/
# white absent, but the older dcol_1xa1/dcol_4xa9 are there (every installed
# theme.dcol and every cached wallpaper .dcol on this machine is in exactly
# this shape). Must fall back to them, not break.
unset "${!dcol_@}"
dcol_1xa1="525229"
dcol_4xa9="ffe4cc"
rendered=$(render_kitty_ansi_lines)
assert_no_placeholder "pre-fix .dcol (has 1xa1/4xa9)" "$rendered"
case "$rendered" in
*"#525229"*) ;;
*) fail "pre-fix .dcol: color0/8 did not fall back to dcol_1xa1: $rendered" ;;
esac
case "$rendered" in
*"#ffe4cc"*) ;;
*) fail "pre-fix .dcol: color7/15 did not fall back to dcol_4xa9: $rendered" ;;
esac

# 2b. same pre-fix shape, inverted mode (a light-variant theme/preset): the
# pre-fix template substituted <wallbash_1xaN>/<wallbash_4xaN> through the
# same src_i swap every other group uses (i=1 reads group 4, i=4 reads group
# 1), so the fallback must swap too -- a static "always read 1xa1/4xa9"
# fallback would read the wrong half of the palette once inverted, a bug
# CodeRabbit caught in review on this PR (HyDE-Project/HyDE#2190).
unset "${!dcol_@}"
dcol_4xa1="inverted-black-source"
dcol_1xa9="inverted-white-source"
rendered=$(render_kitty_ansi_lines true)
assert_no_placeholder "pre-fix .dcol, inverted mode" "$rendered"
case "$rendered" in
*"#inverted-black-source"*) ;;
*) fail "pre-fix .dcol, inverted mode: color0/8 did not fall back to dcol_4xa1 (the inverted-mode source for template slot 1): $rendered" ;;
esac
case "$rendered" in
*"#inverted-white-source"*) ;;
*) fail "pre-fix .dcol, inverted mode: color7/15 did not fall back to dcol_1xa9 (the inverted-mode source for template slot 4): $rendered" ;;
esac

# 3. nothing at all: neither the new fields nor the old ones are set (an
# even older or hand-edited .dcol, or a theme.dcol trimmed down to only the
# fields a particular theme author's generator happened to emit). Must still
# render real hex, via the hardcoded flat-neutral floor.
unset "${!dcol_@}"
rendered=$(render_kitty_ansi_lines)
assert_no_placeholder "no color fields at all" "$rendered"
case "$rendered" in
*"#121212"*) ;;
*) fail "no color fields at all: color0/8 did not fall back to the hardcoded default: $rendered" ;;
esac
case "$rendered" in
*"#F2F2F2"*) ;;
*) fail "no color fields at all: color7/15 did not fall back to the hardcoded default: $rendered" ;;
esac

printf '    wallbash contrast behaviour checked\n'

finish
