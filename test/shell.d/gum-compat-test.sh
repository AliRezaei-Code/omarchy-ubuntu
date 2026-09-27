#!/bin/bash

# The gum shim: a stand-in for a binary jammy does not package, speaking only
# the flag vocabulary this tree actually uses.
#
# The first half of this file is the important half. 40-odd files call gum,
# and a shim that quietly ignored a flag they pass would leave every one of
# those call sites looking fine in a code review and behaving differently on a
# user's machine. So the vocabulary in use is measured out of bin/ on every run
# and has to be a subset of what the shim speaks, and the ones it does not
# speak are pinned by name so that adding a call site fails the build instead.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command perl
require_command script
require_command timeout

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

GUM=$ROOT/packaging/ubuntu/compat/gum

# The subcommands the shim dispatches on. Anything else is refused by name.
HANDLED_SUBCOMMANDS="choose confirm input style"

# The flags the shim translates. Measured from the call sites in bin/, plus
# the ones in install/provisioning/setup-form.sh and
# migrations/1788745941.sh, which run on the installer where there is still no
# desktop to fall back to.
HANDLED_FLAGS="
choose:--cursor.foreground
choose:--header
choose:--height
choose:--selected
confirm:--affirmative
confirm:--default
confirm:--header
confirm:--negative
input:--header
input:--height
input:--password
input:--placeholder
input:--prompt
input:--prompt.foreground
style:--bold
style:--border
style:--foreground
style:--margin
style:--padding
"

# Three call sites in bin/ use flags the shim deliberately does not speak, and
# one uses a whole subcommand. The shim answers each with a loud failure naming
# it, which is the design: an unported call site should show up as a broken
# command, not as a silently different one. Speaking any of them is a
# deliberate edit to the shim and to HANDLED_FLAGS above, and the matching pin
# has to go at the same time.
KNOWN_UNSUPPORTED_SUBCOMMANDS="table" # bin/omarchy-provision-owner:669
KNOWN_UNHANDLED_FLAGS="
input:--char-limit   # bin/omarchy-windows-vm:1207
input:--value        # bin/omarchy-windows-vm:1207
style:--align        # bin/omarchy-windows-vm:1289,1430,1541
"

# --------------------------------------------------------- the vocabulary --
# The measurement, not a fixture: comment lines are dropped, backslash
# continuations are joined so a multi-line gum style is read whole, and the
# scan is quote-aware so a ")" inside --placeholder="N (1-8)" does not look like
# the end of a command substitution and hide the flags behind it.

cat >"$test_tmp/scan.pl" <<'PERL'
use strict;
use warnings;

local $/;
my $text = <STDIN>;

for my $line (split /\n/, $text) {
  while ($line =~ /(?:^|[^[:alnum:]_.\/-])gum\s+([a-z]+)(?=[\s]|$)/g) {
    my $subcommand = $1;
    my $position  = pos($line);
    my $quote     = '';
    my $depth     = 0;
    my @flags;

    for (; $position < length($line); $position++) {
      my $character = substr($line, $position, 1);

      if ($quote ne '') {
        $quote = '' if $character eq $quote;
        next;
      }
      if ($character eq '"' || $character eq "'") {
        $quote = $character;
        next;
      }
      last if $character =~ /[;&|]/;
      if ($character eq '(') { $depth++; next; }
      if ($character eq ')') {
        last if $depth == 0;
        $depth--;
        next;
      }
      next unless $character eq '-';
      next unless substr($line, $position + 1, 1) eq '-';

      my ($flag) = substr($line, $position) =~ /^(--[A-Za-z][A-Za-z0-9_.\-]*)/;
      next unless $flag;
      push @flags, $flag;
      $position += length($flag) - 1;
    }

    # The subcommand is printed on its own first: `gum table -s ,` has no
    # --flags at all, and a scanner that only reports flags would not know the
    # call existed.
    print "$subcommand\n";
    print "$subcommand $_\n" for @flags;
  }
}
PERL

