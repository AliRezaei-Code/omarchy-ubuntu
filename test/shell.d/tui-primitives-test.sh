#!/bin/bash

# The three headless primitives that stand in for a gum dialog: a picker, a
# line editor and a yes/no question. Everything they promise is exercised
# through a pty, because every promise except the refusal depends on a
# terminal -- a red run here means the primitives cannot be driven by a person.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command script
require_command timeout

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A pty, driven by script(1) -- the same tool test/shell.d/remove-ai-test.sh
# uses to make -t 0 answer true. The caller redirects the child's stdout
# inside $1, so what lands in $test_tmp/drawn is only the drawing the
# primitives write to stderr.
#
# The keys are held back briefly so the child has already put the terminal in
# raw mode by the time they arrive. Sent immediately, the pty echoes them into
# the drawing, and a password that must not echo would look like one that did.
# The child's exit status lands in PTY_STATUS rather than in the function's own,
# because most of what is checked here is a question that was cancelled, and a
# test file that dies on the first non-zero it did not expect proves nothing
# about the ones after it.
PTY_STATUS=0
pty() {
  local command="$1"
  local keys="$2"
  local delay="${3:-0.35}"

  PTY_STATUS=0
  timeout 30 script -qefc "$command" /dev/null \
    < <(sleep "$delay"; printf '%b' "$keys") >"$test_tmp/drawn" 2>&1 || PTY_STATUS=$?
  return 0
}

DRAWING=$test_tmp/drawn
VALUE=$test_tmp/value

# ---------------------------------------------------------------- refusals --
# A picker that cannot be driven must say so and stop, not block on a question
# nobody can see and not guess. Exit 2 is that answer, and the message names
# both the command and the side that is missing, so a caller can tell "there
# is no terminal" from "the user said no" (1) and from "that was a mistake"
# (64).

status=0
message=$("$ROOT/bin/omarchy-tui-choose" alpha beta </dev/null 2>&1) || status=$?
[[ $status == 2 ]] || fail "choose refuses a non-interactive run" "got $status"
[[ $message == "omarchy-tui-choose: "* ]] || fail "choose names itself when it refuses" "$message"
[[ $message == *"terminal"* ]] || fail "choose says what is missing" "$message"
pass "choose refuses a non-interactive run with exit 2"

status=0
message=$("$ROOT/bin/omarchy-tui-input" </dev/null 2>&1) || status=$?
[[ $status == 2 ]] || fail "input refuses a non-interactive run" "got $status"
[[ $message == "omarchy-tui-input: "* && $message == *"terminal"* ]] ||
  fail "input names itself and the missing terminal" "$message"
pass "input refuses a non-interactive run with exit 2"

status=0
message=$("$ROOT/bin/omarchy-tui-confirm" "Question?" </dev/null 2>&1) || status=$?
[[ $status == 2 ]] || fail "confirm refuses a non-interactive run" "got $status"
[[ $message == "omarchy-tui-confirm: "* && $message == *"terminal"* ]] ||
  fail "confirm names itself and the missing terminal" "$message"
pass "confirm refuses a non-interactive run with exit 2"

# 64 is the answer to a wrong command line, and it is a different answer from
# a cancel, so a caller that only checks "non-zero" still behaves and a caller
# that cares can tell the two apart.
status=0
"$ROOT/bin/omarchy-tui-choose" --nonsense alpha >/dev/null 2>&1 || status=$?
[[ $status == 64 ]] || fail "an unknown option is a usage error, not a cancel" "got $status"
pass "an unrecognised option exits 64 rather than 1"

status=0
"$ROOT/bin/omarchy-tui-confirm" </dev/null >/dev/null 2>&1 || status=$?
[[ $status == 64 ]] || fail "confirm without a question is a usage error" "got $status"
pass "confirm without a question exits 64"

# ------------------------------------------------------------------ choose --


pty "$ROOT/bin/omarchy-tui-choose --header 'Pick one' >$VALUE alpha beta gamma" '\r'
[[ $(<"$VALUE") == "alpha" ]] || fail "enter takes the row under the cursor" "$(<"$VALUE")"
grep -q 'Pick one' "$DRAWING" || fail "the header is drawn" "$(<"$DRAWING")"
pass "choose returns the row under the cursor"

