#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/data/applications" "$tmp_dir/system/applications" "$tmp_dir/bin"

write_fake_command() {
  local name="$1"
  local prefix="$2"

  cat >"$tmp_dir/bin/$name" <<SCRIPT
#!/bin/bash
printf '%s:%s:%s\\n' '$prefix' "\${OMARCHY_REMOVE_NOTIFY:-}" "\$*" >>"\$TEST_LOG"
SCRIPT
  chmod +x "$tmp_dir/bin/$name"
}

write_fake_command omarchy-webapp-remove web
write_fake_command omarchy-tui-remove tui
write_fake_command omarchy-launch-floating-terminal-with-presentation terminal

cat >"$tmp_dir/bin/omarchy-notification-send" <<'SCRIPT'
#!/bin/bash
printf 'notify::%s\n' "$*" >>"$TEST_LOG"
SCRIPT
chmod +x "$tmp_dir/bin/omarchy-notification-send"

cat >"$tmp_dir/bin/update-desktop-database" <<'SCRIPT'
#!/bin/bash
:
SCRIPT
chmod +x "$tmp_dir/bin/update-desktop-database"

cat >"$tmp_dir/bin/pacman" <<'SCRIPT'
#!/bin/bash
[[ $1 == "-Qqo" ]] || exit 1
for arg in "$@"; do
  if [[ $arg == */native.desktop ]]; then
    printf 'native-pkg\n'
    exit 0
  fi
done
SCRIPT
chmod +x "$tmp_dir/bin/pacman"

# dpkg answers the same question with a "package: path" line, and the seam cuts
# the name off the front of it.
cat >"$tmp_dir/bin/dpkg-query" <<'SCRIPT'
#!/bin/bash
[[ $1 == "-S" ]] || exit 1
for arg in "$@"; do
  if [[ $arg == */debnative.desktop ]]; then
    printf 'omarchy-shell: %s\n' "$arg"
    exit 0
  fi
done
SCRIPT
chmod +x "$tmp_dir/bin/dpkg-query"

cat >"$tmp_dir/data/applications/Basecamp.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Basecamp
Exec=omarchy-launch-webapp https://example.com
DESKTOP

cat >"$tmp_dir/data/applications/Docker.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Docker
Exec=xdg-terminal-exec --app-id=TUI.tile -e lazydocker
DESKTOP

cat >"$tmp_dir/system/applications/native.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Native
Exec=native
DESKTOP

cat >"$tmp_dir/system/applications/debnative.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Debnative
Exec=debnative
DESKTOP

cat >"$tmp_dir/data/applications/aliens.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Aliens
Exec=retroarch -L /usr/lib/libretro/fbneo_libretro.so /home/example/Games/roms/fbneo/aliens.zip
DESKTOP

export TEST_LOG="$tmp_dir/log"
export PATH="$tmp_dir/bin:$PATH"
export XDG_DATA_HOME="$tmp_dir/data"
export XDG_DATA_DIRS="$tmp_dir/system"

"$ROOT/bin/omarchy-remove-launcher-entry" Basecamp.desktop Basecamp
"$ROOT/bin/omarchy-remove-launcher-entry" Docker.desktop Docker
"$ROOT/bin/omarchy-remove-launcher-entry" native.desktop Native
"$ROOT/bin/omarchy-remove-launcher-entry" aliens.desktop Aliens

mapfile -t lines <"$TEST_LOG"

[[ ${lines[0]} == "web:false:Basecamp" ]] || fail "launcher remove routes web apps by desktop name" "${lines[0]}"
pass "launcher remove routes web apps by desktop name"

[[ ${lines[1]} == "tui:false:Docker" ]] || fail "launcher remove routes TUIs by desktop name" "${lines[1]}"
pass "launcher remove routes TUIs by desktop name"

[[ ${lines[2]} == "terminal::echo Uninstalling Native...; sudo pacman -Rns native-pkg" ]] || fail "launcher remove opens package uninstall flow" "${lines[2]}"
pass "launcher remove opens package uninstall flow"

[[ ! -e $tmp_dir/data/applications/aliens.desktop ]] || fail "launcher remove deletes user-owned desktop files"
pass "launcher remove deletes user-owned desktop files"

(( ${#lines[@]} == 3 )) || fail "launcher remove does not notify for user-owned desktop files" "$(printf '%s\n' "${lines[@]}")"
pass "launcher remove does not notify for user-owned desktop files"

# The uninstall line is a string for a terminal, so on Ubuntu it has to name apt
# and its flags rather than pacman's.
: >"$TEST_LOG"
OMARCHY_PKG_BACKEND=deb "$ROOT/bin/omarchy-remove-launcher-entry" debnative.desktop Debnative

mapfile -t deb_lines <"$TEST_LOG"

[[ ${deb_lines[0]} == "terminal::echo Uninstalling Debnative...; sudo apt-get remove -y --purge omarchy-shell" ]] ||
  fail "launcher remove uninstalls through apt on the deb backend" "${deb_lines[0]}"
pass "launcher remove uninstalls through apt on the deb backend"

(( ${#deb_lines[@]} == 1 )) || fail "launcher remove emits one line for a package-owned desktop file" "$(printf '%s\n' "${deb_lines[@]}")"
pass "launcher remove emits one line for a package-owned desktop file"
