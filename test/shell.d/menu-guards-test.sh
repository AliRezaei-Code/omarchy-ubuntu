#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const menu = requireFromRoot('shell/plugins/menu/MenuModel.js')

const items = {
  'setup.default.browser.brave': { id: 'setup.default.browser.brave', when: 'omarchy-pkg-present brave-bin', checked: '[[ "$(omarchy-default-browser)" == "brave" ]]' },
  'setup.default.browser.zen': { id: 'setup.default.browser.zen', when: 'omarchy-pkg-present zen-browser-bin', checked: '[[ "$(omarchy-default-browser)" == "zen" ]]' },
  'install.browser.zen': { id: 'install.browser.zen', disabled: 'omarchy-pkg-present zen-browser-bin' },
  'plain': { id: 'plain', label: 'No guards' }
}
const script = menu.guardScript(items)
const browserSlot = `\${__omarchy_read_${menu.guardReaders.indexOf('omarchy-default-browser')}}`

assert(
  script.includes('if { omarchy-pkg-present brave-bin; } >/dev/null 2>&1; then echo setup.default.browser.brave:w:1; else echo setup.default.browser.brave:w:0; fi'),
  'guard script reports a when: as <id>:w:<0|1>'
)
assert(
  script.includes('then echo setup.default.browser.zen:c:1; else echo setup.default.browser.zen:c:0; fi'),
  'guard script reports a checked: as <id>:c:<0|1>'
)
assert(
  script.includes('if { omarchy-pkg-present zen-browser-bin; } >/dev/null 2>&1; then echo install.browser.zen:d:1; else echo install.browser.zen:d:0; fi'),
  'guard script reports a disabled: as <id>:d:<0|1>'
)
assert(!/\bplain:[wcd]:/.test(script), 'guard script skips items with nothing to evaluate')
assertEqual(menu.guardScript({ plain: items.plain }), '', 'guard script is empty when no item carries a guard')

// The cost the menu is paying is per fork, not per expression, so what makes
// the batch fast is asking each command once however many rows want it.
assertEqual(
  (script.match(/^__omarchy_read_\d+=\$\(omarchy-default-browser /gm) || []).length,
  1,
  'guard script reads a value command once for the whole batch'
)
assert(
  script.includes(`[[ "${browserSlot}" == "brave" ]]`) && !script.includes('"$(omarchy-default-browser)"'),
  'guard script substitutes the captured answer into the expression'
)
assert(
  script.indexOf('__omarchy_read_') < script.indexOf('if { omarchy-pkg-present'),
  'guard script captures readers before any guard runs, since $() would trap a lazy memo in its subshell'
)

// Substitution is confined to the plain `$(reader)` form on purpose. A
// function shadowing the name would also catch these, and answer them wrong.
const untouched = menu.guardScript({
  a: { id: 'a', when: 'command -v omarchy-dns' },
  b: { id: 'b', when: '[[ "$(OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current)" == "stable" ]]' },
  c: { id: 'c', when: '(( $(omarchy-default-browser | wc -l) == 1 ))' }
})
assert(
  untouched.includes('command -v omarchy-dns')
    && untouched.includes('$(OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current)')
    && untouched.includes('$(omarchy-default-browser | wc -l)'),
  'guard script leaves every form but the plain substitution to run the real command'
)
assert(
  !/^__omarchy_read_/m.test(untouched),
  'guard script captures nothing when no guard uses the plain substitution'
)

// Every reader named in the shipped menu has to be listed, or it silently
// keeps forking once per row that reads it.
const fs = require('fs')
const defaultItems = menu.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8'))
const guardText = defaultItems.map(item => `${item.when}\n${item.checked}\n${item.disabled}`).join('\n')
const repeated = [...new Set(
  (guardText.match(/\$\((omarchy-[a-z0-9-]+)\)/g) || []).map(match => match.slice(2, -1))
)].filter(command => guardText.split(`$(${command})`).length > 2)
assertDeepEqual(
  repeated.filter(command => !menu.guardReaders.includes(command)),
  [],
  'guard readers cover every command the shipped menu reads from more than one row'
)
JS

prelude() {
  node -e '
    const path = require("path")
    const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
    process.stdout.write(menu.guardScript({ probe: { id: "probe", when: "true" } }))
  ' | command grep -v '^if {'
}

# The prelude shadows the real commands for the length of the batch, so it has
# to answer exactly as they do -- including for arguments no shipped guard
# passes today, which an extension is free to write tomorrow.
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

# `pacman -Q` resolves a name through what installed packages provide, so gvim
# answers for vim and bash answers for sh. A set built from `pacman -Qq` alone
# would miss both and offer to install what is already there.
#
# `-Qi` wraps a long list onto indented continuation lines whenever COLUMNS is
# set, so gvim's provides arrive the way a wrapped terminal would emit them.
cat >"$stub_dir/pacman" <<'STUB'
#!/bin/bash
case "$1" in
-Qq)
  printf '%s\n' bash gvim
  ;;
-Qi)
  cat <<'INFO'
