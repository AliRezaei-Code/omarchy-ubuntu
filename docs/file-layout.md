# File layout

How `omarchy/` is organized and where everything ends up on an installed
system.

## Mental model

Two Arch packages are built from this one repo (PKGBUILDs live in the
separate `omarchy-pkgs` repository, under `pkgbuilds/`):

- **`omarchy`** — runtime binaries (`bin/`, including `bin/omarchy-dev-*`),
  install/finalize scripts (`install/`), migrations, themes, and the
  Quickshell desktop (`shell/`). Depends on `omarchy-settings`.
- **`omarchy-settings`** — everything that has to be on the target *before*
  the omarchy package installs (specifically before `useradd -m` and the
  limine bootloader install): all `/etc/skel/**`, `/etc/` drop-ins,
  package-owned system files under `/usr/share` and `/usr/lib`, fonts,
  plymouth theme, sddm theme, branding, plus the limine/snapper configs
  (mkinitcpio hooks, limine-entry-tool drop-ins, snapper template, the
  `default/limine/` and `default/snapper/` trees, and the boot/snapshot
  story end-to-end). Also ships the three debug binaries
  (`omarchy-debug`, `omarchy-debug-idle`, `omarchy-upload-log`) needed by
  the live ISO env.

Two other packages live in `omarchy-pkgs` but stand alone:
`omarchy-keyring` (GPG keys for pacman) and `omarchy-nvim` (the Neovim
setup; independently seeds `/etc/skel`).

Some trees ship in neither package and exist only in the repo: `manual/`
(user manual chapters), `agents/skills/` (contributor task guides), `docs/`,
`test/`, and `plans/`.

Three layers populate `$HOME`:

1. **Seed** — `omarchy-settings` ships static defaults to `/etc/skel/`.
   Arch's `useradd -m` copies that tree into a new user's `$HOME` at user
   creation. This is the only mechanism that touches a brand-new user's home
   for these files.
2. **Finalize** — `omarchy-provision-user` (routed as `omarchy finalize
   user`) runs once per user and handles the things `/etc/skel` can't do
   because they need `$HOME` expansion, the live `$OMARCHY_PATH`, or runtime
   detection of system state.
3. **Resync** — `omarchy-reinstall-configs` is the explicit, destructive
   command for an existing user to clobber their configs back to shipped
   defaults.

`/etc/skel` only fires at user creation. Existing users picking up new
defaults must use the resync command.

Deferred-provisioning installs (`omarchy-apply-system --defer-provisioning`)
create no user at all: the ISO leaves `/var/lib/omarchy/provisioning/pending`
behind, which arms `omarchy-provision-owner.service` (shipped from
`install/provisioning/`, alongside the factory-reset finish unit and
`setup-form.sh`). On first boot `bin/omarchy-provision-owner` creates the
user on tty1 and runs the finalize step itself.

Current generated theme state lives under
`~/.local/state/omarchy/current/`. Keep `~/.config/omarchy/` for files a user
may intentionally version in a dotfile manager, such as user themes, hooks,
shell layout, plugins, and themed template overrides.

## Build-time map (repo → installed paths)

