#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp" /tmp/upload-log.txt /tmp/system-info.txt' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

pkg_log="$test_tmp/pkg-log"
temp_log="/tmp/upload-log.txt"

cat >"$stub_bin/dpkg-query" <<'STUB'
#!/bin/bash
printf 'dpkg-query %s\n' "$*" >>"$OMARCHY_TEST_LOG"
for arg in "$@"; do
  if [[ $arg == *'${binary:Package} ${Version}\n'* ]]; then
    for package in ${OMARCHY_TEST_PACKAGES:-}; do
      printf '%s 1:2.3-4ubuntu1\n' "$package"
    done
    exit 0
  fi
done
exit 1
STUB

cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$OMARCHY_TEST_LOG"
if [[ $1 == "-Q" && $# -eq 1 ]]; then
  for package in ${OMARCHY_TEST_PACKAGES:-}; do
    printf '%s 1.2-3\n' "$package"
  done
fi
STUB

# The upload itself is not what is under test; only what gets uploaded is.
cat >"$stub_bin/curl" <<'STUB'
#!/bin/bash
printf 'https://logs.omarchy.org/upload\n'
STUB

chmod +x "$stub_bin"/*

export OMARCHY_TEST_LOG="$pkg_log"

run_upload() {
  local backend="$1" packages="$2"

  : >"$pkg_log"
  OMARCHY_PKG_BACKEND="$backend" \
    OMARCHY_TEST_PACKAGES="$packages" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-upload-log" installed
}

# Arch keeps its listing, under a heading that names the backend rather than
# the tool, so the two cannot drift apart.
run_upload arch "omarchy neovim" >/dev/null
arch_section=$(awk '/^INSTALLED PACKAGES/{ p = 1 } p && !/^=+$/{ print }' <<<"$(<"$temp_log")")

[[ $arch_section == *"INSTALLED PACKAGES (arch)"* ]] || fail "arch upload log names its backend in the package heading" "$arch_section"
grep -qx 'omarchy 1.2-3' <<<"$arch_section" || fail "arch upload log lists the installed packages" "$arch_section"
grep -qx 'neovim 1.2-3' <<<"$arch_section" || fail "arch upload log lists every installed package" "$arch_section"
pass "arch upload log lists the installed packages under its backend"

# A Debian bug report must not claim to be a pacman listing.
deb_out=$(run_upload deb "foot neovim")
deb_section=$(awk '/^INSTALLED PACKAGES/{ p = 1 } p && !/^=+$/{ print }' <<<"$(<"$temp_log")")

[[ $deb_section == *"INSTALLED PACKAGES (deb)"* ]] || fail "deb upload log names its backend in the package heading" "$deb_section"
grep -qx 'foot 1:2.3-4ubuntu1' <<<"$deb_section" || fail "deb upload log lists the installed packages" "$deb_section"
grep -qx 'neovim 1:2.3-4ubuntu1' <<<"$deb_section" || fail "deb upload log lists every installed package" "$deb_section"
pass "deb upload log lists the installed packages under its backend"

if grep -q '^pacman ' "$pkg_log"; then
  fail "deb upload log never shells out to pacman" "$(<"$pkg_log")"
fi
pass "deb upload log never shells out to pacman"

# The system information the log is built around is still there, and the upload
# still happens.
grep -q '^SYSTEM INFORMATION$' <<<"$(<"$temp_log")" || fail "deb upload log keeps the system information section" "$(<"$temp_log")"
grep -q 'https://logs.omarchy.org/upload' <<<"$deb_out" || fail "deb upload log still uploads what it collected" "$deb_out"
pass "deb upload log still uploads what it collected"