pty "$ROOT/bin/omarchy-tui-choose >$VALUE alpha beta gamma" $'\x1b[B\r'
[[ $(<"$VALUE") == "beta" ]] || fail "down moves to the second row" "$(<"$VALUE")"
pass "choose moves down a row"

pty "$ROOT/bin/omarchy-tui-choose >$VALUE alpha beta gamma" $'\x1b[B\x1b[B\r'
[[ $(<"$VALUE") == "gamma" ]] || fail "down down reaches the third row" "$(<"$VALUE")"
pass "choose moves down twice"

# The filter is a case-insensitive substring match, which is the whole of the
# promise; a fuzzy matcher is not being built here.
pty "$ROOT/bin/omarchy-tui-choose >$VALUE Alpha beta GAMMA" 'GAM\r'
[[ $(<"$VALUE") == "GAMMA" ]] || fail "the filter ignores case" "$(<"$VALUE")"
pass "choose filters case-insensitively"

pty "$ROOT/bin/omarchy-tui-choose >$VALUE alpha beta gamma" 'a\r'
[[ $(<"$VALUE") == "alpha" ]] || fail "the filter narrows to matching rows" "$(<"$VALUE")"
pass "choose filters on a substring"

pty "$ROOT/bin/omarchy-tui-choose >$VALUE alpha beta gamma" $' \x1b[B \r'
[[ $(<"$VALUE") == $'alpha\nbeta' ]] || fail "marked rows come back in input order" "$(<"$VALUE")"
pass "choose returns every marked row in input order"

pty "$ROOT/bin/omarchy-tui-choose --selected gamma >$VALUE alpha beta gamma" '\r'
[[ $(<"$VALUE") == "gamma" ]] || fail "--selected opens on the row it names" "$(<"$VALUE")"
pass "choose honours --selected"

pty "$ROOT/bin/omarchy-tui-choose >$VALUE alpha beta gamma" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "a cancel exits 1" "got $PTY_STATUS"
[[ ! -s $VALUE ]] || fail "a cancel prints nothing" "$(<"$VALUE")"
pass "choose exits 1 and prints nothing on cancel"

# A tab separates a row's label from its subtext, and the value the caller gets
# back keeps it. bin/omarchy-menu-select depends on that to tell same-named
# rows apart.
printf 'a\tb\tc\n' >"$test_tmp/rows-file"
pty "$ROOT/bin/omarchy-tui-choose >$VALUE <$test_tmp/rows-file" $'\r'
[[ $(<"$VALUE") == $'a\tb\tc' ]] || fail "a tab-separated row keeps its tab in the value" "$(<"$VALUE")"
pass "choose returns a label and subtext as one value"

# ------------------------------------------------------------------- input --

pty "$ROOT/bin/omarchy-tui-input --prompt 'Name> ' >$VALUE" 'hello\r'
[[ $(<"$VALUE") == "hello" ]] || fail "the typed line is the value" "$(<"$VALUE")"
grep -q 'Name> ' "$DRAWING" || fail "the prompt is drawn" "$(<"$DRAWING")"
pass "input returns the line that was typed"

pty "$ROOT/bin/omarchy-tui-input --header 'Who are you' --prompt 'Name> ' >$VALUE" 'hello\r'
grep -q 'Who are you' "$DRAWING" || fail "the header is drawn" "$(<"$DRAWING")"
! grep -q 'Who are you' "$VALUE" || fail "the header stays off the value" "$(<"$VALUE")"
pass "input draws its header on stderr, not on the value"

# The placeholder is what gum's is: ghost text while the line is empty, and the
# value an untouched line submits. That is what makes "press enter to use the
# default" prompts work.
pty "$ROOT/bin/omarchy-tui-input --placeholder 'docker' >$VALUE" '\r'
[[ $(<"$VALUE") == "docker" ]] || fail "an untouched line takes the placeholder" "$(<"$VALUE")"
pass "input submits the placeholder for an untouched line"