```
omarchy/                            built into          installed at
─────────────────────────           ──────────────      ────────────────────────────────────

bin/omarchy-*                  ──►  omarchy             /usr/bin/omarchy-*
                                                        (and symlinks in /usr/share/omarchy/bin/)
bin/omarchy-debug,
bin/omarchy-debug-idle,
bin/omarchy-upload-log         ──►  omarchy-settings    /usr/bin/  (needed before omarchy is installed)
bin/omarchy-pkg-backend         ──►  omarchy-settings    /usr/bin/  (sourced by the three above)

default/libalpm/hooks/*.hook
                                ──►  omarchy             /usr/share/libalpm/hooks/*.hook

install/**                     ──►  omarchy             /usr/share/omarchy/install/
migrations/**                  ──►  omarchy             /usr/share/omarchy/migrations/
themes/**                      ──►  omarchy             /usr/share/omarchy/themes/
shell/**                       ──►  omarchy             /usr/share/omarchy/shell/
version                        ──►  omarchy             /usr/share/omarchy/version
                                                        + /etc/skel/.local/state/omarchy/migrations/*

config/**                      ──►  omarchy-settings    /etc/skel/.config/**         (seeds new users)
                                                        /usr/share/omarchy/config/** (resync source)
etc/fastfetch/config.jsonc     ──►  omarchy-settings    /etc/fastfetch/config.jsonc
etc/xdg/kitty/kitty.conf       ──►  omarchy-settings    /etc/xdg/kitty/kitty.conf

applications/*.desktop         ──►  omarchy-settings    /etc/skel/.local/share/applications/
                                                        /usr/share/omarchy/applications/
default/applications/battlenet.desktop
                                ──►  omarchy-settings    /usr/share/omarchy/default/applications/
                                                        (installer-only launcher template)
applications/icons/*           ──►  omarchy-settings    /usr/share/icons/hicolor/{48,256,scalable}/apps/

etc/**                         ──►  omarchy-settings    /etc/**           (drop-ins we own outright)
  ├─ mkinitcpio.conf.d/{omarchy_hooks,thunderbolt_module}.conf
  ├─ limine-entry-tool.d/{omarchy-defaults,omarchy-uki}.conf
  ├─ NetworkManager/, sudoers.d/, sysctl.d/, tmpfiles.d/,
  │  profile.d/omarchy.sh, …                            (a summary — `ls etc/` for the full ~17-entry tree)
  └─ security/faillock.conf, nsswitch.conf,
     cups/cups-browsed.conf, plymouth/plymouthd.conf    /usr/share/omarchy/etc-overrides/
                                                          → /etc/* (post_install cp -f, see below)

default/limine/limine.conf     ──►  omarchy-settings    /usr/share/omarchy/default/limine/limine.conf
default/limine/default.conf    ──►  omarchy-settings    /usr/share/omarchy/default/limine/default.conf
                                                        (template; ISO substitutes @@CMDLINE@@ → /etc/default/limine)
default/snapper/root           ──►  omarchy-settings    /etc/snapper/config-templates/omarchy
                                                        (+ /usr/share/omarchy/default/snapper/root)

default/**                     ──►  omarchy-settings    /usr/share/omarchy/default/
  ├─ bash/env-bootstrap                                 /usr/share/omarchy/default/bash/env-bootstrap
  │                                                       (sourced by every shell/session entry point; see "Env bootstrap")
  ├─ bashrc                                             /usr/share/omarchy/etc-overrides/dot.bashrc
  │                                                       → /etc/skel/.bashrc (post_install cp -f)
  ├─ hypr/toggles/*.lua (flags,
  │    single-window-aspect-ratio, window-no-gaps)      /etc/skel/.local/state/omarchy/toggles/hypr/
  ├─ nautilus-python/extensions/*.py                    /etc/skel/.local/share/nautilus-python/extensions/
  ├─ uwsm/env.d/10-omarchy                              /usr/share/uwsm/env.d/
  ├─ environment.d/*.conf                               /usr/lib/environment.d/
  ├─ fontconfig/conf.avail/50-omarchy.conf              /usr/share/fontconfig/conf.avail/
  │                                                       + symlink /etc/fonts/conf.d/50-omarchy.conf
  ├─ xdg-terminal-exec/*.list                           /usr/share/xdg-terminal-exec/
  ├─ applications/mimeapps.list                         /usr/share/applications/mimeapps.list
  ├─ systemd/user/*.service                             /usr/lib/systemd/user/
  ├─ systemd/user/app.slice.d/10-oomd.conf              /usr/lib/systemd/user/app.slice.d/
  ├─ systemd/system-sleep/unmount-fuse                  /usr/lib/systemd/system-sleep/
  ├─ systemd/zram-generator.conf.d/90-omarchy.conf      /usr/lib/systemd/zram-generator.conf.d/
  ├─ fonts/omarchy/omarchy.ttf                          /usr/share/fonts/omarchy/
  ├─ sddm/omarchy/                                      /usr/share/sddm/themes/omarchy/
  ├─ sddm/hyprland.lua                                  /usr/share/sddm/hyprland.lua
  ├─ wayland-sessions/omarchy.desktop                   /usr/local/share/wayland-sessions/
  └─ plymouth/                                          /usr/share/plymouth/themes/omarchy/

logo.{txt,svg}, icon.{txt,png}  ──► omarchy-settings    /usr/share/omarchy/  (resync source)
                                                        /usr/share/pixmaps/omarchy.png
                                                        /usr/share/icons/hicolor/256x256/apps/omarchy.png
                                                        /etc/skel/.config/omarchy/branding/{about,screensaver}.txt
```

