#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The backend is a runtime choice, so the gate that lets a check stand down on
# the other one is part of the contract, not scaffolding. Exercise it in a
# subshell with `skip` stubbed: the real one prints, and `require_backend`
# calls `exit 0`, which would take this file with it.
gate() {
  local requested="$1"
  local wanted="$2"

  OMARCHY_PKG_BACKEND="$requested" ROOT="$ROOT" bash -c '
    source "$ROOT/test/shell.d/base-test.sh"
    skip() { printf "SKIP\t%s\n" "$1"; }
    require_backend "$1" "guarded check"
    printf "RETURN\n"
  ' _ "$wanted"
}

result=$(gate deb deb)
[[ $result == "RETURN" ]] ||
  fail "require_backend proceeds when the backend matches" "$result"
pass "require_backend proceeds when the backend matches"

result=$(gate arch deb)
[[ $result == *"SKIP	backend is arch; skipping guarded check" ]] ||
  fail "require_backend skips, naming the other backend, on a mismatch" "$result"
pass "require_backend skips, naming the other backend, on a mismatch"

# `auto` is the unset case, and it has to resolve the way the runtime resolves
# it -- otherwise a test stands down on a backend the machine is not even on.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

auto_backend() {
  OMARCHY_PKG_BACKEND=auto ROOT="$ROOT" PATH="$1:$PATH" bash -c '
    source "$ROOT/test/shell.d/base-test.sh"
    active_pkg_backend
  '
}

printf '#!/bin/bash\nexit 0\n' >"$stub_dir/pacman"
chmod +x "$stub_dir/pacman"

[[ $(auto_backend "$stub_dir") == "arch" ]] ||
  fail "auto resolves to arch when pacman is present" "$(auto_backend "$stub_dir")"
pass "auto resolves to arch when pacman is present"

# Nothing but a real system directory, so the real dpkg-query is the only
# package manager that can be found and no stub is in reach.
[[ $(auto_backend /nonexistent) == "deb" ]] ||
  fail "auto resolves to deb when pacman is absent" "$(auto_backend /nonexistent)"
pass "auto resolves to deb when pacman is absent"

# An explicit request is a statement about the machine under test, so it has
# to survive both directions of the stub, whatever the host happens to run.
[[ $(OMARCHY_PKG_BACKEND=arch active_pkg_backend) == "arch" ]] ||
  fail "an explicit backend is not overridden by the host's own"
pass "an explicit backend is not overridden by the host's own"

# --- omarchy-pkg-backend -------------------------------------------------

# One stub per package manager, so a test can hand the script a world that has
# pacman, a world that has only dpkg-query, and a world with neither.
arch_dir=$(mktemp -d)
deb_dir=$(mktemp -d)
query_dir=$(mktemp -d)
call_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$arch_dir" "$deb_dir" "$query_dir" "$call_dir"' EXIT

printf '#!/bin/bash\nexit 0\n' >"$arch_dir/pacman"
printf '#!/bin/bash\nexit 0\n' >"$deb_dir/dpkg-query"
chmod +x "$arch_dir/pacman" "$deb_dir/dpkg-query"

# "auto" has to mean "ask the machine", so the request is expressed by not
# setting the variable rather than by setting it to a third value.
backend_output() {
  local path="$1"
  local requested="$2"
  local -a request=()

  [[ $requested != "auto" ]] && request=(OMARCHY_PKG_BACKEND="$requested")

  env -u OMARCHY_PKG_BACKEND "${request[@]}" PATH="$path" \
    "$ROOT/bin/omarchy-pkg-backend" 2>"$arch_dir/stderr"
}

[[ $(backend_output "$arch_dir:$PATH" auto) == "arch" ]] ||
  fail "auto picks arch when pacman is on PATH" "$(<"$arch_dir/stderr")"
pass "auto picks arch when pacman is on PATH"

[[ $(backend_output "$deb_dir:$PATH" auto) == "deb" ]] ||
  fail "auto picks deb when only dpkg-query is on PATH" "$(<"$arch_dir/stderr")"
pass "auto picks deb when only dpkg-query is on PATH"

status=0
backend_output /nonexistent auto || status=$?
[[ $status == 127 ]] || fail "a machine with no package manager exits 127" "exit $status"
[[ $(<"$arch_dir/stderr") == "omarchy-pkg-backend: no supported package manager found (need pacman or dpkg-query)" ]] ||
  fail "a machine with no package manager says which managers it looked for" "$(<"$arch_dir/stderr")"
pass "a machine with no package manager exits 127, naming both managers"

