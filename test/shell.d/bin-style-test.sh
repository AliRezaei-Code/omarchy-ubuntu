#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The package layer is excluded because it has to ask which package manager the
# machine has. `menu-snapshot` and `dashboard-tui` are excluded for the same
# shape of reason and a narrower one: they need the *path* to a Node runtime in
# order to exec it, which is what omarchy-cmd-present exists not to do. They ask
# "where is the interpreter", not "is this command available to the user".
raw_command_checks=$(rg -l 'command -v' "$ROOT/bin" \
  | rg -v '/omarchy-(cmd-|pkg-|menu-snapshot|dashboard-tui|upgrade-to-quattro)' || true)
[[ -z $raw_command_checks ]] || fail "bin commands use command helpers" "$raw_command_checks"
pass "bin commands use command helpers"

raw_notifications=$(rg -l -P '^[[:space:]]*[^#[:space:]].*\bnotify-send\b' "$ROOT/bin" || true)
[[ -z $raw_notifications ]] || fail "bin commands use the notification helper, never notify-send" "$raw_notifications"
pass "bin commands use the notification helper"