The hardware-conditional `force-igpu` and `keyboard-backlight` sources also live under `default/systemd/system-sleep/`, but their setup commands publish root-owned copies only on machines that need them; they are not installed by `omarchy-settings`.

`bin/omarchy-pkg-backend` has to travel in `omarchy-settings` for the same
reason the three commands above do: `omarchy-debug` and `omarchy-upload-log`
run on a live ISO before the `omarchy` package is installed, and they ask the
backend which package manager they are on. Without it in the same package they
cannot answer on a machine that has Omarchy's shell but not Omarchy's
packages.

### Why `etc-overrides/` exists

Some files under `/etc/` (`.bashrc` in `/etc/skel`, `nsswitch.conf`,
`security/faillock.conf`, `cups/cups-browsed.conf`, `plymouth/plymouthd.conf`)
are owned by upstream Arch packages, so we can't install over them via pacman
without a file conflict. Instead their sources (under `etc/` in the repo;
`.bashrc` from `default/bashrc`) ship at
`/usr/share/omarchy/etc-overrides/` and the `omarchy-settings` `post_install`
/ `post_upgrade` scriptlet `cp -f`'s them into place.

Tradeoff: user edits to those files get clobbered on every `omarchy-settings`
upgrade. This is documented in the PKGBUILD.

## A tool the target release does not ship

`bin/omarchy-requires-arch` names the Arch-only half of the port.
`bin/omarchy-requires-tool` names the other half: a tool Ubuntu 22.04
genuinely does not have, which has nothing to do with Arch and would be
wrong to describe as Arch-only.

ImageMagick is the case that matters. Five commands are written against
ImageMagick 7's `magick` -- `omarchy-transcode`, `omarchy-transcode-ascii`,
`omarchy-plymouth-set` and `omarchy-plymouth-preview` guard on it, and
`omarchy-bar-text-color` treats it as an enhancement and falls back.
Ubuntu 22.04 packages ImageMagick 6, which provides `convert` and no
`magick` at all, so the deb depends on `imagemagick` and those commands
stop with `omarchy: 'magick' is not available: ImageMagick 7 is not in
the Ubuntu 22.04 archive` rather than dying partway through with a bare
`command not found` that says nothing about the image the caller handed
it.

## The unsupported surface

This tree runs on Ubuntu 22.04 (jammy) as well as Arch. `bin/omarchy-pkg-backend` picks pacman or apt at runtime and Arch is still the default, so the paths in the build-time map above are all live on an Arch install and inert on a deb one; the installed layout itself does not change, because the deb puts the same tree at `/usr/share/omarchy` with `/usr/bin/omarchy-*` binaries, which is the packaged contract `default/bash/env-bootstrap` already encodes. Parity here does not mean pretending. It means an Arch-only command says which thing it belongs to, rather than failing three frames deep inside a package manager that isn't there. The generic form of that is `bin/omarchy-requires-arch`, which prints `omarchy: '<feature>' requires an Arch-based Omarchy system` to stderr and exits 1.

`install/pkg-map.conf` is the machine-readable form of the same boundary. It is one row per Arch name that Ubuntu spells differently, and a row with an **empty** package list where somebody checked the jammy archive and there is no equivalent. An empty list is a declaration, not an omission: it is what stops a caller asking apt for a package that does not exist and reporting a failure nobody can act on. The seven items below are the parts of the tree that boundary leaves out.

