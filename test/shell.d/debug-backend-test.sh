#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp" /tmp/omarchy-debug.log' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

pkg_log="$test_tmp/pkg-log"

# The bug report reads the system too, and none of that is under test here.
for command in inxi journalctl; do
  cat >"$stub_bin/$command" <<STUB
#!/bin/bash
printf '%s\n' "$command output"
STUB
done

# A debug report that escalates on its own is a bug in itself.
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$OMARCHY_TEST_LOG"
exit 99
STUB

# One dpkg answers every question the seam asks it: which packages are
# installed, and whether one particular package is.
cat >"$stub_bin/dpkg-query" <<'STUB'
#!/bin/bash
printf 'dpkg-query %s\n' "$*" >>"$OMARCHY_TEST_LOG"

if [[ " $* " == *" -S "* ]]; then
  exit 0
fi

for arg in "$@"; do
  if [[ $arg == *'${db:Status-Abbrev} ${binary:Package}\n'* ]]; then
    for package in ${OMARCHY_TEST_PACKAGES:-}; do
      printf 'ii %s\n' "$package"
    done
    exit 0
  fi
done

for arg in "$@"; do
  if [[ $arg == '-f=${db:Status-Abbrev}' ]]; then
    package="${!#}"
    if [[ " ${OMARCHY_TEST_PACKAGES:-} " == *" $package "* ]]; then
      printf 'ii '
    else
      printf 'rc '
    fi
    exit 0
  fi
done

for arg in "$@"; do
  if [[ $arg == '-f=${Version}' ]]; then
    package="${!#}"
    [[ " ${OMARCHY_TEST_PACKAGES:-} " == *" $package "* ]] || exit 1
    printf '9.9'
    exit 0
  fi
done

exit 1
STUB

# pacman answers what the user asked for, what the repositories offer, and
# whether one particular package is installed.
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$OMARCHY_TEST_LOG"
case "$*" in
"-Qqe") printf '%s\n' ${OMARCHY_TEST_PACKAGES:-} ;;
"-Sql") printf '%s\n' ${OMARCHY_TEST_REPO:-} ;;
esac
if [[ $1 == "-Q" ]]; then
  # `-Q` answers a version question: name and version, one line per package,
  # and a non-zero exit unless every package asked about is installed.
  all_installed=1
  for arg in "$@"; do
    [[ $arg == -* ]] && continue
    if [[ " ${OMARCHY_TEST_PACKAGES:-} " == *" $arg "* ]]; then
      printf '%s 9.9\n' "$arg"
    else
      all_installed=0
    fi
  done
  (( all_installed == 1 )) && exit 0
  printf 'error: package %s was not found\n' "$*" >&2
  exit 1
fi
STUB

# expac decorates each package with its version and the place it came from.
cat >"$stub_bin/expac" <<'STUB'
#!/bin/bash
printf 'expac %s\n' "$*" >>"$OMARCHY_TEST_LOG"

mode=""
format=""
for arg in "$@"; do
  if [[ $arg == -* ]]; then
    mode="$arg"
  elif [[ $arg == *%* ]]; then
    format="$arg"
  fi
done

for package in "$@"; do
  [[ $package == -* || $package == *%* ]] && continue
  # expac -S only reports packages the sync repositories offer, which is what
  # leaves the AUR packages for the second call to annotate.
  if [[ $mode == -S ]]; then
    in_repo=""
    for repo_package in ${OMARCHY_TEST_REPO:-}; do
      [[ $repo_package == "$package" ]] && in_repo=1
    done
    [[ -n $in_repo ]] || continue
  fi
  if [[ $mode == -Q || $format == *AUR* ]]; then
    printf '%s 9.9 (AUR)\n' "$package"
  else
    printf '%s 1.2 (extra)\n' "$package"
  fi
done
STUB