# An explicit request is a statement about the machine under test, so it wins
# over whatever is actually installed -- in both directions.
[[ $(backend_output "$arch_dir:$PATH" deb) == "deb" ]] ||
  fail "an explicit deb wins over an installed pacman" "$(<"$arch_dir/stderr")"
[[ $(backend_output "$deb_dir:$PATH" arch) == "arch" ]] ||
  fail "an explicit arch wins over an installed dpkg-query" "$(<"$arch_dir/stderr")"
pass "an explicit backend wins over the host's own package manager"

status=0
backend_output "$arch_dir:$PATH" gentoo || status=$?
[[ $status == 2 ]] || fail "an unknown backend exits 2" "exit $status"
[[ $(<"$arch_dir/stderr") == "omarchy-pkg-backend: unknown backend 'gentoo' (expected arch, deb)" ]] ||
  fail "an unknown backend names the two that exist" "$(<"$arch_dir/stderr")"
pass "an unknown backend exits 2, naming the two that exist"

# Sourced, the same file has to hand over the functions the pkg-* scripts
# call. Executed, it names the backend and stays out of the way.
defined=$(bash -c 'source "$1"; declare -F | awk "{print \$3}"' _ "$ROOT/bin/omarchy-pkg-backend")
for fn in omarchy_pkg_backend omarchy_pkg_query omarchy_pkg_install omarchy_pkg_remove \
  omarchy_pkg_orphans omarchy_pkg_list omarchy_pkg_available omarchy_pkg_info \
  omarchy_pkg_search omarchy_pkg_version omarchy_pkg_owns omarchy_pkg_owner \
  omarchy_pkg_explicit_list omarchy_pkg_list_all omarchy_pkg_remote_list \
  omarchy_pkg_prune_cache omarchy_pkg_candidate; do
  grep -Fxq "$fn" <<<"$defined" ||
    fail "sourcing omarchy-pkg-backend defines $fn" "$defined"
done
pass "sourcing omarchy-pkg-backend defines the package functions"
[[ $(OMARCHY_PKG_BACKEND=arch bash -c 'source "$1"; omarchy_pkg_backend' _ "$ROOT/bin/omarchy-pkg-backend") == "arch" ]] ||
  fail "a sourced omarchy-pkg-backend still resolves the requested backend"
[[ $(OMARCHY_PKG_BACKEND=deb bash -c 'source "$1"; omarchy_pkg_backend' _ "$ROOT/bin/omarchy-pkg-backend") == "deb" ]] ||
  fail "a sourced omarchy-pkg-backend still resolves the requested backend"
pass "sourcing omarchy-pkg-backend still resolves the active backend"

# --- query parity --------------------------------------------------------

cat >"$query_dir/dpkg-query" <<'STUB'
#!/bin/bash

{ printf 'dpkg-query'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"

case "$1" in
-W) ;;
*) exit 2 ;;
esac

for want in "$@"; do
  case "$want" in
  -*) continue ;;
  neovim) printf 'ii \n' ;;
  bat) printf 'rc \n' ;;
  *) exit 1 ;;
  esac
done
STUB
chmod +x "$query_dir/dpkg-query"

call_log=$(mktemp)
dpkg_query() {
  : >"$call_log"
  OMARCHY_PKG_BACKEND=deb PATH="$query_dir:$PATH" PKG_BACKEND_CALL_LOG="$call_log" \
    "$ROOT/bin/omarchy-pkg-$1" "${@:2}"
}

dpkg_query present neovim ||
  fail "a package dpkg reports as installed is present" "$(<"$call_log")"
grep -Fxq 'dpkg-query <-W> <-f=${db:Status-Abbrev}> <--> <neovim>' "$call_log" ||
  fail "the deb query passes the name after --" "$(<"$call_log")"
pass "an ii status reads as present, through a documented dpkg-query argv"

dpkg_query present bat &&
  fail "a package dpkg reports as removed is not present" "$(<"$call_log")"
dpkg_query missing bat ||
  fail "a package dpkg reports as removed is missing" "$(<"$call_log")"
dpkg_query missing neovim &&
  fail "an installed package is not missing" "$(<"$call_log")"
pass "an rc status reads as missing, and missing inverts present"

# No arguments is not a corner case: the menu's guard batch answers from an
# in-process shadow of these two, and MenuModel.js documents the pair as
# agreeing "including for no arguments at all (present is true of nothing,
# missing is not)". A present that flipped here would silently change what
# the shipped menu shows.
dpkg_query present ||
  fail "present of no packages is true, as the guard snapshot assumes" "$(<"$call_log")"
dpkg_query missing &&
  fail "missing of no packages is false, as the guard snapshot assumes" "$(<"$call_log")"