### AUR packages

`bin/omarchy-pkg-aur-add`, `bin/omarchy-pkg-aur-install` and `bin/omarchy-pkg-aur-accessible` are Omarchy's AUR client, and `bin/omarchy-update-aur-pkgs` is the AUR phase of `omarchy update`. All four drive `yay`. The AUR is an Arch-only user repository, so there is nothing on Ubuntu that speaks it and there is no way to shim it.

On the deb backend all four print `The AUR is only available on Arch-based Omarchy` on stderr, and `install/pkg-map.conf` declares `yay` with an empty package list. The three `omarchy-pkg-aur-*` commands exit 1; `omarchy-update-aur-pkgs` exits 0, because it is a phase inside `omarchy update` and must not abort the update that has already upgraded everything else. `omarchy-pkg-aur-accessible` returning non-zero is the entire integration: the shipped menu already keys its AUR rows on that command, so the rows disappear without any menu data learning that the port exists. A user installs a PPA or a vendor `.deb` instead.

### Limine boot management

Omarchy's bootloader is Limine, configured from `default/limine/limine.conf` and `default/limine/default.conf` plus the two `limine-entry-tool` drop-ins in `etc/limine-entry-tool.d/` (`omarchy-defaults.conf`, `omarchy-uki.conf`). Ubuntu boots through GRUB, which its own tooling owns; rewriting a distribution's bootloader is not something a package install should do, and the two are not interchangeable.

On Ubuntu no bootloader is touched at all — no entry is written, no `@@CMDLINE@@` substitution happens, `omarchy-refresh-limine` has nothing to refresh — and `install/pkg-map.conf` declares `limine` and `limine-svn` with empty package lists. Boot entries, kernel images and the boot menu are GRUB's, maintained by `update-grub`.

### mkinitcpio initramfs configuration

`etc/mkinitcpio.conf.d/omarchy_hooks.conf` and `etc/mkinitcpio.conf.d/thunderbolt_module.conf` are mkinitcpio drop-ins: the Omarchy hooks module and the Thunderbolt module. mkinitcpio is Arch's initramfs generator, and its module vocabulary is not a packaging detail you can port — Ubuntu builds its initramfs with `initramfs-tools` (or dracut) from its own module and hook set under `/etc/initramfs-tools/`, which is a different program with a different configuration language.

On Ubuntu the two drop-ins are inert and `mkinitcpio`, `mkinitcpio-firmware` and `mkinitcpio-openssl` are declared with empty package lists in `install/pkg-map.conf`. Ubuntu's initramfs is rebuilt by `update-initramfs`, and nothing in this tree edits it.

### ALPM package hooks

`default/libalpm/hooks/*.hook` is four files that pacman runs inside its own transactions: `00-omarchy-update-guard.hook` (PreTransaction on any upgrade, redirecting to `omarchy update`), `05-omarchy-passwordless-revoke.hook` (PreTransaction on an `omarchy-settings` change), and the pair `10-omarchy-hyprland-reload-pause.hook` / `90-omarchy-hyprland-reload-resume.hook`, which pause and resume Hyprland's config auto-reload around a settings update. ALPM is Arch's package library; dpkg has no hook point inside a transaction, so there is nowhere to route them.

The four files stay in the tree, and that is the decision rather than the omission: upstream ships them, so deleting them would make every merge from `quattro` conflict over a directory that is still theirs. On Ubuntu they simply never fire. The one hand-reachable path, `bin/omarchy-update-pacman-guard` — the sole target of `00-omarchy-update-guard.hook` — refuses with `omarchy: 'the ALPM package hook' requires an Arch-based Omarchy system`, because a user who reaches it by hand is asking about a package manager they do not have.

### Arch kernel package migration