cat >"$test_tmp/logical.awk" <<'AWK'
{
  line = $0
  sub(/^[ \t]+/, "", line)
  if (line ~ /^#/) next
  if (pending != "") { line = pending " " line; pending = "" }
  if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); pending = line; next }
  print line
}
AWK

find "$ROOT/bin" -type f | sort | while read -r file; do
  awk -f "$test_tmp/logical.awk" "$file"
done | perl "$test_tmp/scan.pl" | sort -u >"$test_tmp/in-use"

[[ -s $test_tmp/in-use ]] || fail "bin/ still calls gum somewhere" "no call sites were found"

# The pin lists are written one entry per line with a trailing comment saying
# where the call site is, so the comments come off before the words are split.
words_of() {
  sed 's/#.*//' <<<"$1" | tr -s '[:space:]' '\n' | grep -v '^$' | sort -u
}

# Sort the three vocabularies and let comm do the set arithmetic, so a pin
# cannot drift away from the call site it was written for in either direction.
cut -d' ' -f1 "$test_tmp/in-use" | sort -u >"$test_tmp/used-subcommands"
words_of "$HANDLED_SUBCOMMANDS" >"$test_tmp/handled-subcommands"
words_of "$KNOWN_UNSUPPORTED_SUBCOMMANDS" >"$test_tmp/pinned-subcommands"
cat "$test_tmp/handled-subcommands" "$test_tmp/pinned-subcommands" | sort -u >"$test_tmp/known-subcommands"

comm -23 "$test_tmp/used-subcommands" "$test_tmp/known-subcommands" >"$test_tmp/unaccounted-subcommands"
[[ ! -s $test_tmp/unaccounted-subcommands ]] ||
  fail "every gum subcommand in bin/ is handled or pinned as unsupported" \
    "$(tr '\n' ' ' <"$test_tmp/unaccounted-subcommands")"
pass "every gum subcommand in bin/ is handled or pinned as unsupported"

comm -23 "$test_tmp/pinned-subcommands" "$test_tmp/used-subcommands" >"$test_tmp/stale-subcommands"
[[ ! -s $test_tmp/stale-subcommands ]] ||
  fail "every pinned unsupported subcommand is one bin/ still calls" \
    "nothing in bin/ calls: $(tr '\n' ' ' <"$test_tmp/stale-subcommands")"
pass "every pinned unsupported subcommand is one bin/ still calls"

grep ' ' "$test_tmp/in-use" | awk '{print $1 ":" $2}' | sort -u >"$test_tmp/used-flags"
words_of "$HANDLED_FLAGS" >"$test_tmp/handled-flags"
words_of "$KNOWN_UNHANDLED_FLAGS" >"$test_tmp/pinned-flags"
cat "$test_tmp/handled-flags" "$test_tmp/pinned-flags" | sort -u >"$test_tmp/known-flags"

comm -23 "$test_tmp/used-flags" "$test_tmp/known-flags" >"$test_tmp/unaccounted-flags"
[[ ! -s $test_tmp/unaccounted-flags ]] ||
  fail "every gum flag in bin/ is handled or pinned as unhandled" \
    "unaccounted for: $(tr '\n' ' ' <"$test_tmp/unaccounted-flags")"
pass "every gum flag in bin/ is handled or pinned as unhandled"

comm -23 "$test_tmp/pinned-flags" "$test_tmp/used-flags" >"$test_tmp/stale-flags"
[[ ! -s $test_tmp/stale-flags ]] ||
  fail "every pinned unhandled flag is one bin/ still uses" \
    "nothing in bin/ uses: $(tr '\n' ' ' <"$test_tmp/stale-flags")"
pass "every pinned unhandled flag is one bin/ still uses"

# ------------------------------------------------------ what the shim does --

[[ -x $GUM ]] || fail "the gum shim is executable"