chmod +x "$stub_bin"/*

export OMARCHY_TEST_LOG="$pkg_log"

# Everything after the last section header, which is where the packages land.
package_section() {
  awk '/^INSTALLED PACKAGES$/{ p = 1; next } p && /^=+$/{ next } p{ print }'
}

run_debug() {
  local backend="$1" packages="$2" repo="$3"

  : >"$pkg_log"
  OMARCHY_PKG_BACKEND="$backend" \
    OMARCHY_TEST_PACKAGES="$packages" \
    OMARCHY_TEST_REPO="$repo" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-debug" --no-sudo --print
}

# Arch: repository packages carry their repository, and the packages no
# repository offers are the AUR ones.
arch_log=$(run_debug arch "omarchy neovim yay-bin" "omarchy neovim")
arch_section=$(package_section <<<"$arch_log")

[[ $arch_section == "neovim 1.2 (extra)
omarchy 1.2 (extra)
yay-bin 9.9 (AUR)" ]] || fail "arch debug report splits repository packages from AUR ones" "$arch_section"
pass "arch debug report splits repository packages from AUR ones"

# The edge package is asked about before the stable one, and a system with
# neither still produces a report.
edge_line=$(grep -n '^pacman -Q -- omarchy-dev$' "$pkg_log" | head -1 | cut -d: -f1)
stable_line=$(grep -n '^pacman -Q -- omarchy$' "$pkg_log" | head -1 | cut -d: -f1)
[[ -n $edge_line && -n $stable_line && $edge_line -lt $stable_line ]] ||
  fail "arch debug report asks about the edge package first" "$(<"$pkg_log")"
pass "arch debug report asks about the edge package first"

no_omarchy_log=$(run_debug arch "neovim yay-bin" "neovim")
grep -q '^Omarchy Package: unknown$' <<<"$no_omarchy_log" ||
  fail "arch debug report names an unknown package as unknown" "$(grep '^Omarchy Package:' <<<"$no_omarchy_log")"
pass "arch debug report names an unknown package as unknown"

# Debian: the installed set is the answer, and there is no AUR set to subtract
# a repository list from, so no AUR lines are printed at all.
deb_log=$(run_debug deb "foot neovim omarchy" "")
deb_section=$(package_section <<<"$deb_log")

[[ $deb_section == "foot
neovim
omarchy" ]] || fail "deb debug report lists the installed packages" "$deb_section"
pass "deb debug report lists the installed packages"

if grep -q '(AUR)' <<<"$deb_log"; then
  fail "deb debug report prints no AUR section" "$deb_section"
fi
pass "deb debug report prints no AUR section"

if grep -q '^pacman \|^expac ' "$pkg_log"; then
  fail "deb debug report never reaches for pacman or expac" "$(<"$pkg_log")"
fi
pass "deb debug report never reaches for pacman or expac"

# omarchy-dev is asked about before omarchy, exactly as on Arch.
deb_edge_line=$(grep -n -- '-f=${db:Status-Abbrev} -- omarchy-dev$' "$pkg_log" | cut -d: -f1)
deb_stable_line=$(grep -n -- '-f=${db:Status-Abbrev} -- omarchy$' "$pkg_log" | cut -d: -f1)
[[ -n $deb_edge_line && -n $deb_stable_line && $deb_edge_line -lt $deb_stable_line ]] ||
  fail "deb debug report asks about the edge package first" "$(<"$pkg_log")"
pass "deb debug report asks about the edge package first"

no_omarchy_deb_log=$(run_debug deb "foot" "")
grep -q '^Omarchy Package: unknown$' <<<"$no_omarchy_deb_log" ||
  fail "deb debug report names an unknown package as unknown" "$(grep '^Omarchy Package:' <<<"$no_omarchy_deb_log")"
pass "deb debug report names an unknown package as unknown"


# The report's package line is the one place a bug report says which build the
# user is on, so it has to carry the version, not just the answer to a yes/no.
edge_log=$(run_debug arch "omarchy-dev neovim" "omarchy-dev neovim")
grep -qx 'Omarchy Package: omarchy-dev 9.9' <<<"$edge_log" ||
  fail "the arch package line names the package and its version" "$(grep '^Omarchy Package:' <<<"$edge_log")"
pass "the arch package line names the package and its version"

deb_package_line=$(run_debug deb "omarchy foot" "" | grep '^Omarchy Package:')
[[ $deb_package_line == "Omarchy Package: omarchy 9.9" ]] ||
  fail "the deb package line names the package and its version" "$deb_package_line"
pass "the deb package line names the package and its version"