The migrations that install, replace and roll back the `linux-t2` kernel packages Omarchy ships and migrates between (`migrations/1785273276.sh`, `migrations/1789325478.sh`, `migrations/1789444024.sh`, and anything else keyed on `linux-t2`) are coupled to Arch's kernel packages by name. Those packages do not exist in Ubuntu, where the kernel is the distribution's and is versioned and upgraded through apt like everything else.

They carry `# omarchy:platform=arch`, which `omarchy-migrate` reads from the first five lines of the file. On the deb backend such a migration does not run, and `omarchy-migrate` still writes its marker under `~/.local/state/omarchy/migrations/` rather than leaving it unmarked — a migration that never records itself is one re-examined at every login for the rest of the machine's life. The kernel a user gets is whatever `apt` provides.

### The Quickshell / Hyprland desktop shell

`shell/**` is a Quickshell interface to Hyprland: the bar, the popups, the notification popper, the menu. Neither Quickshell nor Hyprland is in the jammy archive, and neither is a package-rename problem, so the shell cannot run here at all.

What a user gets instead is `omarchy dashboard`, which picks the GTK/libadwaita app when there is a display to draw on and the terminal UI otherwise, with `omarchy dashboard app` and `omarchy dashboard tui` to force either. The shell is not dead weight, and that is the part worth knowing before deleting it: the model is what all three surfaces agree on. `shell/plugins/menu/MenuModel.js` parses the menu and evaluates its `when:` guards for the Quickshell menu (`shell/plugins/menu/Menu.qml`) and for `shell/plugins/menu/MenuSnapshot.js`, which builds the resolved tree behind `omarchy menu snapshot`; the GTK app and the TUI both render that snapshot rather than deciding visibility for themselves, and `shell/plugins/menu/TuiModel.js` holds the terminal UI's pure logic with `DashboardTui.js` doing only the drawing. A row therefore means the same thing in all three, and the shell's menu cannot drift from the two front ends that replaced it.

### The ISO installer

The live installer lives in the sibling `omarchy-iso` repository, not here. This repo's root-side orchestration — `omarchy-apply-system`, `omarchy-provision-owner`, `install/config/`, `install/hardware/`, `install/login/` — is written to be driven by that image, and the ISO is a separate artifact with a separate build.

So this one is out of scope rather than broken: there is no Ubuntu ISO to build, and no part of the target Ubuntu system's behavior depends on there being one. A user on 22.04 installs the packaged tree onto an existing system and never enters the provisioning-owner path.

## Locate indexing

`default/systemd/system/plocate-updatedb.service.d/10-omarchy.conf` ships through `omarchy-settings` to `/usr/lib/systemd/system/plocate-updatedb.service.d/10-omarchy.conf`. It replaces the existing service's `ExecStart` with `updatedb --prune-bind-mounts=no --add-prunepaths=/.snapshots`, keeping Btrfs subvolume mounts searchable and excluding Snapper snapshots. The upstream service retains its timer, resource limits, and sandbox; Omarchy's existing AC-power condition still applies.

`/etc/updatedb.conf` remains owned by plocate and is never rewritten by Omarchy. The command-line options override bind-mount pruning and add to the administrator's existing path exclusions. Installer and AUR package refreshes pass the same options directly because installation may run without systemd and an explicitly requested refresh should work on battery.

Arch's systemd package hook reloads units when the vendor drop-in is installed or upgraded. The settings package containing the drop-in must ship alongside the runtime package that removes the old configuration helper and migration. Pacman removes those retired files; no new state migration is needed. A running indexer finishes with its original options, and subsequent service starts use the drop-in. For an immediate local test after installing the packages, restart `plocate-updatedb.service` while connected to AC power.

## Env bootstrap (`default/bash/env-bootstrap`)

Single source of truth for `OMARCHY_PATH` and dev-link-aware `PATH`. It:

- Sources `/etc/omarchy.conf` (written by `omarchy-dev-link`, reset to the
  package path by `omarchy-dev-unlink`) if present; otherwise forces
  `OMARCHY_PATH=/usr/share/omarchy` so a stale inherited value can't survive
  an `omarchy-dev-unlink`.
