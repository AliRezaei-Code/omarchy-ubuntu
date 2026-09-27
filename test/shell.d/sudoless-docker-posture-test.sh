#!/bin/bash
#
# Docker is root-equivalent, so no automatic path may grant it. Raw input access
# is likewise excluded unless a feature that explicitly needs it is installed.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# First-boot provisioning must not replay old privileged defaults.
mkdir -p "$TMPDIR/bin"
printf '#!/bin/bash\nexit 0\n' >"$TMPDIR/bin/getent" # every group "exists"
# The controller check goes through the package backend, which asks about one
# package at a time and passes the name after `--`. Answer that form: a stub
# that only understood the old `-Qq` call would make every package look absent
# and the "must not replay" assertion would pass for the wrong reason.
cat >"$TMPDIR/bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == "-Q" ]] || exit 2
shift
[[ ${1:-} == "--" ]] && shift
for want in "$@"; do
  [[ " ${STUB_PACKAGES:-} " == *" $want "* ]] || exit 1
done
exit 0
STUB
chmod +x "$TMPDIR/bin/getent" "$TMPDIR/bin/pacman"
export PATH="$TMPDIR/bin:$PATH"

PROVISIONING_DIR="$TMPDIR/prov"
mkdir -p "$PROVISIONING_DIR"
printf 'wheel\ninput\ndocker\n' >"$PROVISIONING_DIR/groups"

# Load the real user_groups() from the provisioning command and run it. The
# backend it now calls has to come with it, or the check silently answers
# "command not found" and every package looks absent.
source "$ROOT/bin/omarchy-pkg-backend"
eval "$(sed -n '/^user_groups() {/,/^}/p' "$ROOT/bin/omarchy-provision-owner")"
groups=$(user_groups)

[[ ",$groups," == *",wheel,"* ]] || fail "user_groups always includes wheel"
[[ ",$groups," != *",input,"* ]] || fail "user_groups must not replay the blanket input grant"
[[ ",$groups," == *",docker,"* ]] && fail "user_groups must never grant the docker group"
pass "first-boot user_groups replays neither privileged default"

groups=$(STUB_PACKAGES=xpadneo-dkms user_groups)
[[ ",$groups," == *",input,"* ]] || fail "user_groups keeps input for installed controller support"
groups=$(STUB_PACKAGES=ydotool user_groups)
[[ ",$groups," == *",input,"* ]] || fail "user_groups keeps input for installed ydotool support"
pass "first-boot user_groups keeps deliberate input-group opt-ins"

# The Quattro upgrade must not re-add the user to docker.
if rg -q 'usermod -aG docker' "$ROOT/bin/omarchy-upgrade-to-quattro"; then
  fail "omarchy-upgrade-to-quattro must not add the user to the docker group"
fi
pass "the Quattro upgrade does not grant the docker group"
