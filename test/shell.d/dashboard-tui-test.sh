#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A snapshot small enough to reason about and shaped like the real one: a root
# with children, a submenu, an action, a link, and a submenu with nothing in
# it. The empty submenu is the case that decides what Enter does on a row the
# user can select but cannot act on.
snapshot_fixture="$test_tmp/snapshot.json"
cat >"$snapshot_fixture" <<'JSON'
{
  "route": "root",
  "tree": {
    "id": "root", "kind": "submenu", "label": "Omarchy", "title": "", "depth": 0, "path": "",
    "children": [
      {"id": "style", "kind": "submenu", "label": "Style", "title": "Style", "depth": 1, "path": "style",
       "children": [
         {"id": "style.theme", "kind": "submenu", "label": "Theme", "depth": 2, "path": "style.theme",
          "children": [
            {"id": "style.theme.nord", "kind": "action", "label": "Nord", "action": "omarchy-theme-set nord", "depth": 3, "path": "style.theme.nord", "children": []}
          ]},
         {"id": "style.font", "kind": "submenu", "label": "Font", "depth": 2, "path": "style.font", "children": []}
       ]},
      {"id": "install.vim", "kind": "action", "label": "Vim", "action": "omarchy-install-vim", "disabled": true, "depth": 1, "path": "install.vim", "children": []},
      {"id": "setup.terminal", "kind": "link", "label": "Terminal", "target": "setup.terminal.ghostty", "depth": 1, "path": "setup.terminal",
       "children": [
         {"id": "setup.terminal.ghostty", "kind": "action", "label": "Ghostty", "action": "omarchy-install-ghostty", "depth": 2, "path": "setup.terminal.ghostty", "children": []}
       ]}
    ]
  }
}
JSON
export SNAPSHOT_FIXTURE="$snapshot_fixture"

run_node_test <<'JS'
const tui = requireFromRoot('shell/plugins/menu/TuiModel.js')
const fs = require('fs')

const snapshot = JSON.parse(fs.readFileSync(process.env.SNAPSHOT_FIXTURE, 'utf8'))

function model() {
  return tui.create({ snapshot: snapshot })
}

// The rows at a level are that level's children, in the order the snapshot has
// them, and nothing else -- a level is never the parent again after descending.
let m = model()
assertDeepEqual(m.rows().map(r => r.id), ['style', 'install.vim', 'setup.terminal'],
  'the top level is the root children, in order')
assertEqual(m.cursor(), 0, 'the cursor starts on the first row')

// Wrapping is what makes a list feel like a loop rather than a trap: j on the
// last row has to come back to the top, and k on the first row to the bottom.
m.nextRow(1)
assertEqual(m.cursor(), 1, 'nextRow moves down one row')
m.nextRow(1)
m.nextRow(1)
assertEqual(m.cursor(), 0, 'nextRow wraps past the last row to the first')
m.nextRow(-1)
assertEqual(m.cursor(), 2, 'nextRow wraps back past the first row to the last')
m.nextRow(0)
assertEqual(m.cursor(), 2, 'nextRow with no movement stays put')

// An empty level cannot move a cursor, and a crash there would take the whole
// TUI down on a submenu a guard just emptied.
const empty = tui.create({ snapshot: { route: 'root', tree: { id: 'root', kind: 'submenu', label: 'Root', children: [] } } })
assertDeepEqual(empty.rows(), [], 'an empty level has no rows')
empty.nextRow(1)
empty.nextRow(-1)
assertEqual(empty.cursor(), 0, 'an empty level leaves the cursor alone')
assertEqual(empty.current(), null, 'an empty level has no current row')

// Descending and coming back are the whole navigation loop, and the path is
// what has to survive so the caller can act on where the user is.
m = model()
m.nextRow(1); m.nextRow(1)
assertEqual(m.current().id, 'setup.terminal', 'the cursor can reach a link')
assertEqual(m.descend(), false, 'a link is not a level to enter')
assertDeepEqual(m.path(), [], 'entering a link does not change the level')

m = model()
m.descend()
assertDeepEqual(m.path(), ['style'], 'descend pushes the level it entered')
assertDeepEqual(m.rows().map(r => r.id), ['style.theme', 'style.font'], 'descend shows that level rows')
m.descend()
assertDeepEqual(m.path(), ['style', 'style.theme'], 'descend pushes again')
assertDeepEqual(m.rows().map(r => r.id), ['style.theme.nord'], 'descend reaches a leaf level')
m.descend()
assertDeepEqual(m.path(), ['style', 'style.theme'], 'descending a leaf does not push')

m.back()
assertDeepEqual(m.path(), ['style'], 'back pops one level')
m.back()
assertDeepEqual(m.path(), [], 'back returns to the top')
m.back()
assertDeepEqual(m.path(), [], 'back at the top stays at the top')

