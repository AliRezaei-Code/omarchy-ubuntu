#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

pkg_log="$test_tmp/pkg-log"

# dpkg answers a version with nothing but the version, and says nothing at all
# for a package it has never heard of.
cat >"$stub_bin/dpkg-query" <<'STUB'
#!/bin/bash
printf 'dpkg-query %s\n' "$*" >>"$OMARCHY_TEST_LOG"
for arg in "$@"; do
  case ",${OMARCHY_TEST_PACKAGES:-}," in
  *",$arg,"*)
    printf '%s' "${OMARCHY_TEST_VERSION:-4.0.0ubuntu1}"
    exit 0
    ;;
  esac
done
exit 1
STUB

# A Debian bug report that reaches for pacman is a bug in itself, so the
# Arch package manager is here to be caught, not used.
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$OMARCHY_TEST_LOG"
exit 99
STUB

chmod +x "$stub_bin/dpkg-query" "$stub_bin/pacman"

export OMARCHY_PKG_BACKEND=deb
export OMARCHY_TEST_LOG="$pkg_log"

version() {
  : >"$pkg_log"
  OMARCHY_TEST_PACKAGES="$1" \
    OMARCHY_PATH="${2:-/usr/share/omarchy}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version"
}

[[ $(version omarchy) == "4.0.0ubuntu1" ]] || fail "deb version reports the stable package"
pass "deb version reports the stable package"

[[ $(version omarchy-dev) == "4.0.0ubuntu1" ]] || fail "deb version reports the edge package"
pass "deb version reports the edge package"

# Only the stable package is installed, so the edge package is asked first and
# found missing before the stable one answers.
version omarchy >/dev/null
grep -q '^dpkg-query .* omarchy-dev$' "$pkg_log" || fail "deb version asks about the edge package first" "$(<"$pkg_log")"
grep -q '^dpkg-query .* omarchy$' "$pkg_log" || fail "deb version falls back to the stable package" "$(<"$pkg_log")"
pass "deb version asks about the edge package first"

if version "" >/dev/null 2>&1; then
  fail "deb version fails when no Omarchy package is installed"
fi
pass "deb version fails when no Omarchy package is installed"

if grep -q '^pacman ' "$pkg_log"; then
  fail "deb version never shells out to pacman" "$(<"$pkg_log")"
fi
pass "deb version never shells out to pacman"

# A checkout answers with its hash without asking a package manager anything,
# and without needing one to be installed at all.
mkdir -p "$test_tmp/checkout"
if git -C "$test_tmp/checkout" init -q 2>/dev/null; then
  [[ $(version "" "$test_tmp/checkout") == "dev" ]] || fail "deb version reports a dev checkout"
  pass "deb version reports a dev checkout"

  if [[ -s $pkg_log ]]; then
    fail "a checkout asks no package manager anything" "$(<"$pkg_log")"
  fi
  pass "a checkout asks no package manager anything"
else
  skip "git unavailable; cannot make a checkout to report a hash for"
fi

# The packaged path is the one a .deb actually reports from, and it cannot be
# faked by pointing OMARCHY_PATH somewhere else: the script treats any other
# path as a development checkout and reports `dev`. A user namespace with a
# private bind mount is the way to exercise it without root, and when even
# that is unavailable the check stands down rather than pretending to pass.
packaged_root=$(mktemp -d)
mkdir -p "$packaged_root/omarchy"

if unshare -Urm true 2>/dev/null; then
  packaged_version=$(unshare -Urm sh -c "
    mount --bind '$packaged_root' /usr/share 2>/dev/null || exit 90
    printf '4.0.0.alpha\n' > /usr/share/omarchy/version
    OMARCHY_PKG_BACKEND=deb '$ROOT/bin/omarchy-version'
  " 2>/dev/null)
  status=$?

  if (( status == 90 )); then
    skip "the user namespace cannot bind /usr/share; cannot mount a fake packaged tree"
  elif (( status != 0 )); then
    fail "a packaged deb tree reports its version file" "exit $status"
  else
    [[ $packaged_version == "4.0.0.alpha" ]] ||
      fail "a packaged deb tree reports its version file" "$packaged_version"
    pass "a packaged deb tree reports its version file"
  fi

  # A checkout is a different answer, and it wins: whatever the version file
  # says, a tree that is not the packaged one is development.
  checkout_version=$(OMARCHY_PATH="$packaged_root/omarchy" "$ROOT/bin/omarchy-version")
  [[ $checkout_version == dev* ]] ||
    fail "a tree that is not the packaged one reports as development" "$checkout_version"
  pass "a tree that is not the packaged one reports as development"
else
  skip "no user namespaces; cannot mount a fake packaged tree"
fi