Name            : bash
Provides        : sh
Version         : 5.3.0-1
Name            : gvim
Provides        : vim=9.2.0849-1
                  xxd
Version         : 9.2-1
INFO
  ;;
-Q)
  if [[ $2 == "--" ]]; then
    shift 2
  else
    shift
  fi
  for want in "$@"; do
    case "${want%%[<>=]*}" in bash | gvim | sh | vim | xxd) ;; *) exit 1 ;; esac
  done
  ;;
esac
exit 0
STUB
chmod +x "$stub_dir/pacman"
printf '#!/bin/bash\nexit 0\n' >"$stub_dir/gvim"
chmod +x "$stub_dir/gvim"

guard_prelude=$(prelude)

# Arguments reach both sides as argv. Interpolating them into the shadow's
# script text would let `bash>=1` parse as a redirection, so the case that
# exists to prove constraints work would quietly test `bash` instead.
assert_helper_agrees() {
  local description="$1" helper="$2"
  shift 2

  local real=0 shadowed=0
  PATH="$stub_dir:$PATH" "$ROOT/bin/$helper" "$@" >/dev/null 2>&1 || real=$?
  PATH="$stub_dir:$PATH" bash -c "$guard_prelude"$'\n'"$helper \"\$@\"" "$helper" "$@" >/dev/null 2>&1 || shadowed=$?
  ((real == shadowed)) || fail "$description" "$helper $*: real=$real shadowed=$shadowed"
}

# vim, sh and xxd are provided rather than installed, and xxd only appears on a
# wrapped continuation line; bash>=1 is a version constraint no set can answer.
pkg_cases=("bash" "vim" "sh" "xxd" "absent" "bash vim" "bash absent" "bash>=1" "vim>=1" "")
for helper in omarchy-pkg-present omarchy-pkg-missing; do
  for case in "${pkg_cases[@]}"; do
    read -r -a argv <<<"$case"
    assert_helper_agrees "guard prelude resolves packages as pacman does" "$helper" "${argv[@]}"
  done
done
pass "guard prelude resolves packages through provides, wrapping, and constraints as pacman does"

# cd is a shell builtin `command -v` finds and a PATH search does not.
cmd_cases=("gvim" "cd" "absent" "gvim absent" "gvim cd" "")
for helper in omarchy-cmd-present omarchy-cmd-missing; do
  for case in "${cmd_cases[@]}"; do
    read -r -a argv <<<"$case"
    assert_helper_agrees "guard prelude resolves commands as the real helper does" "$helper" "${argv[@]}"
  done
done
pass "guard prelude resolves commands as omarchy-cmd-present and omarchy-cmd-missing do"

# --- the deb branch -------------------------------------------------------
#
# The batch picks its package manager at runtime, and the `backend` argument is
# how a test pins that choice without a live machine. A stub dpkg-query answers
# the two questions the deb snapshot asks: what is installed, and whether one
# particular package is.
cat >"$stub_dir/dpkg-query" <<'STUB'
#!/bin/bash
installed=" bash gvim neovim "

# The snapshot asks for every installed name in one call; a name query asks
# about one package after `--` and is answered with the status alone.
list=0
for arg in "$@"; do
  case "$arg" in
  *'${binary:Package}'*) list=1 ;;
  esac
done

if (( list == 1 )); then
  printf '%s\n' $installed
  exit 0
fi

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

