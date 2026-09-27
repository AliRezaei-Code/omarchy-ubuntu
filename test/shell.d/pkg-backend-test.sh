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