// What Enter does. A row the user cannot act on has to say so rather than
// running nothing and looking broken.
m = model()
assertEqual(m.actionFor(m.rows()[0]), null, 'a submenu is not an action')
assertEqual(m.actionFor(m.rows()[1]), 'omarchy-install-vim', 'an action row is its own action')
assertEqual(m.actionFor(m.rows()[2]), 'omarchy-install-ghostty',
  'a link runs whatever its target runs')

const fontRow = { id: 'style.font', kind: 'submenu', label: 'Font', children: [] }
assertEqual(m.actionFor(fontRow), null, 'an empty submenu has no action to run')

// A disabled row is still listed -- the menu dims it rather than hiding it --
// but it is not something Enter may run.
assert(m.rows()[1].disabled, 'a disabled row keeps its disabled state')
assertEqual(m.actionFor(m.rows()[1]), 'omarchy-install-vim',
  'the caller decides whether a disabled row runs, not the model')

// Search ranks through the same scorer the launcher and the shell use, so a
// query that finds something in the launcher finds it here.
m = model()
m.setQuery('vim')
assertDeepEqual(m.rows().map(r => r.id), ['install.vim'], 'a query filters to the matching row')
assertEqual(m.cursor(), 0, 'a query puts the cursor on the best match')
m.setQuery('style')
assertDeepEqual(m.rows().map(r => r.id), ['style'], 'a query that matches a submenu keeps it')
m.setQuery('zzzz')
assertDeepEqual(m.rows(), [], 'a query matching nothing leaves no rows')
m.nextRow(1)
assertEqual(m.current(), null, 'a query matching nothing has no current row')
m.setQuery('')
assertEqual(m.rows().length, 3, 'clearing the query restores every row')

// A refresh happens under the user's hands: guards re-evaluate, a package
// appears or disappears, a submenu empties. The cursor has to survive that by
// path, because a row's index is not a thing that survives a rebuild.
const before = JSON.parse(JSON.stringify(snapshot))
m = model()
m.descend()
assertDeepEqual(m.path(), ['style'], 'the cursor is inside a submenu before the refresh')

const after = JSON.parse(JSON.stringify(before))
// A new row sorts in above the one the cursor is on, at the level the user is
// actually looking at. An index-based cursor would silently land on it.
after.tree.children[0].children = [
  { id: 'style.apps', kind: 'submenu', label: 'Apps', depth: 2, path: 'style.apps', children: [] }
].concat(after.tree.children[0].children)

m.guardRefresh(after)
assertDeepEqual(m.rows().map(r => r.id), ['style.apps', 'style.theme', 'style.font'],
  'a refresh brings in the new rows')
assertEqual(m.current().id, 'style.theme', 'the cursor stays on the same row by path, not by index')
assertDeepEqual(m.path(), ['style'], 'a refresh keeps the level the user is on')

// The refreshed label is what gets read, not the copy the model was built
// with -- a guard flipping a row's name is exactly the kind of change a
// refresh exists to show.
const renamed = JSON.parse(JSON.stringify(before))
renamed.tree.children[0].children[0].label = 'Colour scheme'
m = model()
m.descend()
m.guardRefresh(renamed)
assertEqual(m.current().label, 'Colour scheme', 'the cursor reads the refreshed label')

// A row that went away must not leave the cursor pointing past the end.
// Every package behind the rows goes away, so the level the user is standing
// in is empty when the guards come back.
const gone = JSON.parse(JSON.stringify(before))
gone.tree.children[0].children = []
m = model()
m.descend()
m.guardRefresh(gone)
assertEqual(m.current(), null, 'a refresh that empties the level leaves no current row')
assertEqual(m.cursor(), 0, 'an emptied level puts the cursor back at the start')
JS

# --- the wrapper ----------------------------------------------------------

# The two messages below are the whole contract for a box with no Node or no
# terminal, and both are pinned because a user hitting either one is the only
# evidence they will ever get that the TUI exists.

wrapper="$ROOT/bin/omarchy-dashboard-tui"
[[ -x $wrapper ]] || fail "omarchy-dashboard-tui is executable"
pass "omarchy-dashboard-tui is executable"

out=""
status=0
"$wrapper" </dev/null >"$test_tmp/tty.out" 2>"$test_tmp/tty.err" || status=$?
[[ $status == 2 ]] || fail "a non-terminal launch exits 2" "exit $status: $(<"$test_tmp/tty.out")"
[[ $(<"$test_tmp/tty.err") == "omarchy-dashboard-tui: needs an interactive terminal; use 'omarchy menu snapshot' for machine-readable output" ]] ||
  fail "a non-terminal launch says what to use instead" "$(<"$test_tmp/tty.err")"
pass "a non-terminal launch exits 2 and names the machine-readable alternative"

