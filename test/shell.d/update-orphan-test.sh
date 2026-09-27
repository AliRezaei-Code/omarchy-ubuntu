#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command script

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
export ORPHAN_LOG="$test_tmp/remove-command"
test_home="$test_tmp/home"
mkdir -p "$stub_bin" "$test_home"

write_stub() {
  local name="$1"
  local body="$2"

  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

run_orphan_checker() {
  local backend="$1"

  HOME="$test_home" OMARCHY_PKG_BACKEND="$backend" PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-orphan-pkgs"
}

# The interactive half only runs behind a terminal, so it is driven through a
# pseudo-terminal rather than by faking one of the descriptors.
run_orphan_checker_interactively() {
  local backend="$1"

  HOME="$test_home" OMARCHY_PKG_BACKEND="$backend" PATH="$stub_bin:$PATH" \
    script -qec "$ROOT/bin/omarchy-update-orphan-pkgs" /dev/null
}

write_stub sudo 'printf "%s\n" "$*" >"$ORPHAN_LOG"; exit 0'
write_stub gum 'exit 0'

# Arch: pacman reports the orphans, and nothing is removed without a terminal.
write_stub pacman 'if [[ $1 == "-Qtdq" ]]; then printf "old-lib\nunused-tool\n"; exit 0; fi; exit 1'
run_orphan_checker arch >"$test_tmp/noninteractive.out" 2>"$test_tmp/noninteractive.err"
grep -q '^  old-lib$' "$test_tmp/noninteractive.out" || fail "orphan checker lists orphan packages"
grep -q 'Re-run omarchy-update-orphan-pkgs in a terminal' "$test_tmp/noninteractive.out" || fail "orphan checker does not remove packages non-interactively"
pass "orphan checker only reports orphans non-interactively"

write_stub pacman 'if [[ $1 == "-Qtdq" ]]; then exit 0; fi; exit 1'
run_orphan_checker arch >"$test_tmp/none.out" 2>"$test_tmp/none.err"
[[ ! -s $test_tmp/none.out ]] || fail "orphan checker stays quiet when no orphans exist"
pass "orphan checker stays quiet without orphans"

# Confirmed interactively, the same list is handed to the transaction.
write_stub pacman 'if [[ $1 == "-Qtdq" ]]; then printf "old-lib\nunused-tool\n"; exit 0; fi; exit 1'

run_orphan_checker_interactively arch >"$test_tmp/arch-remove.out" 2>&1
grep -Fx 'pacman -Rns --noconfirm old-lib unused-tool' "$ORPHAN_LOG" >/dev/null ||
  fail "arch orphan removal keeps the pacman transaction" "$(<"$ORPHAN_LOG")"
pass "arch orphan removal removes the reported packages with pacman"

# deb: an apt autoremove simulation is the orphan list, and the transaction has
# to ask for the pruning itself because apt's remove does not cascade.
write_stub apt-get '
if [[ $* == "-s autoremove" ]]; then
  printf "Inst old-lib [6.0.0-1] (5.0.0-1 Ubuntu:22.04/stable [amd64])\n"
  printf "Inst unused-tool [2.2-1] (2.1-1 Ubuntu:22.04/stable [amd64])\n"
  printf "Conf old-lib (5.0.0-1 Ubuntu:22.04/stable [amd64])\n"
fi
exit 0'
write_stub pacman 'echo "pacman must not run on deb" >&2; exit 99'

run_orphan_checker deb >"$test_tmp/deb.out" 2>"$test_tmp/deb.err"
grep -q '^  old-lib$' "$test_tmp/deb.out" || fail "deb orphan checker lists simulated autoremove packages" "$(<"$test_tmp/deb.out")"
grep -q '^  unused-tool$' "$test_tmp/deb.out" || fail "deb orphan checker lists every simulated autoremove package" "$(<"$test_tmp/deb.out")"
grep -q 'Re-run omarchy-update-orphan-pkgs in a terminal' "$test_tmp/deb.out" || fail "deb orphan checker does not remove packages non-interactively"
pass "deb orphan checker reports apt's autoremove simulation instead of removing"

run_orphan_checker_interactively deb >"$test_tmp/deb-remove.out" 2>&1
grep -Fx 'env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge --autoremove old-lib unused-tool' "$ORPHAN_LOG" >/dev/null ||
  fail "deb orphan removal prunes the dependencies it leaves behind" "$(<"$ORPHAN_LOG")"
pass "deb orphan removal cascades the way pacman's -Rns does"

write_stub apt-get 'exit 0'
run_orphan_checker deb >"$test_tmp/deb-none.out" 2>"$test_tmp/deb-none.err"
[[ ! -s $test_tmp/deb-none.out ]] || fail "deb orphan checker stays quiet when apt would remove nothing" "$(<"$test_tmp/deb-none.out")"
pass "deb orphan checker stays quiet when apt would remove nothing"