# Every flag the shim claims must survive a real call. A flag that is still
# unrecognised is caught here rather than on a user's screen, and this is the
# direction that also keeps the shim from drifting away from the list above.
while read -r pair; do
  [[ -n $pair ]] || continue
  subcommand="${pair%%:*}"
  flag="${pair#*:}"
  case "$subcommand" in
  style) set -- style "$flag" somevalue "some text" ;;
  confirm) set -- confirm "$flag" somevalue "Question?" ;;
  choose) set -- choose "$flag" somevalue alpha beta ;;
  *) set -- input "$flag" somevalue ;;
  esac
  reply=$("$GUM" "$@" </dev/null 2>&1) || true
  if grep -q 'unhandled flag' <<<"$reply"; then
    fail "the shim speaks $flag" "$reply"
  fi
done <"$test_tmp/handled-flags"
pass "the shim speaks every flag the tree is allowed to use"

# A flag nobody has ported is refused by name, not ignored. This is the whole
# reason the shim is narrow: the failure is the feature.
for subcommand in choose confirm input style; do
  case "$subcommand" in
  style) set -- style --nonesuch value "text" ;;
  confirm) set -- confirm --nonesuch=value "Question?" ;;
  choose) set -- choose --nonesuch value alpha beta ;;
  *) set -- input --nonesuch=value ;;
  esac

  status=0
  reply=$("$GUM" "$@" </dev/null 2>&1) || status=$?
  [[ $status == 64 ]] || fail "gum $subcommand refuses an unknown flag" "got $status" "$reply"
  [[ $reply == *"unhandled flag"* ]] || fail "gum $subcommand names the flag it refused" "$reply"
done
pass "an unrecognised flag exits 64 and is named"

status=0
reply=$("$GUM" table -s ',' </dev/null 2>&1) || status=$?
[[ $status == 64 ]] || fail "an unrecognised subcommand exits 64" "got $status" "$reply"
[[ $reply == *"unhandled subcommand 'table'"* ]] ||
  fail "an unrecognised subcommand is named" "$reply"
pass "gum table is refused by name rather than half-run"

# gum draws on stderr, so a run with no terminal has to say so. The shim
# forwards the primitives' exit 2 unchanged: 1 is a cancel, 2 is nowhere to
# ask, 64 is a mistake in the call site.
for subcommand in choose confirm input style; do
  case "$subcommand" in
  style) set -- style "text" ;;
  confirm) set -- confirm "Question?" ;;
  choose) set -- choose alpha beta ;;
  *) set -- input ;;
  esac
  status=0
  reply=$("$GUM" "$@" </dev/null 2>&1) || status=$?
  if [[ $subcommand == style ]]; then
    [[ $status == 0 ]] || fail "gum style needs no terminal" "got $status" "$reply"
    continue
  fi
  [[ $status == 2 ]] || fail "gum $subcommand reports a missing terminal" "got $status" "$reply"
  [[ $reply == *"terminal"* ]] || fail "gum $subcommand says what is missing" "$reply"
done
pass "the prompting subcommands report a missing terminal with exit 2"

# gum style is pure presentation. There is no renderer here, so the box and the
# colours are dropped and the words are kept, which is what makes the call
# sites that build their own "  - " markers still read correctly.
out=$("$GUM" style --border rounded --padding "1 2" --margin "1 0" --bold --foreground 2 "Reset this computer?")
[[ $out == "Reset this computer?" ]] || fail "gum style keeps the words" "$out"
[[ $out != *"rounded"* && $out != *"bold"* ]] || fail "gum style drops the box and the colour" "$out"

