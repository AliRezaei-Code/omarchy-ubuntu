#!/bin/bash

# The shared menu model, driven the way the front ends will drive it.
#
# `omarchy menu snapshot` is what the GTK app and the TUI both read, so every
# claim made here is a claim about a contract those two share with the
# Quickshell shell. The assertions run against the real
# default/omarchy/omarchy-menu.jsonc rather than a fixture: a snapshot that
# only ever describes a toy menu is a snapshot whose bugs stay invisible until
# the dashboard is open.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

SNAPSHOT_CMD="$ROOT/bin/omarchy-menu-snapshot"
SNAPSHOT_JS="shell/plugins/menu/MenuSnapshot.js"

# A HOME of our own, so the user's overlay is never part of the answer and the
# file-based guards in the shipped menu all read the same way on every machine.
snapshot_home=$(mktemp -d)
stub_dir=$(mktemp -d)
deb_home=$(mktemp -d)
font_home=$(mktemp -d)
provider_home=$(mktemp -d)
trap 'rm -rf "$snapshot_home" "$stub_dir" "$deb_home" "$font_home" "$provider_home"' EXIT

export HOME="$snapshot_home"

# --- the resolved tree, guards off -----------------------------------------
#
# With no guard evaluation every `when:` is unevaluated, so nothing is hidden
# and the tree is the whole shipped menu: the catalog a front end renders from
# before it knows anything about this machine.

run_node_test <<'JS'
const fs = require('fs')
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')

const model_snapshot = model.buildSnapshot({ root, guards: false })

// The key set is the contract both front ends are written against, so it is
// spelled out rather than inferred from whatever the builder happens to emit.
const NODE_KEYS = [
  'action', 'checked', 'children', 'depth', 'description', 'disabled', 'icon',
  'id', 'kind', 'label', 'path', 'provider', 'route', 'target', 'title'
]

function walk(node, visit) {
  visit(node)
  const children = node.children || []
  for (const child of children) walk(child, visit)
}

function collect(node, out) {
  walk(node, node => out.push(node))
  return out
}

const nodes = collect(model_snapshot.tree, [])

assert(!model_snapshot.error, 'the shipped menu resolves without an error', model_snapshot.error)
assertEqual(model_snapshot.root, 'root', 'the snapshot is rooted at the menu root')
assertEqual(model_snapshot.route, 'root', 'an empty route resolves to the root')
assertDeepEqual(model_snapshot.guards, { evaluated: false, count: 0 }, 'guards report themselves unevaluated')
assertDeepEqual(model_snapshot.providers, { resolved: false, errors: {} }, 'providers report themselves unresolved')

const shipped = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
assert(
  nodes.length === shipped.length + 1,
  'every entry the shipped menu declares is in the tree, plus the injected root',
  `tree: ${nodes.length} shipped: ${shipped.length}`
)
assert(nodes.length > 300, `the shipped menu resolves to more than 300 nodes (${nodes.length})`)
assertDeepEqual(
  Object.keys(model_snapshot.tree).slice().sort(),
  NODE_KEYS,
  'a tree node carries exactly the documented fields'
)

assertEqual(model_snapshot.tree.kind, 'submenu', 'the root is a submenu')

const apps = model_snapshot.tree.children.find(node => node.id === 'apps')
assert(!!apps, 'the Apps submenu is at the root of the tree')
assertEqual(apps.kind, 'submenu', 'Apps resolves as a submenu')
assertEqual(apps.provider, 'apps', 'Apps carries the provider name it points at')
assertDeepEqual(apps.children, [], 'the apps provider contributes no rows outside the shell')

// Depth and path are the shell's own, so a row's position survives a rebuild
// in a front end that holds a cursor by path.
const theme = nodes.find(node => node.id === 'style.theme')
assertEqual(theme.depth, 1, 'Style > Theme sits one level below the root')
assertEqual(theme.path, 'Style › Theme', 'Style > Theme carries the path the shell shows')
assertEqual(theme.kind, 'action', 'a row with an action is an action')
assertEqual(theme.route, 'style.theme', 'an action routes to itself')

const link = model_snapshot.tree.children.find(node => node.id === 'setup')
assertEqual(link.kind, 'submenu', 'a row with children is a submenu')