- Prepends `$OMARCHY_PATH/bin` to `PATH` **only when** `OMARCHY_PATH` is
  not `/usr/share/omarchy`. On a production install the binaries are
  already on `PATH` as `/usr/bin/omarchy-*` via the `omarchy` package.
- Appends `~/.local/share/mise/shims` and `~/.local/bin` so login shells and
  the uwsm session find mise-managed tools — kept in sync with the PAM `PATH`
  line written by `install/config/ssh-command-path.sh`, which covers SSH
  commands that run no shell setup at all.

Sourced by every entry point that needs the env set:

```
/etc/profile.d/omarchy.sh                      (system login shells)
/etc/skel/.bashrc                              (interactive shells)
/usr/share/uwsm/env.d/10-omarchy               (Hyprland session via uwsm)
/usr/share/omarchy/default/bash/envs           (SSH / non-login bash)
```

Idempotent — safe to source more than once in the same shell.

`PATH` covers everything the user runs, but not `sudo`, which resolves command
names against `secure_path` from `/etc/sudoers`. So `omarchy-dev-link` also
writes `/etc/sudoers.d/omarchy-dev-path`:

```
Defaults secure_path="<checkout>/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"
```

Without it, `sudo omarchy-*` fails for a command the package has not shipped
yet and silently runs the packaged copy of one it has. The drop-in is validated
with `visudo -c` before install and removed by `omarchy-dev-unlink`; unlike
`/etc/omarchy.conf`, it takes effect without a reboot.

## Runtime finalization (`omarchy-provision-user`)

Runs once per user. It does **not** copy `~/.config/**`, `~/.bashrc`,
`flags.lua`, or the nautilus extensions — `/etc/skel` already seeded those.
It only does the things `/etc/skel` can't:

- Skill symlinks into `~/.agents/skills/<name>`, `~/.claude/skills/<name>`, `~/.codex/skills/<name>`, `~/.pi/agent/skills/<name>`, `~/.gemini/config/skills/<name>` (Antigravity), `~/.hermes/skills/<name>`, and each existing `~/.hermes/profiles/*/skills/<name>` → `$OMARCHY_PATH/default/agents/skills/<name>`, looping over every skill directory there (currently `omarchy` and `diagnose-crash`) so new skills need no edit. Symlinks (not copies) so `omarchy dev link` against a dev checkout repoints them correctly. Hermes profile dirs are only linked when they already exist — provision does not create Hermes profiles.
- `xdg-user-dirs-update` (Templates/Public/Desktop folded back into `$HOME`)
  and `~/.config/gtk-3.0/bookmarks` (needs `$HOME` expansion).
- Hyprland's package-owned default input reads `XKBLAYOUT` / `XKBVARIANT`
  from `/etc/vconsole.conf`; no per-user Hyprland config rewrite is needed.
- `xdg-settings set default-web-browser chromium.desktop` and
  `xdg-mime default HEY.desktop x-scheme-handler/mailto` (XDG-aware paths).
- `omarchy-refresh-applications` (composes generated `.desktop` launchers).
- Sources `install/user/all.sh` — theme, chromium, git, xcompose, mise,
  keyring, per-user hardware quirks (asus mic/mixer, framework f13 audio, …).
- On `--first-install`, marks every shipped user migration as already applied
  for the freshly-created user.

Idempotency marker: `~/.local/state/omarchy/done/finalize-user`, managed
by `omarchy-done`.

The ISO calls it as `omarchy-provision-user --force --first-install` in the
target chroot as the install user, after `omarchy-apply-system` has finished
the root-side work. `omarchy-provision-owner` makes the same call (with
`OMARCHY_SETUP_CONTEXT=provision-owner`) when it creates the user during
deferred first-boot provisioning.

## Migrations (`omarchy-migrate`)

See [`migrations.md`](../agents/skills/migrations.md) for the full migration model, authoring
guidelines, and troubleshooting notes.

