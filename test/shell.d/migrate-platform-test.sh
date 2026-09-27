#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

omarchy-notification-dismiss() { :; }
export -f omarchy-notification-dismiss

# Three migrations that differ only in their platform line, each writing its
# own marker so a run can show which bodies executed rather than only that
# something did.
make_tree() {
  local root="$1"

  mkdir -p "$root/migrations" "$root/home" "$root/ran"

  cat >"$root/migrations/1000000001.sh" <<'PLAIN'
#!/bin/bash

echo ran >"$OMARCHY_TEST_STATE/1000000001"
PLAIN

  cat >"$root/migrations/1000000002.sh" <<'ARCH'
#!/bin/bash
# omarchy:platform=arch

echo ran >"$OMARCHY_TEST_STATE/1000000002"
ARCH

  cat >"$root/migrations/1000000003.sh" <<'DEB'
#!/bin/bash
# omarchy:platform=deb

echo ran >"$OMARCHY_TEST_STATE/1000000003"
DEB
}

# The backend is named rather than left to detection: a fixture tree has no
# pacman of its own, and which one it resolved to would be a property of the
# machine running the tests rather than of the code under them.
migrate() {
  local root="$1" backend="$2"
  shift 2

  OMARCHY_PKG_BACKEND="$backend" HOME="$root/home" OMARCHY_PATH="$root" \
    OMARCHY_MIGRATION_STATE="$root/markers" OMARCHY_TEST_STATE="$root/ran" \
    OMARCHY_PKG_LOCK="$root/lock" \
    "$@" 2>/dev/null
}

pending() {
  local root="$1" backend="$2"

  OMARCHY_PKG_BACKEND="$backend" HOME="$root/home" OMARCHY_PATH="$root" \
    OMARCHY_MIGRATION_STATE="$root/markers" OMARCHY_TEST_STATE="$root/ran" \
    OMARCHY_PKG_LOCK="$root/lock" \
    "$ROOT/bin/omarchy-migrate" --pending 2>/dev/null
}

# --- what is pending -----------------------------------------------------

arch_tree="$test_tmp/arch"
make_tree "$arch_tree"

listed=$(pending "$arch_tree" arch) || true
[[ $listed == *1000000001.sh* ]] || fail "an unmarked migration is pending on arch" "$listed"
[[ $listed == *1000000002.sh* ]] || fail "an arch migration is pending on arch" "$listed"
[[ $listed != *1000000003.sh* ]] || fail "a deb migration is not pending on arch" "$listed"
pass "arch runs the unmarked and arch migrations and stands down on the deb one"

deb_tree="$test_tmp/deb"
make_tree "$deb_tree"
# dpkg's lock-frontend is a permanent file, so a Debian fixture has one whether
# or not apt is running. pacman's db.lck is not: it appears for the duration of
# a transaction, so the Arch fixture deliberately has none.
: >"$deb_tree/lock"

listed=$(pending "$deb_tree" deb) || true
[[ $listed == *1000000001.sh* ]] || fail "an unmarked migration is pending on deb" "$listed"
[[ $listed == *1000000003.sh* ]] || fail "a deb migration is pending on deb" "$listed"
[[ $listed != *1000000002.sh* ]] || fail "an arch migration is not pending on deb" "$listed"
pass "deb runs the unmarked and deb migrations and stands down on the arch one"

# --- running them --------------------------------------------------------

ran="$arch_tree/ran"
migrate "$arch_tree" arch "$ROOT/bin/omarchy-migrate"
[[ -f $ran/1000000001 ]] || fail "the unmarked migration ran on arch"
[[ -f $ran/1000000002 ]] || fail "the arch migration ran on arch"
[[ ! -f $ran/1000000003 ]] || fail "the deb migration ran on arch"
pass "arch runs exactly the migrations it should"

# A migration skipped for the platform still has to be marked done. One that
# never records itself is re-examined at every login for the rest of the
# machine's life, which is the opposite of what marking it was for.
[[ -f $arch_tree/markers/1000000003.sh ]] ||
  fail "a migration skipped for the platform still leaves its marker"
pass "a skipped migration is marked done, so it is never reconsidered"

ran="$deb_tree/ran"
migrate "$deb_tree" deb "$ROOT/bin/omarchy-migrate"
[[ -f $ran/1000000001 ]] || fail "the unmarked migration ran on deb"
[[ -f $ran/1000000003 ]] || fail "the deb migration ran on deb"
[[ ! -f $ran/1000000002 ]] || fail "the arch migration ran on deb"
[[ -f $deb_tree/markers/1000000002.sh ]] ||
  fail "a migration skipped for the platform still leaves its marker"