// Every install row stays listed with a boolean, which is what makes Install a
// catalog of what Omarchy can install rather than a list of what is missing.
const install = nodes.filter(node => node.id.startsWith('install.'))
assert(
  install.length > 0 && install.every(node => typeof node.disabled === 'boolean'),
  'every install row that survives carries a boolean disabled'
)
assert(
  install.every(node => node.disabled === false),
  'with no guard evaluated every install row is selectable'
)
assert(
  install.every(node => typeof node.checked === 'boolean'),
  'every install row carries a boolean checked'
)

// Remove is the other half of the convention, and it is the opposite one: a
// row is hidden when there is nothing to remove, and never dimmed. So what
// decides a remove row's presence is its `when:`, and reading the JSONC says
// which rows are exempt -- Remove > Package and Remove > Theme are commands
// that are meaningful whether or not the thing is installed.
const removeIds = Object.keys(model_snapshot.items).filter(id => id.startsWith('remove.'))
assert(
  removeIds.length > 0 && removeIds.every(id => !model_snapshot.items[id].disabled),
  'no remove row is gated by disabled:'
)
assertDeepEqual(
  removeIds.filter(id => model_snapshot.items[id].action && !model_snapshot.items[id].when),
  ['remove.package', 'remove.theme'],
  'every remove action is gated by a when: except the two that are always meaningful'
)
const ungated = removeIds.filter(id => !model_snapshot.items[id].action && !model_snapshot.items[id].when)
assert(
  ungated.length > 0
    && ungated.every(id => {
      const node = nodes.find(node => node.id === id)
      return !!node && node.kind === 'submenu' && node.children.length > 0
    }),
  'the remove rows with no guard of their own are categories, which stay as long as a child does'
)
assert(
  nodes.filter(node => node.id.startsWith('remove.')).every(node => node.when === undefined),
  'a resolved row reports guard results, not the guard expressions'
)
JS

# --- the same tree, guards evaluated ---------------------------------------
#
# One batch, one process: MenuModel builds the script and the answers come
# back as <id>:<w|c|d>:<0|1> lines, exactly as the shell reads them.

run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

const evaluated = model.buildSnapshot({ root })

function ids(node, out) {
  for (const child of node.children || []) {
    out.push(child.id)
    ids(child, out)
  }
  return out
}

const present = ids(evaluated.tree, [])

assert(!evaluated.error, 'the shipped menu resolves with guards evaluated', evaluated.error)
assert(evaluated.guards.evaluated, 'the guard batch reports that it ran')
assert(
  evaluated.guards.count > 100,
  `the guard batch answers for the whole shipped menu at once (${evaluated.guards.count} answers)`
)
assert(!evaluated.guards.error, 'the guard batch finished cleanly', evaluated.guards.error)
assert(['arch', 'deb'].includes(evaluated.backend), `the snapshot names a package backend (${evaluated.backend})`)
assert(
  present.length < 300,
  `guards actually hide something (${present.length} of a full catalog survive)`
)
assert(
  ['style.theme', 'install.editor.vim', 'setup.default.editor'].every(id => present.includes(id)),
  'rows with no when: survive the guards'
)
JS

# The frontend's backend resolution has to agree with the package layer's, or
# a snapshot can name one backend while its guards answered from the other.
machine_backend=$(active_pkg_backend)
export MACHINE_BACKEND="$machine_backend"

# --- the deb backend, and the name map the guard batch reads ---------------
#
# Debian is a rename, not a second catalog: `nvim` is `neovim` and a guard
# written against the Arch name has to read as the real command reads, or the
# two front ends disagree about the same row.

mkdir -p "$deb_home/.config/omarchy/extensions"
cat >"$deb_home/.config/omarchy/extensions/omarchy-menu.jsonc" <<'JSONC'
{
  // A row that exists only to ask the batch a question the shipped menu
  // already asks in its own words.
  "backendcheck": {"label":"Backend"},
  "backendcheck.nvim": {"label":"Neovim is installed","when":"omarchy-pkg-present nvim","action":"true"},
  "backendcheck.unsupported": {"label":"Declared unsupported","when":"omarchy-pkg-present expac","action":"true"},
}
JSONC

# RetroArch is installed, Lutris is not. One of each is the whole point: a
# guard that always said the same thing would pass a test that only checked one
# side of it.
cat >"$stub_dir/dpkg-query" <<'STUB'
#!/bin/bash
installed=" retroarch fprintd neovim zed "

