#!/bin/bash

# The graphical half of the dashboard: the app grid entry, the window it opens,
# and the wrapper that decides whether it can open at all.
#
# Everything asserted here is an install-path or a start-up contract, because
# those are the two things that break in a way nobody notices until a user has
# clicked the icon. The window's contents are the snapshot's, not this file's:
# testing that the rows are right would mean testing MenuSnapshot.js again, and
# the whole point of the design is that the app has no opinion about them.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

desktop_file="$ROOT/applications/Omarchy.desktop"
icon_name="omarchy-dashboard"
app_source="$ROOT/app/omarchy-dashboard/omarchy-dashboard.js"
wrapper="$ROOT/bin/omarchy-dashboard-app"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# --- the app grid entry -----------------------------------------------------

if [[ ! -f $desktop_file ]]; then
  fail "applications/Omarchy.desktop exists"
  exit 1
fi
pass "applications/Omarchy.desktop exists"

desktop_value() {
  sed -n "s/^$1=//p" "$desktop_file" | head -1
}

if [[ $(desktop_value Type) == Application ]]; then
  pass "the desktop entry declares Type=Application"
else
  fail "the desktop entry declares Type=Application (got '$(desktop_value Type)')"
fi

# TryExec is what a desktop environment checks before it shows the entry at
# all, and Exec is what it runs. Both name the bare command, because
# bin/omarchy-refresh-applications copies this file into ~/.local/share/
# applications verbatim and nothing there knows about $OMARCHY_PATH.
tryexec=$(desktop_value TryExec)
if [[ -z $tryexec ]]; then
  fail "the desktop entry has a TryExec"
elif [[ -x "$ROOT/bin/$tryexec" ]]; then
  pass "TryExec names bin/$tryexec, which exists"
else
  fail "TryExec names bin/$tryexec, which exists"
fi

exec_line=$(desktop_value Exec)
if [[ $exec_line == "$tryexec" || $exec_line == "$tryexec "* ]]; then
  pass "Exec runs the same bare command as TryExec ($exec_line)"
else
  fail "Exec runs the same bare command as TryExec (got '$exec_line')"
fi

if [[ $(desktop_value Terminal) == false ]]; then
  pass "the desktop entry declares Terminal=false"
else
  fail "the desktop entry declares Terminal=false"
fi

if [[ $(desktop_value StartupNotify) == true ]]; then
  pass "the desktop entry declares StartupNotify=true"
else
  fail "the desktop entry declares StartupNotify=true"
fi

# An Icon= that resolves to nothing is a blank tile in the app grid, and a
# blank tile is the one failure the user cannot diagnose.
icon_key=$(desktop_value Icon)
icon_file="$ROOT/applications/icons/$icon_key.svg"
if [[ -z $icon_key ]]; then
  fail "the desktop entry names an Icon"
elif [[ -f $icon_file ]]; then
  pass "Icon=$icon_key resolves to applications/icons/$icon_key.svg"
else
  fail "Icon=$icon_key resolves to applications/icons/$icon_key.svg"
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
  if desktop-file-validate "$desktop_file"; then
    pass "desktop-file-validate accepts the entry"
  else
    fail "desktop-file-validate accepts the entry"
  fi
else
  skip "desktop-file-validate accepts the entry # desktop-file-validate is not installed"
fi

# --- the icon ---------------------------------------------------------------

# Parsed, not merely present: a truncated or malformed SVG is a tile that
# renders as nothing, and `test -s` would pass it.
if python3 -c "
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.tag.endswith('svg'), root.tag
assert root.get('viewBox') or root.get('width'), 'no viewBox or width'
" "$icon_file" 2>"$test_tmp/svg-error"; then
  pass "the icon parses as SVG with a drawable extent"
else
  fail "the icon parses as SVG with a drawable extent ($(cat "$test_tmp/svg-error"))"
fi

# --- the app source ---------------------------------------------------------

if [[ ! -f $app_source ]]; then
  fail "app/omarchy-dashboard/omarchy-dashboard.js exists"
else
  pass "app/omarchy-dashboard/omarchy-dashboard.js exists"
fi

# gjs parses the source as an ES module, which is how GJS loads it. `gjs -c`
# evaluates its argument in script mode where `import` is a syntax error, so the
# module target is what has to be asked for explicitly -- checking the same
# source the same way it is actually loaded is the whole point.
if command -v gjs >/dev/null 2>&1; then
  if gjs -c '
    const GLib = imports.gi.GLib
    const [ok, bytes] = GLib.file_get_contents(ARGV[0])
    if (!ok) throw new Error("unreadable")
    Reflect.parse(new TextDecoder().decode(bytes), { target: "module" })
  ' "$app_source" >/dev/null 2>"$test_tmp/parse-error"; then
    pass "gjs -c parses the app source as an ES module"
  else
    fail "gjs -c parses the app source as an ES module ($(cat "$test_tmp/parse-error"))"
  fi

  # Stronger than a parse: the module loader has resolved every typelib the
  # window needs. No window, so this runs in a test harness too.
  if DISPLAY=${DISPLAY:-} gjs -m "$app_source" --check >/dev/null 2>&1; then
    pass "gjs -m --check loads the app and its typelibs"
  else
    fail "gjs -m --check loads the app and its typelibs"
  fi
else
  skip "gjs -c parses the app source as an ES module # gjs is not installed"
  skip "gjs -m --check loads the app and its typelibs # gjs is not installed"
fi

# The app renders the snapshot; it must not have grown a second copy of the
# model to render it with. GJS is ESM and has no require(), so the trap is
# subtle enough to be worth a tripwire.
if grep -qE '\brequire\s*\(|module\.exports|__dirname' "$app_source"; then
  fail "the app has no CommonJS loader of its own"
