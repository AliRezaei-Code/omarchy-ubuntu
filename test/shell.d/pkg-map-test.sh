#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

# dpkg and apt have to answer consistently for the round trip to mean anything:
# a package is absent until apt installs it, so `omarchy-pkg-add` has to
# resolve the name, ask apt for the Ubuntu one, and then find it installed.
installed="$test_tmp/installed"
: >"$installed"
export PKG_MAP_INSTALLED="$installed"

cat >"$stub_bin/dpkg-query" <<'STUB'
#!/bin/bash
printf 'dpkg-query %s\n' "$*" >>"$PKG_MAP_CALL_LOG"

list=0
name=""
for arg in "$@"; do
  case "$arg" in
  *'${binary:Package}'*) list=1 ;;
  -*) ;;
  *) name="$arg" ;;
  esac
done

if (( list == 1 )); then
  for package in $(cat "$PKG_MAP_INSTALLED"); do
    printf 'ii %s\n' "$package"
  done
  exit 0
fi

if grep -qxF -- "$name" "$PKG_MAP_INSTALLED"; then
  printf 'ii \n'
  exit 0
fi

printf 'rc \n'
exit 1
STUB

# apt is what makes a package installed, so it has to record it.
cat >"$stub_bin/apt-get" <<'STUB'
#!/bin/bash
{ printf 'apt-get'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_MAP_CALL_LOG"

# Record the operands, not apt's own flags: what got installed is the answer
# to "did the Ubuntu names reach apt", and a flag is not a package.
if [[ ${1:-} == "install" ]]; then
  shift
  for arg in "$@"; do
    [[ $arg == -* ]] || printf '%s\n' "$arg" >>"$PKG_MAP_INSTALLED"
  done
fi
exit 0
STUB

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
{ printf 'sudo'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_MAP_CALL_LOG"

# Real env takes VAR=value pairs before the command and sets them itself;
# `exec` cannot, so do what env does and run whatever is left.
while (( $# )) && [[ $1 == *=* && $1 != -* ]]; do
  export "$1"
  shift
done

exec "$@"
STUB

chmod +x "$stub_bin"/*

call_log="$test_tmp/calls"
export PKG_MAP_CALL_LOG="$call_log"

# --- parsing -------------------------------------------------------------

# A hand-written map is only as trustworthy as its parser, so the properties
# that keep it out of trouble are pinned directly rather than inferred.
mkdir -p "$test_tmp/install"
map_path="$test_tmp/install/pkg-map.conf"
cat >"$map_path" <<'MAP'
# A comment, and a blank line follow.

nvim	neovim
fd	fd-find	fd=fdfind
bat	bat	bat=batcat
gvfs-mtp gvfs-backends
cupspk
expac	
MAP

translate() {
  OMARCHY_PATH="$test_tmp" bash -c '
    source "$ROOT/bin/omarchy-pkg-map"
    omarchy_pkg_map_translate "$1"
  ' _ "$1"
}

[[ $(translate nvim) == "neovim" ]] ||
  fail "a tab-separated row translates" "$(translate nvim)"
pass "a tab-separated row translates"

[[ $(translate nvim | wc -w) == 1 ]] ||
  fail "a trailing field is not read as part of the package list"
pass "a trailing field is not read as part of the package list"

[[ $(OMARCHY_PATH="$test_tmp" bash -c 'source "$ROOT/bin/omarchy-pkg-map"; omarchy_pkg_map_aliases' | tr ' ' '\n' | sort) == $'bat=batcat\nfd=fdfind' ]] ||
  fail "binary aliases are collected from every row" \
  "$(OMARCHY_PATH="$test_tmp" bash -c 'source "$ROOT/bin/omarchy-pkg-map"; omarchy_pkg_map_aliases' | tr ' ' '\n' | sort)"
pass "binary aliases are collected from every row"

# A name the map never mentions is not a claim the map makes, so it passes
# through: most Arch names are spelled the same on both systems.
[[ $(translate git) == "git" ]] || fail "an unmapped name passes through unchanged"
pass "an unmapped name passes through unchanged"

# An empty package list is a statement, not an omission: the caller has to be
# able to tell it apart from a name the map says nothing about.
if translate expac >/dev/null 2>&1; then
  fail "an empty package list is reported as unsupported"
fi
pass "an empty package list is reported as unsupported"

# Comments and blank lines are the map's own documentation, and a `#` inside a
# value is not a comment.
[[ $(translate '# not a row') == "# not a row" ]] || fail "a name beginning with # is a name"
pass "a name beginning with # is a name"

# --- callers -------------------------------------------------------------

: >"$call_log"
OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-add" nvim fd >/dev/null 2>&1
grep -Fxq 'apt-get <install> <-y> <--no-install-recommends> <neovim> <fd-find>' "$call_log" ||
  fail "pkg-add installs the Ubuntu names, not the Arch ones" "$(<"$call_log")"
if grep -qE '(^| )<(nvim|fd)>( |$)' "$call_log"; then
  fail "pkg-add never names an Arch package to apt" "$(<"$call_log")"
fi
grep -Fxq 'dpkg-query -W -f=${db:Status-Abbrev} -- neovim' "$call_log" ||
  fail "the name dpkg is asked about is the Ubuntu one" "$(<"$call_log")"
pass "pkg-add installs the Ubuntu names, not the Arch ones"

[[ $(sort "$installed") == $'fd-find\nneovim' ]] ||
  fail "apt is asked for exactly the Ubuntu names" "$(sort "$installed" | tr '\n' ' ')"
pass "apt is asked for exactly the Ubuntu names"

# The mirror image: a presence check has to reach dpkg under the Ubuntu name,
# or everything the guard batch asks about is a question about a package that
# dpkg has never heard of.
: >"$call_log"
OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-present" nvim ||
  fail "pkg-present finds a package the map renamed" "$(<"$call_log")"
grep -q -- '-- neovim$' "$call_log" ||
  fail "pkg-present asks dpkg about the Ubuntu name" "$(<"$call_log")"
if grep -q -- '-- nvim$' "$call_log"; then
  fail "pkg-present never asks dpkg about the Arch name" "$(<"$call_log")"
fi
pass "pkg-present asks dpkg about the Ubuntu name, not the Arch one"

OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-missing" nvim &&
  fail "pkg-missing inverts the mapped answer"
OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-missing" bat >/dev/null 2>&1 ||
  fail "pkg-missing finds a mapped package that is not installed"
pass "pkg-missing inverts the mapped answer"

# On Arch the map is a no-op, so 126+ callers keep exactly the meaning they
# had: `omarchy-pkg-present nvim` must still ask pacman about `nvim`.
: >"$call_log"
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$PKG_MAP_CALL_LOG"
exit 0
STUB
chmod +x "$stub_bin/pacman"
OMARCHY_PATH="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-pkg-present" nvim
grep -Fxq 'pacman -Q -- nvim' "$call_log" ||
  fail "the arch backend asks pacman the Arch name it was given" "$(<"$call_log")"
pass "the arch backend asks pacman the Arch name it was given"

# A name the map declares unsupported has no Ubuntu equivalent, and saying so
# is the whole point of declaring it: a silent skip would look like success.
: >"$call_log"
status=0
OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-add" expac >"$test_tmp/add.out" 2>"$test_tmp/add.err" || status=$?
[[ $status == 0 ]] || fail "adding a package with no Ubuntu equivalent is not a failure" "exit $status"
[[ $(<"$test_tmp/add.err") == "omarchy-pkg-add: no Ubuntu package is equivalent to 'expac'; skipping it" ]] ||
  fail "add names the package it could not translate" "$(<"$test_tmp/add.err")"
if grep -q 'apt-get' "$call_log"; then
  fail "add runs no transaction for a package it cannot translate" "$(<"$call_log")"
fi
pass "add says which package it could not translate and installs nothing"

# One unsupported name among installable ones costs only that one.
: >"$call_log"
OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-add" expac gvfs-mtp 2>"$test_tmp/add.err"
grep -Fxq 'apt-get <install> <-y> <--no-install-recommends> <gvfs-backends>' "$call_log" ||
  fail "a supported package beside an unsupported one still installs" "$(<"$call_log")"
pass "a supported package beside an unsupported one still installs"

if OMARCHY_PATH="$ROOT" OMARCHY_PKG_BACKEND=deb PATH="$stub_bin:$ROOT/bin:$PATH" \
  "$ROOT/bin/omarchy-pkg-present" expac >/dev/null 2>&1; then
  fail "a package with no Ubuntu equivalent is never present"
fi
pass "a package with no Ubuntu equivalent is never present"

# --- the shipped map -----------------------------------------------------

shipped="$ROOT/install/pkg-map.conf"
[[ -f $shipped ]] || fail "the shipped map exists"

# A map that names a package nothing in the tree asks for is documentation
# nobody maintains. Every key has to be a name a caller could pass.
unused=$(awk -F'\t' '/^[^#[:space:]]/ { print $1 }' "$shipped" |
  while read -r name; do
    if ! grep -rlwF -- "$name" "$ROOT/bin" "$ROOT/install" "$ROOT/migrations" "$ROOT/default" "$ROOT/etc" >/dev/null 2>&1; then
      echo "$name"
    fi
  done)
[[ -z $unused ]] ||
  fail "every mapped package is one the tree can ask for" "$unused"
pass "every mapped package is one the tree can ask for"

# A row is either a name with packages or a name that declares itself
# unsupported. What must never appear is a name with nothing on either side --
# that is a typo, and a typo here means a package silently never installs --
# and neither may a name carry a space, which would read as part of the
# package field.
malformed=$(awk -F'\t' '
  /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
  $1 == "" { print NR": no name: "$0; next }
  $1 ~ / / { print NR": spaced name: "$0; next }
  NF >= 3 && $2 == "" { print NR": declared empty but carries aliases: "$0; next }
  NF >= 2 && $2 ~ /^[[:space:]]+$/ { print NR": blank package list: "$0; next }
' "$shipped")
[[ -z $malformed ]] ||
  fail "every row in the map is a name with packages or a declared-empty name" "$malformed"
pass "every row in the map is a name with packages or a declared-empty name"

# --- the Ubuntu package list ---------------------------------------------

deb_list="$ROOT/install/omarchy-deb.packages"
[[ -f $deb_list ]] || fail "the Ubuntu package list exists"

# Generated, not maintained: every Arch name in the base list has to reach the
# Ubuntu list, and nothing may reach it that the Arch list did not ask for. One
# process for both directions -- a subprocess per package would take longer
# than the suite it belongs to.
deb_dependencies() {
  # The file ends with a declared-unsupported footer naming Arch packages on
  # purpose; only the part above it is a dependency list.
  sed '/^# --- no Ubuntu equivalent/,$d' "$deb_list" | grep -vE '^[[:space:]]*(#|$)' | sort -u
}

# One process for both directions: a subprocess per package would take longer
# than the suite this file belongs to.
translated_base_packages() {
  OMARCHY_PATH="$ROOT" bash -c '
    source "$OMARCHY_PATH/bin/omarchy-pkg-map"
    while IFS= read -r name; do
      omarchy_pkg_map_translate "$name" 2>/dev/null
    done < <(grep -vE "^[[:space:]]*(#|$)" "$OMARCHY_PATH/install/omarchy-base.packages")
  ' | tr " " "\n" | grep -v '^$' | sort -u
}

undelivered=$(comm -23 <(translated_base_packages) <(deb_dependencies))
[[ -z $undelivered ]] ||
  fail "every translatable base package reaches the Ubuntu list" "$undelivered"
pass "every translatable base package reaches the Ubuntu list"

# And nothing in the Ubuntu list that no Arch package asked for.
stray=$(comm -13 <(translated_base_packages) <(deb_dependencies))
[[ -z $stray ]] ||
  fail "the Ubuntu list holds only what the Arch list asks for" "$stray"
pass "the Ubuntu list holds only what the Arch list asks for"

# Generated, not maintained: regenerating it has to reproduce it byte for byte,
# or the checked-in file is a hand edit wearing a generated header.
before=$(cksum <"$deb_list")
OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-deb-packages" >/dev/null
[[ $(cksum <"$deb_list") == "$before" ]] ||
  fail "regenerating the Ubuntu list reproduces the checked-in file"
pass "regenerating the Ubuntu list reproduces the checked-in file"