for arg in "$@"; do
  case "$arg" in
  *'${binary:Package}'*)
    printf '%s\n' $installed
    exit 0
    ;;
  esac
done

for want in "$@"; do
  case "$want" in
  -*) continue ;;
  *)
    if [[ " $installed " == *" $want "* ]]; then
      printf 'ii \n'
      exit 0
    fi
    printf 'rc \n'
    exit 1
    ;;
  esac
done

exit 0
STUB
chmod +x "$stub_dir/dpkg-query"

# The frontend's backend resolution has to agree with the package layer's, or
# a snapshot can name one backend while its guards answered from the other.
machine_backend=$(active_pkg_backend)

HOME="$deb_home" OMARCHY_PKG_BACKEND=deb PATH="$stub_dir:$PATH" run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

const snapshot = model.buildSnapshot({ root })

function find(node, id) {
  if (node.id === id) return node
  for (const child of node.children || []) {
    const hit = find(child, id)
    if (hit) return hit
  }
  return null
}

assertEqual(snapshot.backend, 'deb', 'the snapshot names the deb backend when the batch is pinned to it')
assert(snapshot.guards.evaluated, 'guards evaluate on deb as well as on arch')
assert(!snapshot.guards.error, 'the deb guard batch finished cleanly', snapshot.guards.error)

// The same row, asked both ways, from the real shipped menu.
const retroarch = find(snapshot.tree, 'install.gaming.retroarch')
const lutris = find(snapshot.tree, 'install.gaming.lutris')
assert(!!retroarch, 'an install row for an installed package stays listed')
assertEqual(retroarch.disabled, true, 'an installed package dims its install row')
assertEqual(lutris.disabled, false, 'a package that is not installed leaves its install row selectable')

// Remove is the mirror image: the row is there exactly when there is something
// to remove.
assert(!!find(snapshot.tree, 'remove.gaming.retroarch'), 'a remove row appears for software that is installed')
assert(!find(snapshot.tree, 'remove.gaming.lutris'), 'a remove row for absent software stays hidden')

// The overlay merges the way the shell merges it, and the batch resolves names
// through the map rather than asking about the Arch spelling.
assert(!!find(snapshot.tree, 'backendcheck'), 'a user extension joins the shipped menu')
assert(!!find(snapshot.tree, 'backendcheck.nvim'), 'a guard asking for nvim sees the installed neovim')
assert(!find(snapshot.tree, 'backendcheck.unsupported'), 'a package with no Ubuntu equivalent is absent')
JS

# Unpinned, the resolution is the machine's -- the same answer the package
# layer gives, derived independently.
HOME="$deb_home" PATH="$stub_dir:$PATH" run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

const snapshot = model.buildSnapshot({ root })

assertEqual(snapshot.backend, process.env.MACHINE_BACKEND, 'the snapshot resolves the same backend the package layer does')
assert(snapshot.guards.evaluated, 'guards evaluate on the machine-selected backend')
JS

# --- providers -------------------------------------------------------------
#
# fonts and power-profiles are bash one-liners emitting `label\tvalue\tcurrent`.
# They run here exactly as the shell runs them, and their rows merge through
# the same swap, so a font installed a minute ago reads the same in both.

mkdir -p "$font_home"
cat >"$stub_dir/omarchy-font-current" <<'STUB'
#!/bin/bash
printf 'Fira Code\n'
STUB
cat >"$stub_dir/omarchy-font-list" <<'STUB'
#!/bin/bash
printf 'Meslo LG Mono\nFira Code\nFira-Code\n'
STUB
chmod +x "$stub_dir/omarchy-font-current" "$stub_dir/omarchy-font-list"

# A provider that cannot answer must not take the menu with it.
mkdir -p "$provider_home/.config/omarchy/extensions"
cat >"$provider_home/.config/omarchy/extensions/omarchy-menu.jsonc" <<'JSONC'
{
  "broken": {"label":"Broken"},
  "broken.rows": {"label":"Rows","provider":"no-such-provider"},
}
JSONC

HOME="$font_home" PATH="$stub_dir:$PATH" run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

const snapshot = model.buildSnapshot({ root, providers: true })

function find(node, id) {
  if (node.id === id) return node
  for (const child of node.children || []) {
    const hit = find(child, id)
    if (hit) return hit
  }
  return null
}