pty "$ROOT/bin/omarchy-tui-input --placeholder 'docker' >$VALUE" 'podman\r'
[[ $(<"$VALUE") == "podman" ]] || fail "typing replaces the placeholder" "$(<"$VALUE")"
pass "input drops the placeholder once the line has text"

pty "$ROOT/bin/omarchy-tui-input --placeholder 'docker' >$VALUE" $'\x7f\r'
[[ $(<"$VALUE") == "docker" ]] || fail "backspacing back to empty restores the placeholder" "$(<"$VALUE")"
pass "input restores the placeholder after a backspace"

# A password is drawn as dots. The characters themselves must not reach the
# terminal, the file, or the value.
pty "$ROOT/bin/omarchy-tui-input --password --prompt 'Password> ' >$VALUE" 's3cret\r'
[[ $(<"$VALUE") == "s3cret" ]] || fail "a password still returns its value" "$(<"$VALUE")"
! grep -q 's3cret' "$DRAWING" || fail "a password is never echoed" "$(<"$DRAWING")"
grep -q '\*\*\*\*\*\*' "$DRAWING" || fail "a password is drawn as dots" "$(<"$DRAWING")"
pass "input masks a password and does not echo it"

pty "$ROOT/bin/omarchy-tui-input >$VALUE" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "a cancelled line exits 1" "got $PTY_STATUS"
[[ ! -s $VALUE ]] || fail "a cancelled line prints nothing" "$(<"$VALUE")"
pass "input exits 1 and prints nothing on cancel"

# ----------------------------------------------------------------- confirm --

pty "$ROOT/bin/omarchy-tui-confirm 'Reboot now?' >$VALUE" 'y'
[[ $PTY_STATUS == 0 ]] || fail "yes exits 0" "got $PTY_STATUS"
grep -q 'Reboot now? Yes' "$DRAWING" || fail "y answers yes" "$(<"$DRAWING")"
pass "confirm exits 0 for yes"

pty "$ROOT/bin/omarchy-tui-confirm 'Reboot now?' >$VALUE" 'n'
[[ $PTY_STATUS == 1 ]] || fail "no exits 1" "got $PTY_STATUS"
grep -q 'Reboot now? No' "$DRAWING" || fail "n answers no" "$(<"$DRAWING")"
pass "confirm exits 1 for no"

# gum's unqualified --default selects the affirmative button, and the six
# destructive call sites in bin/ only earn `--default=false` if that is the
# case: a flag nobody writes would otherwise change nothing.
pty "$ROOT/bin/omarchy-tui-confirm 'Reboot now?' >$VALUE" '\r'
grep -q 'Reboot now? Yes' "$DRAWING" || fail "enter takes the default, which is yes" "$(<"$DRAWING")"
pass "confirm defaults to yes"

pty "$ROOT/bin/omarchy-tui-confirm --default=false 'Delete data?' >$VALUE" '\r'
[[ $PTY_STATUS == 1 ]] || fail "--default=false makes enter mean no, which is exit 1" "got $PTY_STATUS"
grep -q 'Delete data? No' "$DRAWING" || fail "--default=false makes enter mean no" "$(<"$DRAWING")"
pass "confirm --default=false defaults to no"

# The user can still say yes after --default=false; the flag picks what enter
# does, not what is allowed.
pty "$ROOT/bin/omarchy-tui-confirm --default=false 'Delete data?' >$VALUE" 'y'
grep -q 'Delete data? Yes' "$DRAWING" || fail "y overrides the default" "$(<"$DRAWING")"
pass "confirm --default=false still allows an explicit yes"

pty "$ROOT/bin/omarchy-tui-confirm --default=false 'Delete data?' >$VALUE" $'\x1b[C\r'
grep -q 'Delete data? Yes' "$DRAWING" || fail "the right arrow moves to yes" "$(<"$DRAWING")"
pass "confirm moves the selection with the arrow keys"