else
  pass "the app has no CommonJS loader of its own"
fi

if grep -q "const argv = \['menu', 'snapshot'\]" "$app_source"; then
  pass "the app reads its tree from omarchy menu snapshot"
else
  fail "the app reads its tree from omarchy menu snapshot"
fi

# --- the wrapper ------------------------------------------------------------

# `omarchy dashboard` picks between this and the TUI by asking --available, so
# the exit code is the contract and has to be pinned in both directions.
if command -v gjs >/dev/null 2>&1; then
  "$wrapper" --available >/dev/null 2>&1
  status=$?
  if [[ $status -eq 0 ]]; then
    pass "--available exits 0 when the app can start"
  else
    fail "--available exits 0 when the app can start (exited $status)"
  fi
else
  skip "--available exits 0 when the app can start # gjs is not installed"
fi

# An empty PATH is the honest way to hide gjs: the wrapper is bash and needs
# nothing else, so anything that is still found came from the system rather than
# from a stub. Without gjs the wrapper must refuse by name, because that refusal
# is what makes `omarchy dashboard` fall back to the TUI.
empty_path="$test_tmp/empty-path"
mkdir -p "$empty_path"
set +e
refusal=$(PATH="$empty_path" "$wrapper" 2>&1 >/dev/null)
refusal_status=$?
PATH="$empty_path" "$wrapper" --available >/dev/null 2>&1
unavailable_status=$?
set -e

if [[ $refusal_status -eq 1 ]]; then
  pass "the wrapper exits 1 when gjs is not on PATH"
else
  fail "the wrapper exits 1 when gjs is not on PATH (exited $refusal_status)"
fi

if [[ $refusal == "omarchy-dashboard-app: the graphical dashboard is unavailable on this system" ]]; then
  pass "the refusal names the reason on stderr"
else
  fail "the refusal names the reason on stderr (got '$refusal')"
fi

if [[ $unavailable_status -ne 0 ]]; then
  pass "--available exits nonzero when the app cannot start (exited $unavailable_status)"
else
  fail "--available exits nonzero when the app cannot start"
fi

# --- the install path -------------------------------------------------------

# This is the only install step the dashboard has. bin/omarchy-refresh-applications
# copies applications/*.desktop into ~/.local/share/applications; it also calls
# two things a checkout may not have, so both are stubbed -- the assertion under
# test is where the file lands, not what the rest of the script does.
home="$test_tmp/home"
mkdir -p "$home"
stub_bin="$test_tmp/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
exit 1
STUB
cat >"$stub_bin/update-desktop-database" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$stub_bin/omarchy-cmd-present" "$stub_bin/update-desktop-database"

# install/user/mise.sh installs a runtime toolchain; a test that runs it is a
# test that reaches the network, so the script is made unreachable for its own
# length and a stripped tree stands in for $OMARCHY_PATH.
refresh_tree="$test_tmp/tree"
mkdir -p "$refresh_tree"
cp "$ROOT/bin/omarchy-refresh-applications" "$refresh_tree/omarchy-refresh-applications"
cp -r "$ROOT/applications" "$refresh_tree/applications"

if HOME="$home" OMARCHY_PATH="$refresh_tree" PATH="$stub_bin:$PATH" \
  "$refresh_tree/omarchy-refresh-applications" >/dev/null 2>&1; then
  if [[ -f "$home/.local/share/applications/Omarchy.desktop" ]]; then
    pass "a refresh installs Omarchy.desktop into a fresh HOME"
  else
    fail "a refresh installs Omarchy.desktop into a fresh HOME (not in $home/.local/share/applications)"
  fi
else
  fail "a refresh installs Omarchy.desktop into a fresh HOME (the refresh exited nonzero)"
fi

installed="$home/.local/share/applications/Omarchy.desktop"
if [[ -f $installed ]]; then
  if diff -q "$desktop_file" "$installed" >/dev/null 2>&1; then
    pass "the installed entry is the shipped one, byte for byte"
  else
    fail "the installed entry is the shipped one, byte for byte"
  fi
fi

if command -v desktop-file-validate >/dev/null 2>&1 && [[ -f $installed ]]; then
  if desktop-file-validate "$installed" >/dev/null 2>&1; then
    pass "desktop-file-validate accepts the installed entry"
  else
    fail "desktop-file-validate accepts the installed entry"
  fi
fi

# The menu's icon column is Nerd Font private-use codepoints, and a stock
# Ubuntu has no Nerd Font installed. Rendering those anyway fills the window
# with tofu boxes, which reads as a broken app rather than as missing
# decoration -- so the rule that drops them is pinned here rather than left to
# a screenshot nobody reads in review.
if command -v gjs >/dev/null 2>&1; then
  glyph_rule=$(sed -n '/^function renderableGlyph/,/^}/p' "$ROOT/app/omarchy-dashboard/omarchy-dashboard.js")
  [[ -n $glyph_rule ]] || fail "the app has a rule about which glyphs it can render"

  result=$(gjs -c "
    $glyph_rule
    print(JSON.stringify([
      renderableGlyph('\ue0b0'),
      renderableGlyph('\udb81\udc0b'),
      renderableGlyph('A'),
      renderableGlyph('')
    ]))
  " 2>/dev/null)

  [[ $result == '["","","A",""]' ]] ||
    fail "private-use glyphs are dropped and ordinary text is kept" "$result"
  pass "private-use glyphs are dropped and ordinary text is kept"
else
  skip "gjs is not installed; cannot run the glyph rule"
fi