Omarchy migrations live in `migrations/*.sh` and run per-user through
`omarchy-migrate`. Completion state lives in
`~/.local/state/omarchy/migrations/`, so every user gets a chance to run every
migration. Migrations run as the user; privileged work should invoke the
appropriate helper or privilege prompt. Migrations must be idempotent;
machine-wide repairs should no-op when another user already applied them.

Each graphical user has `omarchy-migrate-notify.service`, started once per login
through `WantedBy=graphical-session.target` and ordered after that target so
notification actions can safely launch through UWSM. The `omarchy-pkgs`
PKGBUILD has shipped `omarchy-update-user-notify.service` as a symlink onto
it, so users enabled under the old unit name keep working before they reach
migration `1785095882`.
It runs `omarchy-migrate-notify` as
that user, which checks `omarchy-migrate --pending`. If this user has missing
migration state, it shows a notification that opens a terminal for
`omarchy-migrate`. The notifier never runs migrations in the background.

Login is the only trigger. Nothing watches the packaged migration directory: a
watcher cannot tell a bypassed `pacman -Syu` from the package transaction inside
a normal `omarchy update`, so it notified about migrations that `omarchy-migrate`
was already applying in the visible update terminal.

`omarchy-migrate` waits for any active pacman transaction to finish, then runs
pending migrations. It does not need `--force`; migrations happen when state
files are missing. `omarchy update` runs `omarchy-migrate` after the package
transaction in the already-visible update terminal, then runs
`omarchy-hook post-update`.

## First-run (`omarchy-provision-first-run`)

Runs once on first interactive login, after the user manager is live. It
first runs `omarchy-provision-user || true` so finalize catches up if it
never ran, then handles the steps that need a running graphical session
and/or a working user systemd instance:

- `omarchy-hook-install post-update` for the three shipped hooks
  (`install-voxtype.hook`, `setup-fingerprint.hook`, `setup-agent.hook`).
- `install/user/first-run/enable-user-units.sh` — daemon-reload, then
  `systemctl --user enable --now` the shipped user units (`bt-agent`,
  `omarchy-sleep-lock`, `omarchy-recover-internal-monitor`,
  `omarchy-migrate-notify.service`, `omarchy-fcitx5.service`,
  `omarchy-crash-watch.service`) so they run in the first session too.
  Done here, not at finalize, because
  the user manager isn't reachable from the ISO chroot; `ConditionPath*`
  in the unit files keeps services inert when they don't apply.
- `install/user/first-run/gnome-theme.sh`,
  `install/user/first-run/gtk-primary-paste.sh` — GNOME/GTK settings that
  need the dconf daemon.
- `install/user/first-run/audio-tuning.sh` — apply speaker tuning.
- `install/user/first-run/welcome.sh` — keybindings toast that greets the
  first login and opens the cheatsheet when clicked. The caller runs
  `omarchy-notification-wait` once before this and the Wi-Fi step, so both
  toasts land on a live notification server.
- `install/user/first-run/wifi.sh` — Wi-Fi/update toasts (waits detached on
  `nm-online` so the update prompt only lands once there is a connection).

The entire sequence has one idempotency marker:
`~/.local/state/omarchy/done/first-run-user`, managed by `omarchy-done`.
Completed users exit before any first-run step. On failure the marker is not
written and the sequence retries next login.

Completion markers live under `~/.local/state/omarchy/done/`. Use
`omarchy-done check <name>` to check one and `omarchy-done mark <name>` to record it.
Use `omarchy-done ensure <name>` as a conditional when the guarded work should
run only once; it records completion before returning success.
The Quattro upgrade completes graphical first-run for upgraded users and moves
the legacy finalization marker from `~/.local/state/omarchy/` into `done/`.

## Root-side install orchestration

`omarchy-apply-system` (root, in chroot) runs target-side setup at ISO
finalization. It sources:

- `install/config/all.sh` — theme links, lockout limits, lockscreen PAM,
  powerprofilesctl shebang fix, SSH command path and keepalive, docker setup,
  Snapper retention, locate index tuning, service enablement, firewall.