# One operand per line, the way gum lays them out: a call site that passes
# several strings is building a paragraph, and joining them with spaces would
# run it into one unreadable line.
out=$("$GUM" style --padding "0 0 0 4" "  - one" "  - two" "  - three")
[[ $out == "  - one
  - two
  - three" ]] || fail "gum style prints one operand per line" "$out"
pass "gum style drops the presentation and keeps the text"

# ------------------------------------------------------------- end to end --
# A pty, driven by script(1), with the keys held back long enough for the shim's
# child to put the terminal in raw mode first. The child's stdout is redirected
# inside $1, so what lands in $test_tmp/drawn is only the drawing.

PTY_STATUS=0
pty() {
  local command="$1"
  local keys="$2"

  PTY_STATUS=0
  timeout 30 script -qefc "$command" /dev/null \
    < <(sleep 0.4; printf '%b' "$keys") >"$test_tmp/drawn" 2>&1 || PTY_STATUS=$?
  return 0
}

DRAWING=$test_tmp/drawn
VALUE=$test_tmp/value

pty "$GUM choose --header 'Window style' --height 4 --cursor.foreground 5 >$VALUE float tile" $'\x1b[B\r'
[[ $PTY_STATUS == 0 ]] || fail "gum choose answers" "got $PTY_STATUS" "$(<"$DRAWING")"
[[ $(<"$VALUE") == "tile" ]] || fail "gum choose returns the chosen row" "$(<"$VALUE")"
grep -q 'Window style' "$DRAWING" || fail "gum choose draws its header" "$(<"$DRAWING")"
pass "gum choose answers with the chosen row"

pty "printf 'alpha\nbeta\n' | $GUM choose --header 'Select' >$VALUE" $'\r'
[[ $(<"$VALUE") == "alpha" ]] || fail "gum choose reads rows from a pipe" "$(<"$VALUE")"
pass "gum choose reads its rows from stdin"

pty "$GUM choose --header 'Window style' >$VALUE float tile" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "gum choose exits 1 on cancel" "got $PTY_STATUS"
[[ ! -s $VALUE ]] || fail "gum choose prints nothing when cancelled" "$(<"$VALUE")"
pass "gum choose exits 1 on cancel"

pty "$GUM input --prompt 'Name> ' --header 'Who' --prompt.foreground '#845DF9' >$VALUE" 'hello\r'
[[ $PTY_STATUS == 0 ]] || fail "gum input answers" "got $PTY_STATUS"
[[ $(<"$VALUE") == "hello" ]] || fail "gum input returns what was typed" "$(<"$VALUE")"
grep -q 'Who' "$DRAWING" || fail "gum input draws its header" "$(<"$DRAWING")"
pass "gum input returns the typed line"

pty "$GUM input --password --height 20 --placeholder 'admin' >$VALUE" 's3cret\r'
[[ $(<"$VALUE") == "s3cret" ]] || fail "gum input --password returns its value" "$(<"$VALUE")"
! grep -q 's3cret' "$DRAWING" || fail "gum input --password never echoes" "$(<"$DRAWING")"
pass "gum input --password does not echo"

pty "$GUM input --header 'Reminder' >$VALUE" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "gum input exits 1 on cancel" "got $PTY_STATUS"
pass "gum input exits 1 on cancel"

pty "$GUM confirm --affirmative 'Yes, reboot' --negative 'No, keep setting up' 'Reboot this machine?' >$VALUE" 'y'
[[ $PTY_STATUS == 0 ]] || fail "gum confirm answers yes" "got $PTY_STATUS" "$(<"$DRAWING")"
grep -q 'Yes, reboot' "$DRAWING" || fail "gum confirm --affirmative relabels the button" "$(<"$DRAWING")"
pass "gum confirm answers yes"

# The destructive call sites in bin/ all pass --default=false, and what they
# are buying is that a bare enter says no. The shim has to keep that.
pty "$GUM confirm --default=false 'Delete ~/.openclaw?' >$VALUE" '\r'
[[ $PTY_STATUS == 1 ]] || fail "gum confirm --default=false makes enter mean no" "got $PTY_STATUS" "$(<"$DRAWING")"
grep -q 'No' "$DRAWING" || fail "gum confirm --default=false preselects no" "$(<"$DRAWING")"
pass "gum confirm --default=false defaults to no"

pty "$GUM confirm 'Reboot now?' >$VALUE" 'n'
[[ $PTY_STATUS == 1 ]] || fail "gum confirm answers no with exit 1" "got $PTY_STATUS" "$(<"$DRAWING")"
pass "gum confirm answers no"

pty "$GUM confirm 'Reboot now?' >$VALUE" $'\x1b'
[[ $PTY_STATUS == 1 ]] || fail "gum confirm exits 1 when cancelled" "got $PTY_STATUS"
pass "gum confirm exits 1 on cancel, the same as no"