pass "present and missing agree with the guard snapshot on no arguments"

# --- transaction argv ----------------------------------------------------

cat >"$call_dir/pacman" <<'STUB'
#!/bin/bash

{ printf 'pacman'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"
[[ $1 == "-Qq" ]] && printf '%s\n' exact-package provider-package && exit 0
exit 0
STUB

cat >"$call_dir/apt-get" <<'STUB'
#!/bin/bash

{ printf 'apt-get'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"
[[ $1 == "-s" ]] && exit 0
exit 0
STUB

cat >"$call_dir/dpkg-query" <<'STUB'
#!/bin/bash

{ printf 'dpkg-query'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"

# A name query carries the name after `--` and asks for the status alone; a
# list query asks for status and name together and has nothing to filter on.
if [[ " $* " == *" -f="* && " $* " == *" -W "* ]]; then
  names=()
  for want in "$@"; do
    [[ $want == -* ]] && continue
    names+=("$want")
  done

  if (( ${#names[@]} == 0 )); then
    printf 'ii  exact-package\nii  provider-package\n'
    exit 0
  fi

  for want in "${names[@]}"; do
    case "$want" in
    exact-package | provider-package) printf 'ii \n' ;;
    *) exit 1 ;;
    esac
  done
  exit 0
fi

exit 0
STUB

cat >"$call_dir/sudo" <<'STUB'
#!/bin/bash

{ printf 'sudo'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"
exec "$@"
STUB

cat >"$call_dir/env" <<'STUB'
#!/bin/bash

{ printf 'env'; printf ' <%s>' "$@"; printf '\n'; } >>"$PKG_BACKEND_CALL_LOG"

# Real env takes VAR=value pairs before the command and sets them itself.
# `exec` cannot, so do what env does and run whatever is left.
while (( $# )) && [[ $1 == *=* && $1 != -* ]]; do
  export "$1"
  shift
done

exec "$@"
STUB

cat >"$call_dir/omarchy-pkg-missing" <<'STUB'
#!/bin/bash

exit 0
STUB

chmod +x "$call_dir"/*

transaction() {
 : >"$call_log"
 OMARCHY_PKG_BACKEND="$1" PATH="$call_dir:$PATH" PKG_BACKEND_CALL_LOG="$call_log" \
   "$ROOT/bin/omarchy-pkg-$2" "${@:3}"
}

transaction arch add exact-package
grep -Fxq 'pacman <-S> <--noconfirm> <--needed> <--> <exact-package>' "$call_log" ||
  fail "the arch backend installs through the argv it always did" "$(<"$call_log")"
pass "the arch backend installs through the argv it always did"

transaction deb add exact-package
grep -Fxq 'apt-get <install> <-y> <--no-install-recommends> <exact-package>' "$call_log" ||
  fail "the deb backend installs non-interactively" "$(<"$call_log")"
grep -Fxq 'env <DEBIAN_FRONTEND=noninteractive> <apt-get> <install> <-y> <--no-install-recommends> <exact-package>' "$call_log" ||
  fail "the deb backend answers apt's own prompts without a tty" "$(<"$call_log")"
grep -Fxq 'sudo <env> <DEBIAN_FRONTEND=noninteractive> <apt-get> <install> <-y> <--no-install-recommends> <exact-package>' "$call_log" ||
  fail "the deb backend installs through sudo" "$(<"$call_log")"
pass "the deb backend installs non-interactively through sudo"

transaction arch drop exact-package provider-package
grep -Fxq 'pacman <-Rns> <--noconfirm> <exact-package> <provider-package>' "$call_log" ||
  fail "the arch backend removes through the argv it always did" "$(<"$call_log")"
pass "the arch backend removes through the argv it always did"

# apt's remove does not cascade the way pacman's -Rns does, so a full drop has
# to ask for the autoremove itself -- but only then, because a partial drop
# must not take the dependencies of a package the caller did not name.
transaction deb drop exact-package provider-package
grep -Fxq 'apt-get <remove> <-y> <--purge> <--autoremove> <exact-package> <provider-package>' "$call_log" ||
  fail "a full deb drop purges and prunes" "$(<"$call_log")"

transaction deb drop exact-package absent-package
grep -Fxq 'apt-get <remove> <-y> <--purge> <exact-package>' "$call_log" ||
  fail "a partial deb drop drops only what is installed" "$(<"$call_log")"
[[ $(grep -c '^apt-get' "$call_log") == 1 ]] ||
  fail "a partial deb drop is a single transaction" "$(<"$call_log")"
pass "the deb backend removes only installed packages, cascading on a full drop"