const font = find(snapshot.tree, 'style.font')
assert(!!font, 'a provider-backed submenu stays in the tree whether or not it has rows')
assertEqual(snapshot.providers.resolved, true, 'the snapshot reports that providers were resolved')
assertDeepEqual(
  Object.keys(snapshot.providers.errors),
  ['apps'],
  'a provider that answers contributes no error; only the QML-native one is reported'
)

const rows = font.children
assertEqual(rows.length, 3, 'every row the provider printed is merged')
assertDeepEqual(
  rows.map(row => row.id),
  ['style.font.meslo-lg-mono', 'style.font.fira-code', 'style.font.fira-code-'],
  'a row id is <menuId>.<slugify(value)>, nudged on collision so no row is dropped'
)
assertDeepEqual(
  rows.map(row => row.label),
  ['Meslo LG Mono', 'Fira Code', 'Fira-Code'],
  'the provider supplies the label'
)
assertEqual(rows[1].icon, '✓', 'the row whose value is current takes the ✓')
assertEqual(rows[0].icon, '', 'every other row takes the provider icon')
assertEqual(rows[2].icon, '', 'a colliding value is still the provider icon, not the marker')
assertDeepEqual(
  rows.map(row => row.action),
  ['omarchy-font-set \'Meslo LG Mono\'', 'omarchy-font-set \'Fira Code\'', 'omarchy-font-set \'Fira-Code\''],
  'a provider row runs the spec actionFor(value) with the value shell-quoted'
)
assertEqual(rows[1].kind, 'action', 'a provider row is an action')
assertEqual(rows[1].provider, '', 'a provider row is not itself provider-backed')
assertEqual(rows[1].path, 'Style › Font › Fira Code', 'a provider row carries its path')
assertDeepEqual(snapshot.providers.errors.apps ? [snapshot.providers.errors.apps] : [],
  ['apps: provider is QML-native (shell AppLibrary); no rows outside the Quickshell shell'],
  'the apps provider is reported rather than silently answered with a different catalog'
)
JS

HOME="$provider_home" PATH="$stub_dir:$PATH" run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

const snapshot = model.buildSnapshot({ root, providers: true })

assert(!snapshot.error, 'a provider that cannot answer does not fail the snapshot', snapshot.error)
assert(!!snapshot.tree, 'the menu is still a tree when a provider fails')
assert(!!snapshot.tree.children.find(node => node.id === 'style'), 'the rest of the menu survives a failed provider')
assert(
  Object.keys(snapshot.providers.errors).includes('broken.rows'),
  'the submenu whose provider failed is named in providerErrors'
)
assert(
  snapshot.providers.errors['broken.rows'].includes('no-such-provider'),
  'the failure says which provider it was',
  snapshot.providers.errors['broken.rows']
)
const broken = snapshot.tree.children.find(node => node.id === 'broken')
assert(!!broken, 'the category holding a broken provider still appears')
const brokenRows = broken.children.find(node => node.id === 'broken.rows')
assert(!!brokenRows, 'a submenu with a broken provider is still in the tree')
assertEqual(brokenRows.kind, 'submenu', 'a provider-backed submenu is a submenu even with nothing in it')
assertEqual(brokenRows.provider, 'no-such-provider', 'the row still names the provider it asked for')
assertDeepEqual(brokenRows.children, [], 'a submenu with a broken provider has no rows to show')
JS

# Which tree gets read is a question with an order to it, and a packaged
# install and a checkout answer it differently: $OMARCHY_PATH names a packaged
# tree, $ROOT names a checkout. Both have to reach the same file, and both have
# to fail the same way when the file is not there.
broken_tree=$(mktemp -d)
OMARCHY_PATH="$broken_tree" run_node_test <<'JS'
const model = requireFromRoot('shell/plugins/menu/MenuSnapshot.js')

// $ROOT is what a harness pins and $OMARCHY_PATH is what a packaged install
// sets, so with the first one absent the second has to be the one that names
// the tree -- and both have to fail the same way when the file is not there.
const pinned = process.env.ROOT
process.env.ROOT = ''
const fromEnvironment = model.buildSnapshot({ guards: false })
process.env.ROOT = pinned

const fromRoot = model.buildSnapshot({ root: process.env.OMARCHY_PATH, guards: false })
const fromOmarchyPath = model.buildSnapshot({ omarchyPath: process.env.OMARCHY_PATH, guards: false })

