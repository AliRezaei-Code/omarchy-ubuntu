#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

require_command dpkg-deb
require_command make

# The deb is the deliverable: everything above it is a script in a checkout, and
# this is the first thing that has to work on a machine that is not this one.
# So these assertions are about the artefact -- what dpkg itself reports about
# it -- and not about the makefile that produced it.

make -s -C "$ROOT" deb >"$test_tmp/make.out" 2>"$test_tmp/make.err" || {
  fail "make deb produces a .deb" "$(<"$test_tmp/make.err")"
}

# One artefact, so a build that somehow produced two is a build to look at
# rather than a test to accommodate.
mapfile -t debs < <(ls "$ROOT"/build/deb/*.deb 2>/dev/null)
[[ ${#debs[@]} == 1 ]] || fail "make deb produces exactly one .deb" "${debs[*]}"
deb="${debs[0]}"
pass "make deb produces a .deb"

control=$(dpkg-deb -f "$deb")
[[ $(sed -n 's/^Package: //p' <<<"$control") == "omarchy" ]] ||
  fail "the package is named omarchy" "$control"
pass "the package is named omarchy"

# It is a metapackage of scripts and data with no compiled code, and saying
# otherwise makes apt install a C library nobody needs.
[[ $(sed -n 's/^Architecture: //p' <<<"$control") == "all" ]] ||
  fail "the package is architecture-independent" "$control"
[[ -z $(sed -n 's/^Depends: //p' <<<"$control" | grep -E 'libc6|libgcc') ]] ||
  fail "the package depends on no C library" "$control"
pass "the package is architecture-independent and depends on no C library"

version=$(sed -n 's/^Version: //p' <<<"$control")
base_version=$(cat "$ROOT/version")
[[ $version == "$base_version" || $version == "$base_version"+g* ]] ||
  fail "the version comes from the version file" "$version != $base_version"
pass "the version comes from the version file ($version)"

# Everything the package layer promises has to be installable, or `omarchy
# update` on a fresh machine fails at a dependency rather than at a command.
depends=$(sed -n 's/^Depends: //p' <<<"$control" | tr ', ' '\n\n' | grep -v '^$')
for required in nodejs gjs gir1.2-adw-1 fzf jq; do
  grep -qxF "$required" <<<"$depends" ||
    fail "the deb depends on $required" "$depends"
done
pass "the deb depends on the runtimes both front ends need"

# A symlink line ends in " -> target", and the target is what awk's last field
# would pick up. What this file is about is the paths the package owns, so the
# link is recorded and the target discarded.
listing=$(dpkg-deb -c "$deb" |
  sed 's| -> .*$||' |
  awk '{print $NF}' |
  sed 's|^\./||')

# The packaged contract, already written into default/bash/env-bootstrap.
grep -qx 'usr/bin/omarchy' <<<"$listing" ||
  fail "the router is installed at /usr/bin/omarchy"
grep -qx 'etc/profile.d/omarchy.sh' <<<"$listing" ||
  fail "the login-shell profile is installed"
grep -qx 'usr/share/omarchy/version' <<<"$listing" ||
  fail "the version file is installed where omarchy-version reads it"
pass "the layout matches what env-bootstrap already promises"

grep -q '^usr/share/omarchy/bin/' <<<"$listing" ||
  fail "the tree is installed at /usr/share/omarchy"
pass "the tree is installed at /usr/share/omarchy"

# Every omarchy-* binary in bin/ has to be reachable by bare name, or the 460
# commands that shell out to each other find nothing.
missing=()
for binary in "$ROOT"/bin/omarchy-*; do
  name=${binary##*/}
  grep -qx "usr/bin/$name" <<<"$listing" || missing+=("$name")
done
(( ${#missing[@]} == 0 )) || fail "every command is on PATH" "${missing[*]}"
pass "all $(ls "$ROOT"/bin/omarchy-* | wc -l) commands are on PATH"

# Anything the tree ships as a private helper stays out of /usr/bin, so
# `omarchy pkg backend` is a command and `omarchy-pkg-transaction` is not
# something a user can run by accident.
# `grep && fail` is a non-zero compound when the check passes, which set -e
# reads as a failure. Written the other way round, and negated because this is
# the shape we do not want.
if grep -qx 'usr/bin/omarchy-dashboard-tui.js' <<<"$listing"; then
  fail "a front-end script is not installed as a command" "$listing"
fi
pass "a front-end script is not installed as a command"

# The manifest is the same list, and a deb that stages a path the manifest does
# not claim is how the ownership invariant quietly stops meaning anything.
if [[ -f $ROOT/packaging/ubuntu/deb/omarchy.manifest ]]; then
  manifest="$ROOT/packaging/ubuntu/deb/omarchy.manifest"
  # dpkg-deb -c prints package-relative paths; the manifest spells them as
  # install paths. Comparing them as written would call every single one
  # unlisted.
  declared=$(sed 's|^/||' "$manifest")
  unlisted=$(while IFS= read -r path; do
    [[ $path == */ ]] && continue
    grep -qxF "$path" <<<"$declared" || echo "$path"
  done <<<"$listing" | head -5)
  [[ -z $unlisted ]] ||
    fail "every installed path is on the manifest" "$unlisted"
  pass "every installed path is on the manifest"
fi

# gum is a substitute the tree ships, so it has to land somewhere a call site
# can find it. /usr/local/bin is on PATH ahead of /usr/bin on a stock install
# and is not owned by dpkg, which is exactly the point.
grep -q 'packaging/ubuntu/compat/gum' "$ROOT/Makefile" ||
  fail "the gum substitute is installed by the deb"
pass "the gum substitute is installed by the deb"

postinst=$(dpkg-deb --ctrl-tarfile "$deb" | tar -xO ./postinst 2>/dev/null || true)
[[ -n $postinst ]] || fail "the deb has a postinst"
grep -q 'fdfind' <<<"$postinst" && grep -q 'batcat' <<<"$postinst" ||
  fail "the postinst links the renamed binaries" "$postinst"
grep -q 'omarchy-refresh-config' <<<"$postinst" ||
  fail "the postinst says what to run next" "$postinst"
pass "the postinst links fdfind and batcat and says what to run next"
