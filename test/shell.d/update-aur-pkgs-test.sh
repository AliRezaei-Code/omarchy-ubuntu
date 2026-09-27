#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
export AUR_LOG="$test_tmp/aur.log"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-pkg-aur-accessible" <<'SH'
#!/bin/bash
printf 'queried\n' >>"$AUR_LOG"
exit "${AUR_ACCESSIBLE:-0}"
SH

cat >"$stub_bin/yay" <<'SH'
#!/bin/bash
printf 'yay %s\n' "$*" >>"$AUR_LOG"
SH

chmod +x "$stub_bin/omarchy-pkg-aur-accessible" "$stub_bin/yay"

run_aur_phase() {
  local backend="$1"

  OMARCHY_PKG_BACKEND="$backend" OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-aur-pkgs" >"$test_tmp/stdout" 2>"$test_tmp/stderr"
}

: >"$AUR_LOG"
run_aur_phase arch
grep -q 'Update AUR packages' "$test_tmp/stdout" ||
  fail "arch AUR phase announces itself" "$(<"$test_tmp/stdout")"
grep -Fq "yay -Sua --noconfirm --cleanafter --ignore gcc14,gcc14-libs" "$AUR_LOG" ||
  fail "arch AUR phase upgrades with the same yay transaction" "$(<"$AUR_LOG")"
pass "arch AUR phase upgrades AUR packages with yay"

# omarchy update runs this phase after revoking its own authorization, so the
# no-update sudo wrapper has to reach yay the same way it always has.
: >"$AUR_LOG"
OMARCHY_SUDO_NO_UPDATE=1 run_aur_phase arch
grep -Fq -- "--sudo $ROOT/default/omarchy/sudo-no-update/sudo --sudoloop=false" "$AUR_LOG" ||
  fail "AUR builds still run through the no-update sudo wrapper" "$(<"$AUR_LOG")"
pass "AUR builds keep the no-update sudo wrapper"

: >"$AUR_LOG"
AUR_ACCESSIBLE=1 run_aur_phase arch
grep -q '^AUR is unavailable' "$test_tmp/stdout" ||
  fail "an unreachable AUR is reported instead of upgraded" "$(<"$test_tmp/stdout")"
grep -q '^yay ' "$AUR_LOG" && fail "an unreachable AUR is not upgraded" "$(<"$AUR_LOG")"
pass "an unreachable AUR is skipped rather than upgraded"

# deb has no AUR to skip: the phase has to stand down quietly and let the rest
# of the update run, so it says why on stderr and exits successfully.
: >"$AUR_LOG"
run_aur_phase deb || fail "the deb AUR phase fails the update" "$(<"$test_tmp/stderr")"
[[ ! -s $test_tmp/stdout ]] || fail "the deb AUR phase announces itself" "$(<"$test_tmp/stdout")"
grep -Fx 'The AUR is only available on Arch-based Omarchy' "$test_tmp/stderr" >/dev/null ||
  fail "the deb AUR phase says why it stands down" "$(<"$test_tmp/stderr")"
[[ ! -s $AUR_LOG ]] || fail "the deb AUR phase reaches for the AUR" "$(<"$AUR_LOG")"
pass "the deb AUR phase stands down without touching the AUR"

: >"$AUR_LOG"
OMARCHY_SUDO_NO_UPDATE=1 run_aur_phase deb || fail "the deb AUR phase fails the update" "$(<"$test_tmp/stderr")"
[[ ! -s $AUR_LOG ]] || fail "the deb AUR phase reaches for the AUR" "$(<"$AUR_LOG")"
pass "the deb AUR phase stands down under the no-update sudo wrapper too"