- `install/hardware/all.sh` via `omarchy-apply-hardware` — vendor- and
  device-specific kernel modules, udev rules, microcode, wireless regdom,
  ASUS / Framework / Intel / Apple / Lenovo quirks.
- `install/login/all.sh` — SDDM theme/session config.
- `install/post-install/all.sh` — final pacman/udev/localdb passes.

Logging goes to `/var/log/omarchy-install.log` via
`install/helpers/logging.sh`.

The package lists the ISO pacstraps live at `install/omarchy-base.packages`
and `install/omarchy-other.packages`; the ISO builder also reads them when
constructing its offline mirror.

## Explicit resync (`omarchy-reinstall-configs`)

When an existing user wants to reset to shipped defaults:

```
~/  ←  cp -af /etc/skel/.
```

Replaying `/etc/skel` over `$HOME` is exactly what `useradd -m` does for a
brand-new user, so this one copy resyncs `.bashrc`, `.config/**`,
`.local/share/applications/`, the nautilus-python extensions, hypr toggles,
branding files, and the shipped migration markers in a single pass.

Then it runs `omarchy-refresh-limine`, `omarchy-refresh-plymouth`, and the
nvim refresh. Destructive: existing user files copied from `/etc/skel` are
clobbered without backup. Fastfetch is package-owned at
`/etc/fastfetch/config.jsonc`; delete `~/.config/fastfetch/config.jsonc` to
return to the packaged default.

## Quick reference: where does X live?

| Goal | Touch |
| --- | --- |
| Default file at `~/.config/foo/` | `config/foo/` |
| `/etc/` drop-in we own outright | `etc/` |
| `/etc/` file owned by an upstream package | `etc/` (see `etc/security/faillock.conf`), then add to `etc-overrides` in `omarchy-settings` PKGBUILD + scriptlet |
| Package-owned system file (e.g. systemd user service in `/usr/lib`) | `default/`, then add the `install -Dm644` line in `omarchy-settings` PKGBUILD |
| Per-user file that's static but lives outside `~/.config` | `default/`, then add `install -Dm644 ... $pkgdir/etc/skel/...` in `omarchy-settings` PKGBUILD |
| Runtime tweak that needs `$HOME` or live system state | extend `omarchy-provision-user`, or add a per-user leaf under `install/user/` and wire into `install/user/all.sh` |
| One-time root-side setup step | `install/config/*.sh` or `install/hardware/*.sh`, wire into `install/config/all.sh` or `install/hardware/all.sh` |
| One-time fix for existing installs | `migrations/<unix-timestamp>.sh` |
| Package-owned path something else may already write | Prefer a path nothing else writes, such as a vendor drop-in under `/usr/lib`. Otherwise the `--overwrite` entry in `bin/omarchy-update-system-pkgs` has to ship a release before the file |
| User-facing `omarchy-*` command | `bin/omarchy-<group>-<verb>` — see `GROUP_DESCRIPTIONS` in `bin/omarchy` |
| New stock theme | `themes/<name>/` (+ matching templates under `default/themed/` if they need theme colors) |
| User-installed theme | `~/.config/omarchy/themes/<name>/` |
| Generated current theme/background state | `~/.local/state/omarchy/current/` |

## Kitty defaults and user overrides

Kitty loads `/etc/xdg/kitty/kitty.conf` before `~/.config/kitty/kitty.conf`. The `omarchy-settings` package owns the system file; the user template contains only the active theme include and commented examples for personal overrides. Keeping the theme include in the user file lets users remove it without changing the packaged defaults. Individual inherited keybindings can be unmapped with an empty `map <shortcut>` directive, or all inherited bindings can be cleared with `clear_all_shortcuts yes`.

The system default uses `allow_remote_control socket-only` so Omarchy can query the active terminal directory over its Unix socket while Kitty rejects remote-control requests arriving through terminal output. Changing this setting requires restarting Kitty. The migration refreshes the exact previous stock config with a backup; customized configs retain their settings and ordering, with only explicit unrestricted `yes`, `y`, or `true` remote-control settings commented out.
