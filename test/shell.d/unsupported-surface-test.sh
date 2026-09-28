#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Parity means the things that do not carry over are named. A command that
# shells out to a tool the system does not have fails at a line about the tool,
# which tells the user nothing about the thing they asked for and nothing about
# what to do instead. These two commands are where that sentence lives.

# --- omarchy-requires-arch -----------------------------------------------

message="omarchy: 'AUR packages' requires an Arch-based Omarchy system"

status=0
OMARCHY_PKG_BACKEND=deb "$ROOT/bin/omarchy-requires-arch" "AUR packages" 2>"$test_tmp/arch.err" || status=$?
[[ $status == 1 ]] || fail "an Arch-only feature is refused on deb" "exit $status"
[[ $(<"$test_tmp/arch.err") == "$message" ]] ||
  fail "the refusal names the feature and the system" "$(<"$test_tmp/arch.err")"
pass "an Arch-only feature is refused on deb, by name"

status=0
OMARCHY_PKG_BACKEND=arch "$ROOT/bin/omarchy-requires-arch" "AUR packages" 2>"$test_tmp/arch.err" || status=$?
[[ $status == 0 ]] || fail "the same call is a no-op on arch" "exit $status"
[[ ! -s $test_tmp/arch.err ]] || fail "the same call is silent on arch" "$(<"$test_tmp/arch.err")"
pass "the same call is a no-op and silent on arch"

# --- omarchy-requires-tool -----------------------------------------------

reason="ImageMagick 7 is not in the Ubuntu 22.04 archive"

status=0
"$ROOT/bin/omarchy-requires-tool" "tool-that-does-not-exist" "$reason" 2>"$test_tmp/tool.err" || status=$?
[[ $status == 1 ]] || fail "a missing tool is refused" "exit $status"
[[ $(<"$test_tmp/tool.err") == "omarchy: 'tool-that-does-not-exist' is not available: $reason" ]] ||
  fail "the refusal names the tool and why" "$(<"$test_tmp/tool.err")"
pass "a missing tool is refused, naming it and why"

status=0
"$ROOT/bin/omarchy-requires-tool" bash "$reason" 2>"$test_tmp/tool.err" || status=$?
[[ $status == 0 ]] || fail "a tool that is present is a no-op" "exit $status"
[[ ! -s $test_tmp/tool.err ]] || fail "a tool that is present is silent" "$(<"$test_tmp/tool.err")"
pass "a tool that is present is a no-op and silent"

# The helper is run, not sourced: a sourced script inherits the caller's "$@",
# and omarchy-cmd-present loops over it. Sourcing it here would check the
# explanation words instead of the tool -- which passes for the wrong reason
# only while the words happen not to name a command.
status=0
"$ROOT/bin/omarchy-requires-tool" "bash" "this reason is not a command name" 2>"$test_tmp/tool.err" || status=$?
[[ $status == 0 ]] || fail "the reason text is not mistaken for the tool to check" "exit $status"

# --- the commands that use them ------------------------------------------

# Every command that reaches for a tool the target release does not ship has to
# say so before it starts, not after it has half-done its work.
guard_text="# ImageMagick 7. Ubuntu 22.04 packages ImageMagick 6"
for command in omarchy-transcode omarchy-transcode-ascii omarchy-plymouth-set omarchy-plymouth-preview; do
  grep -q 'omarchy-requires-tool' "$ROOT/bin/$command" || fail "$command guards its ImageMagick dependency"
done
pass "every ImageMagick 7 command guards the dependency"

for command in omarchy-transcode omarchy-transcode-ascii; do
  status=0
  "$ROOT/bin/$command" /nonexistent-input /nonexistent-output >/dev/null 2>"$test_tmp/$command.err" || status=$?
  [[ $status == 1 ]] || fail "$command exits 1 without ImageMagick 7" "exit $status"
  grep -q "is not available: ImageMagick 7" "$test_tmp/$command.err" ||
    fail "$command says why it stopped" "$(<"$test_tmp/$command.err")"
done
pass "without ImageMagick 7 those commands stop and say why"

# bar-text-color treats ImageMagick as an enhancement, not a requirement, so it
# must fall back rather than refuse.
grep -q 'omarchy-cmd-present" magick || fallback' "$ROOT/bin/omarchy-bar-text-color" ||
  fail "bar-text-color still falls back without ImageMagick 7"
pass "bar-text-color still falls back rather than refusing"