# gum draws no value on stdout for a question, so neither does this: the answer
# is the exit status, and a caller reading stdout gets nothing to misread.
pty "$ROOT/bin/omarchy-tui-confirm 'Reboot now?' >$VALUE" 'y'
[[ ! -s $VALUE ]] || fail "confirm writes its answer nowhere but the exit status" "$(<"$VALUE")"
pass "confirm keeps stdout empty"

pty "$ROOT/bin/omarchy-tui-confirm --affirmative 'Yes, reboot' --negative 'No, keep setting up' 'Reboot this machine?' >$VALUE" 'y'
grep -q 'Yes, reboot' "$DRAWING" || fail "--affirmative relabels the yes button" "$(<"$DRAWING")"
grep -q 'No, keep setting up' "$DRAWING" || fail "--negative relabels the no button" "$(<"$DRAWING")"
pass "confirm honours --affirmative and --negative"

pty "$ROOT/bin/omarchy-tui-confirm 'Reboot now?' >$VALUE" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "a cancelled question exits 1" "got $PTY_STATUS"
grep -q 'Reboot now? cancelled' "$DRAWING" || fail "esc cancels" "$(<"$DRAWING")"
pass "confirm exits 1 on cancel, the same as no"

# ------------------------------------------------------------ menu fallback --
# With no shell to draw it, omarchy-menu-select and omarchy-menu-input have to
# land on the primitives, because every picker in the tree is built on them.
# The probe is omarchy-shell's own, so a Quickshell that is merely starting
# still takes the shell path.

cat >"$test_tmp/no-shell.sh" <<EOF
export PATH="$ROOT/bin:\$PATH"
omarchy-menu-select Pick alpha beta gamma
EOF

pty "bash '$test_tmp/no-shell.sh' >$VALUE" $'\x1b[B\r'
[[ $(<"$VALUE") == "beta" ]] || fail "menu-select picks through the fallback" "$(<"$VALUE")"
pass "omarchy-menu-select picks through the primitive when no shell is running"

pty "bash '$test_tmp/no-shell.sh' >$VALUE" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "menu-select still exits 1 on cancel" "got $PTY_STATUS"
[[ ! -s $VALUE ]] || fail "menu-select still cancels with nothing on stdout" "$(<"$VALUE")"
pass "omarchy-menu-select exits 1 on cancel through the fallback"

# A glyph is dropped and a subtext comes back with the label, which is the
# contract the comment at the top of bin/omarchy-menu-select describes.
printf '1\tAlpha\n2\tBeta\tsome detail\n' >"$test_tmp/glyphs"
cat >"$test_tmp/glyph-select.sh" <<EOF
export PATH="$ROOT/bin:\$PATH"
omarchy-menu-select Pick <"$test_tmp/glyphs"
EOF
pty "bash '$test_tmp/glyph-select.sh' >$VALUE" $'\x1b[B\r'
[[ $(<"$VALUE") == $'Beta\tsome detail' ]] ||
  fail "menu-select returns label and subtext without the glyph" "$(<"$VALUE")"
pass "omarchy-menu-select keeps the label and subtext, drops the glyph"

cat >"$test_tmp/no-shell-input.sh" <<EOF
export PATH="$ROOT/bin:\$PATH"
omarchy-menu-input 'Reminder in minutes'
EOF
pty "bash '$test_tmp/no-shell-input.sh' >$VALUE" '45\r'
[[ $(<"$VALUE") == "45" ]] || fail "menu-input reads through the fallback" "$(<"$VALUE")"
pass "omarchy-menu-input reads through the primitive when no shell is running"

# The shell path treats an empty selection as a cancel (it tests the selection
# file with -s), and docs/menu.md documents the same, so the fallback has to
# keep it.
pty "bash '$test_tmp/no-shell-input.sh' >$VALUE" '\r'
[[ $PTY_STATUS == 1 ]] || fail "an empty line exits 1, as it does through the shell" "got $PTY_STATUS"
[[ ! -s $VALUE ]] || fail "an empty line is a cancel, as it is through the shell" "$(<"$VALUE")"
pass "omarchy-menu-input treats an empty line as a cancel"