# `bat` reads as removed-but-not-purged, which dpkg still lists and a reader
# has to know is not installed.
deb_prelude=$(node -e '
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  process.stdout.write(menu.guardScript({ probe: { id: "probe", when: "true" } }, "deb"))
' | command grep -v '^if {')

deb_helper() {
  local helper="$1"
  shift

  PATH="$stub_dir:$PATH" OMARCHY_PKG_BACKEND=deb OMARCHY_PATH="$ROOT" \
    "$ROOT/bin/$helper" "$@" >/dev/null 2>&1
}

deb_shadowed() {
  local helper="$1"
  shift

  PATH="$stub_dir:$PATH" OMARCHY_PATH="$ROOT" \
    bash -c "$deb_prelude"$'\n'"$helper \"\$@\"" "$helper" "$@" >/dev/null 2>&1
}

assert_deb_agrees() {
  local description="$1" helper="$2"
  shift 2

  local real=0 shadowed=0
  deb_helper "$helper" "$@" || real=$?
  deb_shadowed "$helper" "$@" || shadowed=$?
  ((real == shadowed)) || fail "$description" "$helper $*: real=$real shadowed=$shadowed"
}

# Installed, not installed, several, and the empty case the pair is documented
# to agree on: present is true of nothing, missing is not.
deb_cases=("neovim" "bat" "absent" "neovim bat" "bash neovim" "")
for helper in omarchy-pkg-present omarchy-pkg-missing; do
  for case in "${deb_cases[@]}"; do
    read -r -a argv <<<"$case"
    assert_deb_agrees "guard prelude resolves packages as dpkg does" "$helper" "${argv[@]}"
  done
done
pass "guard prelude resolves packages as dpkg does"

# The real commands are what the batch stands in for, so the answers have to
# be the answers, not merely the same on both sides of a stub.
deb_helper omarchy-pkg-present neovim ||
  fail "an ii status reads as present on the deb backend"
if deb_helper omarchy-pkg-present bat; then
  fail "an rc status does not read as present"
fi
deb_helper omarchy-pkg-missing bat ||
  fail "an rc status reads as missing on the deb backend"
if deb_helper omarchy-pkg-missing neovim; then
  fail "an ii status does not read as missing"
fi
pass "the deb backend reads ii as present and rc as missing"

deb_helper omarchy-pkg-present ||
  fail "present of no packages is true on the deb backend"
if deb_helper omarchy-pkg-missing; then
  fail "missing of no packages is false on the deb backend"
fi
pass "the deb backend agrees with the documented empty case"

# The shadow reads the same name map the real commands do. Without that, a
# guard written against `nvim` would hear "absent" from the batch and "present"
# from the command it stands in for -- the two front ends disagreeing about
# the same row, which is the one thing they must never do.
deb_helper omarchy-pkg-present nvim ||
  fail "the real command resolves a renamed package"
assert_deb_agrees "guard prelude resolves renamed packages" omarchy-pkg-present nvim
if deb_shadowed omarchy-pkg-present nvim; then
  pass "guard prelude resolves renamed packages the same way"
else
  fail "guard prelude resolves renamed packages the same way" \
    "the batch read nvim as absent while the command read it as present"
fi

# A declared-unsupported name has no Ubuntu equivalent, so it is absent on both
# sides -- and the row that asks about it stays visible rather than vanishing.
if deb_helper omarchy-pkg-present expac; then
  fail "a package with no Ubuntu equivalent is not present on deb"
fi
assert_deb_agrees "guard prelude agrees about unsupported packages" omarchy-pkg-present expac
pass "a package with no Ubuntu equivalent is absent on both sides"

# The default (no backend argument) is what the QML call site uses, and it has
# to choose for itself.
runtime_prelude=$(node -e '
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  process.stdout.write(menu.guardScript({ probe: { id: "probe", when: "true" } }))
' | command grep -v '^if {')

case "$runtime_prelude" in
*"command -v pacman"*) ;;
*) fail "the default guard script asks the machine which package manager it has" ;;
esac
pass "the default guard script asks the machine which package manager it has"

runtime_result=$(PATH="$stub_dir:$PATH" OMARCHY_PATH="$ROOT" bash -c "$runtime_prelude"$'\n'"omarchy-pkg-present neovim; echo $?")
[[ $runtime_result == 0 ]] ||
  fail "the default guard script answers from dpkg when there is no pacman" "$runtime_result"
pass "the default guard script answers from dpkg when there is no pacman"

# A reader is replaced by what it printed, which has to compare identically to
# the substitution it stood in for -- including the trailing newline $() drops.
reader_script=$(node -e '
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  process.stdout.write(menu.guardScript({
    hit: { id: "hit", checked: "[[ \"$(omarchy-dns)\" == \"Cloudflare\" ]]" },
    miss: { id: "miss", checked: "[[ \"$(omarchy-dns)\" == \"Google\" ]]" }
  }))
')
reader_result=$(bash -c '
omarchy-dns() { printf "Cloudflare\n"; }
export -f omarchy-dns
'"$reader_script")
[[ $reader_result == $'hit:c:1\nmiss:c:0' ]] ||
  fail "guard prelude compares a captured reader as the substitution did" "got: $reader_result"
pass "guard prelude compares a captured reader exactly as the substitution it replaced"

# The batch inherits whatever a login shell left set. A reader that exits
# nonzero must not take the rest of the menu's rows down with it.
errexit_result=$(bash -e -c '
omarchy-dns() { printf "Cloudflare\n"; return 3; }
export -f omarchy-dns
'"$reader_script"'
printf "survived\n"' 2>/dev/null)
[[ $errexit_result == $'hit:c:1\nmiss:c:0\nsurvived' ]] ||
  fail "guard batch survives a failing reader under errexit" "got: $errexit_result"
pass "guard batch survives a reader that exits nonzero under errexit"

# Update > Extra Themes runs omarchy-theme-update, which pulls the themes that
# came from a git clone and skips everything else, so the guard has to answer
# for the same set: a row that appears over a symlinked theme or a worktree's
# `.git` file opens a terminal that prints nothing and closes. Both sides ask
# omarchy-theme-extras today; the shapes below are what would tell us if one
# of them stopped.
themes_guard=$(node -e '
  const fs = require("fs")
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  const items = menu.parseMenuJsonc(fs.readFileSync(path.join(process.env.ROOT, "default/omarchy/omarchy-menu.jsonc"), "utf8"))
  process.stdout.write(items.find(item => item.id === "update.themes").when)
')

cat >"$stub_dir/git" <<'STUB'
#!/bin/bash
: "${GIT_CALLS:=/dev/null}"
{ printf '<%s>' "$@"; printf '\n'; } >>"$GIT_CALLS"
STUB
chmod +x "$stub_dir/git"

# The updater names each theme it pulls, so what it printed is what the row
# would have been for. Run the guard the way the batch does, braces and all,
# and say which shapes are meant to show it rather than only that the two
# agree: they read the same command now, and agreement alone would hold even
# if both went wrong together.
assert_themes_guard_agrees() {
  local description="$1" home="$2" expected="$3"
  local guarded=0 updated=0

  HOME="$home" PATH="$ROOT/bin:$PATH" bash -e -c "{ $themes_guard; } >/dev/null 2>&1" || guarded=$?
  [[ -n $(HOME="$home" PATH="$ROOT/bin:$stub_dir:$PATH" "$ROOT/bin/omarchy-theme-update" 2>/dev/null) ]] || updated=1
  ((guarded == expected)) || fail "$description" "$home: guard=$guarded expected=$expected"
  ((updated == expected)) || fail "$description" "$home: update=$updated expected=$expected"
}

themes_home=$(mktemp -d)
trap 'rm -rf "$stub_dir" "$themes_home"' EXIT

# A theme copied by hand has nothing to pull, a symlinked one is someone's
# working copy, and a `.git` file is a worktree living elsewhere.
mkdir -p "$themes_home/missing"
mkdir -p "$themes_home/empty/.config/omarchy/themes"
mkdir -p "$themes_home/copied/.config/omarchy/themes/handmade"
mkdir -p "$themes_home/cloned/.config/omarchy/themes/tokyo-night/.git"
mkdir -p "$themes_home/linked/.config/omarchy/themes" "$themes_home/checkout/.git"
ln -s "$themes_home/checkout" "$themes_home/linked/.config/omarchy/themes/in-progress"
mkdir -p "$themes_home/worktree/.config/omarchy/themes/branch"
printf 'gitdir: /elsewhere\n' >"$themes_home/worktree/.config/omarchy/themes/branch/.git"

for shape in missing:1 empty:1 copied:1 cloned:0 linked:1 worktree:1; do
  assert_themes_guard_agrees \
    "Extra Themes shows exactly when omarchy-theme-update has something to pull" \
    "$themes_home/${shape%:*}" "${shape#*:}"
done
pass "Extra Themes shows exactly when omarchy-theme-update has something to pull"

# Which themes get pulled, not just that something did: a name with a space in
# it is the one that goes missing the moment a path is split rather than passed
# whole, and it would still print an Updating: line on its way to the wrong
# directory.
many="$themes_home/many/.config/omarchy/themes"
mkdir -p "$many/tokyo night/.git" "$many/zen/.git" "$many/handmade"
ln -s "$themes_home/checkout" "$many/in-progress"

listed=$(HOME="$themes_home/many" LC_ALL=C "$ROOT/bin/omarchy-theme-extras")
[[ $listed == "$many/tokyo night"$'\n'"$many/zen" ]] ||
  fail "omarchy-theme-extras lists every clone and nothing else" "got: $listed"
pass "omarchy-theme-extras lists every clone and nothing else"

git_calls=$(mktemp)
trap 'rm -rf "$stub_dir" "$themes_home" "$git_calls"' EXIT
HOME="$themes_home/many" LC_ALL=C GIT_CALLS="$git_calls" PATH="$ROOT/bin:$stub_dir:$PATH" \
  "$ROOT/bin/omarchy-theme-update" >/dev/null 2>&1
pulled=$(<"$git_calls")
[[ $pulled == "<-C><$many/tokyo night><pull>"$'\n'"<-C><$many/zen><pull>" ]] ||
  fail "omarchy-theme-update pulls each clone by its whole path" "got: $pulled"
pass "omarchy-theme-update pulls each clone by its whole path"