assert(
  !!fromEnvironment.error && fromEnvironment.error.includes('omarchy-menu.jsonc'),
  'OMARCHY_PATH locates the tree when ROOT is not set',
  fromEnvironment.error
)
assertEqual(fromRoot.error, fromEnvironment.error, 'root and OMARCHY_PATH name the same tree')
assertEqual(fromOmarchyPath.error, fromEnvironment.error, 'omarchyPath overrides the tree it is handed')
assertEqual(fromRoot.tree, null, 'a tree that cannot be read is an error, not an empty menu')
JS

# --- the command -----------------------------------------------------------

check_output=$("$ROOT/bin/omarchy" commands --check 2>&1) ||
  fail "omarchy commands --check passes with the snapshot command installed" "$check_output"
pass "omarchy commands --check passes with the snapshot command installed"

[[ $check_output == *"Command metadata check passed"* ]] ||
  fail "omarchy commands --check reports success" "$check_output"
pass "omarchy commands --check reports success"

route_record=$("$ROOT/bin/omarchy" commands --json | jq -r '
  .commands[] | select(.binary == "omarchy-menu-snapshot") |
  [ .route, .group, .name, .summary ] | @tsv
')
assert_equal_route() {
  local description="$1" actual="$2" expected="$3"

  [[ $actual == "$expected" ]] || fail "$description" "expected: $expected
actual:   $actual"
  pass "$description"
}

assert_equal_route "omarchy-menu-snapshot registers as 'omarchy menu snapshot'" \
  "$(cut -f1 <<<"$route_record")" "omarchy menu snapshot"
assert_equal_route "omarchy-menu-snapshot joins the existing menu group" \
  "$(cut -f2 <<<"$route_record")" "menu"
assert_equal_route "omarchy-menu-snapshot is named snapshot within the group" \
  "$(cut -f3 <<<"$route_record")" "snapshot"
assert_equal_route "omarchy-menu-snapshot carries an explicit summary" \
  "$(cut -f4 <<<"$route_record")" "Print the fully-resolved Omarchy menu tree as JSON"

# Every omarchy-* command finds its tree through $OMARCHY_PATH, so a checkout
# has to name its own -- the packaged path has nothing under it here.
snapshot_json() {
  OMARCHY_PATH="$ROOT" "$SNAPSHOT_CMD" "$@"
}


# --no-guards answers from the two JSONC files and nothing else, so it is the
# one form of this output that can be compared byte for byte.
first_run=$(snapshot_json --no-guards)
second_run=$(snapshot_json --no-guards)
[[ $first_run == "$second_run" ]] ||
  fail "--no-guards output is byte-identical across two runs"
pass "--no-guards output is byte-identical across two runs"

echo "$first_run" | jq -e '.root == "root" and .route == "root"' >/dev/null ||
  fail "the default output is JSON naming the root route"
pass "the default output is JSON naming the root route"

[[ $(echo "$first_run" | wc -l) -eq 1 ]] ||
  fail "the default output is compact JSON on one line"
pass "the default output is compact JSON on one line"

pretty_json=$(snapshot_json --no-guards --pretty)
[[ $(echo "$pretty_json" | wc -l) -gt 10 ]] ||
  fail "--pretty indents the JSON"
pass "--pretty indents the JSON"

echo "$pretty_json" | jq -e '.tree.id == "root"' >/dev/null ||
  fail "--pretty output parses as the same JSON"
pass "--pretty output parses as the same JSON"

jq -S . <<<"$first_run" >/dev/null ||
  fail "the default output parses as JSON"
pass "the default output parses as JSON"

# A route resolves to a subtree, not to a copy of the whole menu.
route_node=$(snapshot_json --route=style.theme)
assert_equal_route "--route resolves the named node" \
  "$(echo "$route_node" | jq -r '.tree.id')" "style.theme"
assert_equal_route "--route names the route it resolved" \
  "$(echo "$route_node" | jq -r '.route')" "style.theme"
assert_equal_route "--route of a leaf is a leaf" \
  "$(echo "$route_node" | jq -r '.tree.children | length')" "0"
assert_equal_route "the root is still the menu root, whatever the route" \
  "$(echo "$route_node" | jq -r '.root')" "root"

style_children=$(snapshot_json --route=style | jq -r '[.tree.children[].id] | join(",")')
[[ ,${style_children}, == *,style.theme,* ]] ||
  fail "--route=style returns the style subtree, which contains style.theme" "got: $style_children"
pass "--route=style returns the style subtree, which contains style.theme"

# The whole point of the guard batch is that the shipped menu's hundreds of
# questions cost one process rather than one each. A stub `bash` that records
# every invocation and then hands over to the real one counts them, which is
# the only way to see the number rather than infer it from the runtime.
counter_dir=$(mktemp -d)
: >"$counter_dir/calls"
cat >"$counter_dir/bash" <<'STUB'
#!/bin/bash
printf 'bash\n' >>"$BASH_CALLS"
exec /bin/bash "$@"
STUB
chmod +x "$counter_dir/bash"

count_bash_calls() {
  : >"$counter_dir/calls"
  BASH_CALLS="$counter_dir/calls" HOME="$snapshot_home" PATH="$counter_dir:$PATH" \
    OMARCHY_PATH="$ROOT" "$SNAPSHOT_CMD" "$@" >/dev/null
  wc -l <"$counter_dir/calls"
}

assert_equal_route "the guard batch is one process for the whole menu" \
  "$(count_bash_calls)" "1"
assert_equal_route "no guards means no guard process" \
  "$(count_bash_calls --no-guards)" "0"
assert_equal_route "each provider costs one process of its own" \
  "$(count_bash_calls --providers)" "2"

# Paging a full menu is the most ordinary thing anyone will do with it, and a
# closed pipe is the reader's decision rather than a failure of the command.
pipe_status=0
pipe_output=$(snapshot_json --no-guards 2>&1 | head -c 200) || pipe_status=$?
assert_equal_route "a closed pipe is not a failure" "$pipe_status" "0"
[[ $pipe_output != *"EPIPE"* && $pipe_output != *"throw"* ]] ||
  fail "a closed pipe does not print a stack trace" "got: $pipe_output"
pass "a closed pipe does not print a stack trace"

# A route is either resolved or refused. An empty tree for a misspelling would
# be indistinguishable from a route whose rows all hid.
unknown_status=0
unknown_output=$(snapshot_json --route=style.nonexistent 2>&1 >/dev/null) || unknown_status=$?
assert_equal_route "an unknown route exits nonzero" "$unknown_status" "1"
echo "$unknown_output" | jq -e '.error | test("style.nonexistent")' >/dev/null ||
  fail "an unknown route prints a JSON error naming it" "got: $unknown_output"
pass "an unknown route prints a JSON error naming it"
[[ $unknown_output != *"at "* ]] ||
  fail "an unknown route is an error, not a stack trace" "got: $unknown_output"
pass "an unknown route is an error, not a stack trace"

# A tree that cannot be read is the same shape of answer, not a crash.
broken_home=$(mktemp -d)
missing_status=0
missing_output=$(
  export OMARCHY_PATH="$ROOT"
  export ROOT="$broken_home"
  "$SNAPSHOT_CMD" --no-guards 2>&1 >/dev/null
) || missing_status=$?
assert_equal_route "a missing menu file exits nonzero" "$missing_status" "1"
echo "$missing_output" | jq -e '.error | test("omarchy-menu.jsonc")' >/dev/null ||
  fail "a missing menu file prints a JSON error naming the file" "got: $missing_output"
pass "a missing menu file prints a JSON error naming the file"
[[ $missing_output != *" at "* && $missing_output != *"Error:"* ]] ||
  fail "a missing menu file is an error, not a stack trace" "got: $missing_output"
pass "a missing menu file is an error, not a stack trace"

# Nothing here needs a Node.js binary to have a name, and a machine without
# one has to be told how to get it rather than failing obscurely.
node_status=0
node_output=$(OMARCHY_PATH="$ROOT" PATH=/nonexistent snapshot_json --no-guards 2>&1 >/dev/null) || node_status=$?
assert_equal_route "no Node.js runtime exits nonzero" "$node_status" "1"
assert_equal_route "no Node.js runtime names the fix" "$node_output" \
  "omarchy-menu-snapshot: no Node.js runtime found. Install one with: omarchy install node-runtime"
pass "no Node.js runtime is told exactly how to get one"

unknown_flag_status=0
snapshot_json --nope >/dev/null 2>&1 || unknown_flag_status=$?
[[ $unknown_flag_status -ne 0 ]] ||
  fail "an unknown flag is refused"
pass "an unknown flag is refused"