pass "deb runs exactly the migrations it should, and marks the rest done"

# --- the lock wait -------------------------------------------------------

# The lock is a file that exists on every Debian install whether apt is running
# or not. Waiting for its *existence* would stall every login for the full
# fifteen minutes on every machine, so what is tested is whether it is held.
unheld="$test_tmp/unheld-lock"
: >"$unheld"

started=$(date +%s)
OMARCHY_PKG_BACKEND=deb HOME="$test_tmp/home" OMARCHY_PATH="$test_tmp/none" \
  OMARCHY_MIGRATION_STATE="$test_tmp/none-markers" OMARCHY_PKG_LOCK="$unheld" \
  timeout 20 "$ROOT/bin/omarchy-migrate" 2>/dev/null || true
elapsed=$(($(date +%s) - started))
(( elapsed < 10 )) || fail "an unheld lock does not make migrations wait" "${elapsed}s"
pass "an unheld lock does not make migrations wait"

# A lock that is genuinely held still is waited on, and the message names the
# transaction it is actually waiting for -- which is the only thing that tells
# a user whether to wait or to go and look.
held="$test_tmp/held-lock"
: >"$held"
flock "$held" sleep 5 &
holder=$!
sleep 0.3

migrate_output=$(OMARCHY_PKG_BACKEND=deb HOME="$test_tmp/home" OMARCHY_PATH="$test_tmp/none" \
  OMARCHY_MIGRATION_STATE="$test_tmp/none-markers" OMARCHY_PKG_LOCK="$held" \
  timeout 3 "$ROOT/bin/omarchy-migrate" 2>&1 || true)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

[[ $migrate_output == *"apt transaction"* ]] ||
  fail "a held lock is waited on and says which transaction" "$migrate_output"
pass "a held lock is waited on and says which transaction"

pacman_output=$(OMARCHY_PKG_BACKEND=arch HOME="$test_tmp/home" OMARCHY_PATH="$test_tmp/none" \
  OMARCHY_MIGRATION_STATE="$test_tmp/none-markers" OMARCHY_PKG_LOCK="$test_tmp/absent-arch-lock" \
  timeout 20 "$ROOT/bin/omarchy-migrate" 2>&1 || true)
[[ $pacman_output != *"pacman transaction"* ]] ||
  fail "an Arch run does not wait for a pacman lock that is not there" "$pacman_output"
pass "an Arch run does not wait for a pacman lock that is not there"

# --- the annotated set is exactly the Arch-coupled one -------------------

# 21 today. The list is the output of grepping the migrations for the Arch
# tools they reach for, and a new Arch-coupled migration nobody marked would
# run on Ubuntu and fail somewhere unrelated to the reason.
arch_coupled=$(grep -lE '\bpacman\b|\bmkinitcpio\b|limine|/etc/pacman|\byay\b|vercmp|alpm|paccache|archinstall|/usr/lib/modules|linux-t2|t2fanrd|/boot/' \
  "$ROOT"/migrations/*.sh | xargs -n1 basename | sed 's/\.sh$//' | sort)

[[ $(wc -l <<<"$arch_coupled") == 21 ]] ||
  fail "the Arch-coupled migration set is still 21" "$(wc -l <<<"$arch_coupled") names"

unmarked=$(while read -r name; do
  if ! head -5 "$ROOT/migrations/$name.sh" | grep -qx '# omarchy:platform=arch'; then
    echo "$name"
  fi
done <<<"$arch_coupled")
[[ -z $unmarked ]] ||
  fail "every Arch-coupled migration is marked" "$unmarked"
pass "every Arch-coupled migration is marked for arch"

# And nothing is marked that does not need it: a marker is a claim, and a
# wrong one silently skips a migration that would have worked.
marked=$(grep -l '^# omarchy:platform=arch$' "$ROOT"/migrations/*.sh |
  xargs -n1 basename | sed 's/\.sh$//' | sort)
marked_but_clean=$(comm -23 <(printf '%s\n' "$marked") <(printf '%s\n' "$arch_coupled"))
[[ -z $marked_but_clean ]] ||
  fail "no migration is marked for arch without touching Arch" "$marked_but_clean"
pass "no migration is marked for arch without touching Arch"
