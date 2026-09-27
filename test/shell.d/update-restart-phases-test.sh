#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/fixtures/sudo-boundary-test.sh"
rm "$SUDO_TEST_ROOT/bin/omarchy-update-restart"
copy_boundary_file bin/omarchy-update-restart
copy_boundary_file bin/omarchy-pkg-backend
for step in omarchy-state omarchy-restart-sshd omarchy-restart-shell omarchy-system-reboot; do
  ln -s test-step "$SUDO_TEST_ROOT/bin/$step"
done
cat >"$SUDO_TEST_ROOT/bin/gum" <<'STUB'
#!/bin/bash
printf 'prompt:%s\n' "$*" >>"$SUDO_TEST_LOG"
exit 1
STUB
chmod +x "$SUDO_TEST_ROOT/bin/gum"
mkdir -p "$SUDO_TEST_HOME/.local/state/omarchy"
touch "$SUDO_TEST_HOME/.local/state/omarchy/reboot-required" "$SUDO_TEST_HOME/.local/state/omarchy/restart-sshd-required"

for mode in --services-only --reboot-only; do
  reset_boundary
  PATH="$SUDO_TEST_ROOT/bin:$PATH" "$SUDO_TEST_ROOT/bin/omarchy-update-restart" "$mode" >"$boundary_tmp/output" 2>&1
  if [[ $mode == "--services-only" ]]; then
    grep -q '^step:omarchy-restart-sshd ' "$SUDO_TEST_LOG" || fail "service phase did not restart a marked service"
    grep -q '^step:omarchy-restart-shell ' "$SUDO_TEST_LOG" || fail "service phase did not restart the shell"
    if grep -q '^prompt:' "$SUDO_TEST_LOG"; then fail "service phase offered a reboot before update cleanup"; fi
  else
    grep -q '^prompt:' "$SUDO_TEST_LOG" || fail "reboot phase did not offer the required reboot"
    if grep -q '^step:omarchy-restart-' "$SUDO_TEST_LOG"; then fail "reboot phase performed later service work"; fi
  fi
  pass "restart $mode performs only its selected phase"
done
reset_boundary
OMARCHY_UPDATE_UNATTENDED=1 PATH="$SUDO_TEST_ROOT/bin:$PATH" "$SUDO_TEST_ROOT/bin/omarchy-update-restart" --reboot-only >"$boundary_tmp/output" 2>&1
if grep -Eq "^(prompt:|step:omarchy-restart-|step:omarchy-system-reboot)" "$SUDO_TEST_LOG"; then
  fail "unattended reboot phase prompted or performed service work"
fi
pass "unattended reboot phase reports a required reboot without prompting"

# The kernel-ownership probe only reaches the package manager when a kernel
# image is actually installed, and /usr/lib/modules is an absolute path a test
# cannot populate. A mount namespace can: bind-mounting over it changes what
# this process tree sees and nothing else. Unattended mode is what makes the
# outcome readable here -- the script announces the reason instead of asking a
# question nobody answers -- so an owned running kernel says nothing at all.
kernel_modules="$boundary_tmp/modules"
kernel_image="/usr/lib/modules/$(uname -r)/vmlinuz"
mkdir -p "$kernel_modules/$(uname -r)"
touch "$kernel_modules/$(uname -r)/vmlinuz"

cat >"$SUDO_TEST_ROOT/bin/dpkg-query" <<'STUB'
#!/bin/bash
printf 'step:dpkg-query %s\n' "$*" >>"$SUDO_TEST_LOG"
exit "${KERNEL_OWNED:-0}"
STUB
chmod +x "$SUDO_TEST_ROOT/bin/dpkg-query"

cat >"$boundary_tmp/kernel-run" <<RUNNER
#!/bin/bash
set -e
mount --bind "$kernel_modules" /usr/lib/modules
export OMARCHY_PKG_BACKEND="\$1" OMARCHY_UPDATE_UNATTENDED=1 PATH="$SUDO_TEST_ROOT/bin:\$PATH"
exec "$SUDO_TEST_ROOT/bin/omarchy-update-restart" --reboot-only
RUNNER
chmod +x "$boundary_tmp/kernel-run"

if ! command -v unshare >/dev/null || ! unshare --map-root-user --mount -- /bin/true 2>/dev/null; then
  skip "user namespaces unavailable; skipping kernel ownership probe"
  exit 0
fi

reset_boundary
unshare --map-root-user --mount -- "$boundary_tmp/kernel-run" arch >"$boundary_tmp/output" 2>&1 ||
  fail "restart failed to read a kernel image through pacman" "$(<"$boundary_tmp/output")"
grep -qF "step:pacman -Qo -- $kernel_image" "$SUDO_TEST_LOG" ||
  fail "restart asks pacman who owns an installed kernel image" "$(<"$SUDO_TEST_LOG")"
! grep -q 'Linux kernel has been updated' "$boundary_tmp/output" ||
  fail "a running kernel pacman owns is not an updated kernel" "$(<"$boundary_tmp/output")"
pass "restart reads kernel ownership from pacman and recognises the running kernel"

reset_boundary
unshare --map-root-user --mount -- "$boundary_tmp/kernel-run" deb >"$boundary_tmp/output" 2>&1 ||
  fail "restart failed to read a kernel image through dpkg-query" "$(<"$boundary_tmp/output")"
! grep -q '^step:pacman ' "$SUDO_TEST_LOG" ||
  fail "the deb backend shells out to pacman" "$(<"$SUDO_TEST_LOG")"
grep -qF "step:dpkg-query -S -- $kernel_image" "$SUDO_TEST_LOG" ||
  fail "restart asks dpkg-query who owns an installed kernel image" "$(<"$SUDO_TEST_LOG")"
! grep -q 'Linux kernel has been updated' "$boundary_tmp/output" ||
  fail "a running kernel dpkg-query owns is not an updated kernel on deb" "$(<"$boundary_tmp/output")"
pass "restart reads kernel ownership from dpkg-query and recognises the running kernel"

# The same probe answering differently has to change the decision, or the two
# checks above would pass on a script that never looks.
reset_boundary
KERNEL_OWNED=1 unshare --map-root-user --mount -- "$boundary_tmp/kernel-run" deb >"$boundary_tmp/output" 2>&1
grep -q 'Linux kernel has been updated' "$boundary_tmp/output" ||
  fail "an unowned kernel image still reads as an updated kernel" "$(<"$boundary_tmp/output")"
pass "an unowned kernel image reads as an updated kernel on deb"