node_dir="$test_tmp/empty-bin"
mkdir -p "$node_dir"
for tool in bash env cat sed dirname basename; do
  [[ -e /usr/bin/$tool ]] && ln -sf "/usr/bin/$tool" "$node_dir/$tool"
done

no_node=""
status=0
no_node=$(
  PATH="$node_dir" OMARCHY_NODE="" bash "$wrapper" </dev/null 2>&1
) || status=$?
[[ $no_node == "omarchy-dashboard-tui: no Node.js runtime found. Install one with: omarchy install node-runtime" ]] ||
  fail "a box with no Node says how to get one" "$no_node (exit $status)"
pass "a box with no Node says how to get one"

# The TUI model itself has to be loadable by the runtime the box actually has.
# Jammy's nodejs is 12; anything newer than ES5 would parse here and fail there.
OMARCHY_PATH="$ROOT" node -e 'require(process.env.OMARCHY_PATH + "/shell/plugins/menu/TuiModel.js")' ||
  fail "the TUI model loads as CommonJS"
if command -v node >/dev/null && [[ $(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))') -lt 12 ]]; then
  skip "the local node is older than the 12 the target ships"
else
  pass "the TUI model is ES5 the target's node can parse"
fi

# --- a real terminal ------------------------------------------------------
#
# The model is tested without one, which proves it decides correctly and proves
# nothing about whether the user can get out of it. So: drive the real binary
# in a PTY and press the keys a user presses. A `script` timeout is the
# assertion that matters most here -- a TUI that cannot be left is a hung
# terminal, and a hung terminal looks exactly like a passing test that
# captured no output.

pty_root="$test_tmp/pty"
mkdir -p "$pty_root/bin"
cat >"$pty_root/bin/omarchy" <<'STUB'
#!/bin/bash
[[ $1 == menu ]] || exit 1
cat "$SNAPSHOT_FILE"
STUB
chmod +x "$pty_root/bin/omarchy"

cat >"$test_tmp/pty-snapshot.json" <<'SNAPSHOT'
{"route":"root","tree":{"id":"root","kind":"submenu","label":"Omarchy","children":[
 {"id":"style","kind":"submenu","label":"Style","path":"style","children":[
  {"id":"style.theme","kind":"submenu","label":"Theme","path":"style.theme","children":[
   {"id":"style.theme.nord","kind":"action","label":"Nord","action":"echo NORD-RAN","path":"style.theme.nord","children":[]}]},
  {"id":"style.font","kind":"submenu","label":"Font","path":"style.font","children":[]}]},
 {"id":"install.vim","kind":"action","label":"Vim","action":"echo VIM-RAN","disabled":true,"path":"install.vim","children":[]}]}}
SNAPSHOT

require_command script

run_tui() {
  printf '%b' "$1" |
    timeout 30 env OMARCHY_PATH="$pty_root" SNAPSHOT_FILE="$test_tmp/pty-snapshot.json" \
      script -qefc "$ROOT/bin/omarchy-dashboard-tui" /dev/null 2>&1
}

# Escape followed by q routinely arrives in one read, and an arrow key is
# three bytes. Losing either leaves the user in a terminal they cannot leave,
# so the keys are sent the way a terminal delivers them.
tui_out=$(run_tui '\rjj\x1bq') || fail "the TUI quits on q" "exit $?"
strip_ansi() {
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][A-Z0-9]//g'
}

seen=$(strip_ansi <<<"$tui_out" | grep -oE 'Omarchy|Style|Theme|Font' | sort -u | tr '\n' ' ')
[[ $seen == *"Style"* && $seen == *"Theme"* && $seen == *"Font"* ]] ||
  fail "the TUI descends into a submenu and shows its rows" "saw: $seen"
pass "the TUI descends into a submenu, moves, comes back, and quits"

# Enter on a row with an action runs it. A model that computes the right
# command and a front end that never runs it are both "working" until someone
# presses the key.
action_out=$(run_tui '\r\r\r') || fail "the TUI exits after running an action" "exit $?"
grep -q 'NORD-RAN' <<<"$action_out" ||
  fail "Enter on an action row runs that action" "$(strip_ansi <<<"$action_out" | tail -3)"
pass "Enter on an action row runs that action"

# A row that is already installed is listed, dimmed, and not runnable: a
# confirm prompt the user did not ask for is worse than a refusal.
disabled_out=$(run_tui 'j\rq') || fail "the TUI exits after refusing a disabled row" "exit $?"
grep -q 'VIM-RAN' <<<"$disabled_out" &&
  fail "Enter never runs a row that is already installed" "$disabled_out"
grep -q 'already installed' <<<"$disabled_out" ||
  fail "refusing a disabled row says why" "$(strip_ansi <<<"$disabled_out" | tail -3)"
pass "Enter never runs a row that is already installed, and says why"
