#!/usr/bin/env sh
# A submodule's tracked `branch` in .gitmodules must exist on its remote.
#
# `git submodule update --remote` follows that branch; naming one the remote
# does not have (language-packs tracked `master` while its only branch is
# `main`) leaves the update with nothing to follow.

. "$(dirname -- "$0")/lib/common.sh"

if ! command -v git >/dev/null 2>&1; then
    skip "git is not installed"
    finish
fi

# Prints the state of one submodule entry:
#   ok | missing-branch | empty-branch | no-url | unreachable
branch_state() { # <gitmodules file> <submodule name>
    file=$1
    name=$2
    branch=$(git config -f "$file" --get "submodule.$name.branch" 2>/dev/null) || branch=''
    url=$(git config -f "$file" --get "submodule.$name.url" 2>/dev/null) || url=''

    [ -n "$url" ] || { echo no-url; return; }
    [ -n "$branch" ] || { echo empty-branch; return; }

    git ls-remote --heads --exit-code "$url" "refs/heads/$branch" >/dev/null 2>&1
    case $? in
        0) echo ok ;;
        2) echo missing-branch ;; # reachable, but no such branch
        *) echo unreachable ;;
    esac
}

# Names of submodules that set a `branch` key (an absent key is "track the
# remote's default HEAD", which needs no check).
tracked() { # <gitmodules file>
    git config -f "$1" --name-only --get-regexp '^submodule\..*\.branch$' 2>/dev/null |
        sed 's/^submodule\.//; s/\.branch$//'
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# ---- the check itself, against fixtures ---------------------------------
# A local bare repository whose only branch is `main`: no network needed.
git init -q --bare "$tmp/remote.git"
git init -q "$tmp/work"
(
    cd "$tmp/work" || exit 1
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    git branch -M main
    git push -q "$tmp/remote.git" main
) >/dev/null 2>&1

fixture() { # <branch line value|-> <url> -> path of a .gitmodules
    out="$tmp/gm.$$.$(date +%s%N)"
    {
        printf '[submodule "x"]\n\tpath = x\n'
        [ "$2" = '-' ] || printf '\turl = %s\n' "$2"
        [ "$1" = '-' ] || printf '\tbranch = %s\n' "$1"
    } >"$out"
    echo "$out"
}

expect() { # <label> <expected> <branch> <url>
    got=$(branch_state "$(fixture "$3" "$4")" x)
    [ "$got" = "$2" ] || fail "$1: expected $2, got $got"
}

expect "branch that exists"            ok             main    "$tmp/remote.git"
expect "branch the remote lacks"       missing-branch master  "$tmp/remote.git"
expect "case differs"                  missing-branch Main    "$tmp/remote.git"
# git config trims trailing whitespace in an unquoted value, so this still resolves
expect "trailing space is trimmed"     ok             'main ' "$tmp/remote.git"
expect "branch name with a slash"      missing-branch a/b     "$tmp/remote.git"
expect "unreachable remote"            unreachable    main    "$tmp/does-not-exist.git"
expect "no url at all"                 no-url         main    -
expect "no branch key counts as empty" empty-branch   -       "$tmp/remote.git"

printf '[submodule "x"]\n\tpath = x\n\turl = %s\n\tbranch = \n' "$tmp/remote.git" >"$tmp/empty.gm"
[ "$(branch_state "$tmp/empty.gm" x)" = empty-branch ] || fail "an empty branch value is not flagged"

# a file with no branch keys has nothing to check
printf '[submodule "x"]\n\tpath = x\n\turl = %s\n' "$tmp/remote.git" >"$tmp/none.gm"
[ -z "$(tracked "$tmp/none.gm")" ] || fail "tracked() listed a submodule without a branch key"

# ---- the tree under test -------------------------------------------------
gm="$REPO_ROOT/.gitmodules"
if [ ! -f "$gm" ]; then
    skip "no .gitmodules"
    finish
fi

checked=0
for name in $(tracked "$gm"); do
    case $(branch_state "$gm" "$name") in
        ok) checked=$((checked + 1)) ;;
        missing-branch) fail "$name tracks branch '$(git config -f "$gm" --get "submodule.$name.branch")', which its remote does not have" ;;
        empty-branch) fail "$name has an empty branch value" ;;
        no-url) fail "$name has no url" ;;
        unreachable) skip "$name's remote is unreachable (offline?)" ;;
    esac
done

printf '    %d tracked submodule branch(es) checked\n' "$checked"
finish
