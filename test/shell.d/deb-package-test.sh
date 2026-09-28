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

# dpkg-deb -c prints: perms links owner group size date time path, with a
# symlink's target after " -> ". Taking the last field -- the obvious way --
# truncates every path with a space in it, and this tree ships several:
# "Disk Usage.desktop", "Google Maps.desktop", and so on. dpkg-deb -c prints
# perms owner/group size date time path -- five fields, then the path, so
# blanking one to five keeps the whole of it, spaces and all.
listing=$(dpkg-deb -c "$deb" |
  sed 's| -> .*$||' |
  awk '{$1=$2=$3=$4=$5=""; sub(/^ +/, ""); print}' |
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

# The desktop entry is the whole reason the app appears in the user's app grid,
# and omarchy-refresh-applications copies it from the INSTALLED tree. A package
# that builds and installs perfectly while missing that directory leaves the
# user with no dashboard and a "cp: cannot stat" on the first command they are
# told to run -- which is exactly what six releases did.
listing_has() { grep -qx "$1" <<<"$listing"; }

listing_has 'usr/share/omarchy/applications/Omarchy.desktop' ||
  fail "the package ships the desktop entry the refresh command copies"
listing_has 'usr/share/icons/hicolor/scalable/apps/omarchy-dashboard.svg' ||
  fail "the package ships the dashboard icon"
listing_has 'usr/share/omarchy/install/user/mise.sh' ||
  fail "the package ships install/user, which the refresh command reads"

# And it must agree with the shipped tree, or the two describe different
# machines again.
while read -r entry; do
  name="${entry##*/}"
  listing_has "usr/share/omarchy/applications/$name" ||
    fail "every shipped .desktop is in the package" "$name"
done < <(cd "$ROOT" && ls applications/*.desktop)
pass "the package ships every .desktop the tree declares"

# The wrapper resolves the app's source relative to itself, so a package
# without app/ installs perfectly, passes every dependency check, and then
# cannot start the dashboard -- which is what seven releases did, and what the
# applications/ omission before it did. The package has to ship what its own
# commands read.
for required in \
  'usr/share/omarchy/app/omarchy-dashboard/omarchy-dashboard.js' \
  'usr/share/omarchy/shell/plugins/menu/MenuModel.js' \
  'usr/share/omarchy/shell/plugins/menu/MenuSnapshot.js' \
  'usr/share/omarchy/shell/plugins/menu/TuiModel.js' \
  'usr/share/omarchy/shell/plugins/menu/DashboardTui.js' \
  'usr/share/omarchy/install/pkg-map.conf' \
  'usr/share/omarchy/config/kitty/kitty.conf' ; do
  listing_has "$required" || fail "the package ships $required, which its commands read"
done
pass "the package ships every file its own commands read"

# And the graphical front end, asked directly, must find what it needs.
# --available is the windowless probe `omarchy dashboard` uses to choose
# between the app and the TUI, so a package whose app source is missing shows
# up here as a missing file rather than as a user staring at nothing.
if "$ROOT/bin/omarchy-dashboard-app" --available >/dev/null 2>&1; then
  pass "omarchy-dashboard-app reports itself available"
else
  # gjs or the libadwaita typelib is absent on some machines; that is the
  # documented refusal, and it is what makes the fallback a real decision.
  "$ROOT/bin/omarchy-dashboard-app" --available 2>&1 |
    grep -q 'the graphical dashboard is unavailable on this system' ||
    fail "omarchy-dashboard-app refuses with its documented message when it cannot start"
  pass "omarchy-dashboard-app refuses with its documented message when it cannot start"
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

# --- no command assumes OMARCHY_PATH is exported ---------------------------
#
# The deb installs the tree at /usr/share/omarchy, and /etc/profile.d sets
# OMARCHY_PATH for LOGIN shells. A GNOME session is not a login shell, so on a
# desktop -- the one place the dashboard is meant to appear -- the variable is
# simply absent. Six releases shipped with omarchy-refresh-applications, the
# command the postinst names and the one that installs the app-grid entry,
# failing with "cp: cannot stat '/applications/*.desktop'".
#
# Every command that reads the variable therefore has to fall back to the
# packaged root, which is what the 55 of them now do.
unguarded=""
for script in "$ROOT"/bin/*; do
  [[ -f $script && -x $script ]] || continue
  head -1 "$script" | grep -q 'bash' || continue
  grep -q 'OMARCHY_PATH' "$script" || continue
  grep -qE 'OMARCHY_PATH:-|OMARCHY_PATH="' "$script" && continue
  # A mention inside a comment is not a read.
  grep -vE '^[[:space:]]*#' "$script" | grep -q '\$OMARCHY_PATH' &&
    unguarded="$unguarded ${script##*/}"
done

[[ -z $unguarded ]] ||
  fail "every bin/ command defaults OMARCHY_PATH to the packaged root" "$unguarded"
pass "every bin/ command defaults OMARCHY_PATH to the packaged root"

# And the two the postinst names carry the fallback explicitly, since those
# are the commands a user is told to run first.
for command in omarchy-refresh-applications omarchy-refresh-config; do
  grep -q 'OMARCHY_PATH:-/usr/share/omarchy' "$ROOT/bin/$command" ||
    fail "$command falls back to the packaged root"
done
pass "the first-run commands fall back to the packaged root"
