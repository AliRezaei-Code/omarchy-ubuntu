# Omarchy on...

### Ubuntu 22.04

Omarchy runs on **Ubuntu 22.04**, and the whole `omarchy` command surface comes with it. `omarchy update` updates Omarchy and your packages the same way it does on Arch.

The dashboard comes in both forms. `omarchy dashboard` opens a graphical window when there's a display to draw it on, and falls back to a full-screen terminal UI when there isn't, so the same menu is a click or a keystroke away either way. Force one with `omarchy dashboard app` or `omarchy dashboard tui`, and read the menu as JSON from a script with `omarchy menu snapshot`.

What's different is the handful of things Omarchy inherits from Arch. Each of them tells you it needs an Arch-based Omarchy, rather than failing with some cryptic package-manager error:

- **AUR packages.** Ubuntu's equivalent is a PPA, or a `.deb` straight from the vendor.
- **Limine boot management.** Ubuntu boots through GRUB, so Omarchy leaves your bootloader alone.
- **mkinitcpio initramfs configuration.** Ubuntu builds its initramfs with `initramfs-tools` (or dracut) instead.
- **ALPM package hooks.** These fire inside Arch's package manager. dpkg has no equivalent hook point, so on Ubuntu they're simply inert.
- **Arch kernel package migration.** Ubuntu's kernel is the distribution's, upgraded through apt like everything else.
- **The Quickshell/Hyprland desktop shell.** Neither program is in the 22.04 archive, so the bar, the popups and the notification popper aren't part of this. The dashboard is.

The live installer ISO is a separate matter. It lives in the sibling `omarchy-iso` repository rather than this one, so there's no Ubuntu ISO to boot from; install Omarchy on top of an existing 22.04 system.

### Apple M1/M2 chips

[Asahi Alarm](https://asahi-alarm.org/) is a version of Arch for Apple M1/M2 computers built on top of [Asahi Linux](https://asahilinux.org/). You can get Omarchy running on top of that with some effort. See [the user-driven guide](https://github.com/omarchy-mac/omarchy-mac).

### Apple Virtual Machine

You can also install Omarchy inside a Parallels VM. Quite the cumbersome process, but there's [a user-driven guide](https://github.com/omacom/omarchy/discussions/452) for that too.

### VirtualBox

VirtualBox is a popular VM runner. [You can run Omarchy inside that too](https://github.com/omacom/omarchy/discussions/176). But performance probably won't be great.

### VMware Workstation on Windows 11

Another popular VM runner for Windows. [Omarchy has been setup inside of that as well](https://github.com/omacom/omarchy/discussions/572).

### Steam Deck

The Steam Deck runs on Arch, which means you can run Omarchy on your Steam Deck. Altynbek Orumbayev has [a full setup script and explanation on how to do it](https://github.com/aorumbayev/deckarchy). How cool is that!

### NixOS

Omarchy is really Arch + Hyprland, but Henry Sipp has [ported the essence of the setup to NixOS](https://github.com/henrysipp/omarchy-nix). So if you've been nix-pilled, here's a good starting point. It may or may not stay up-to-date with the latest Omarchy changes, but it's pretty cool none the less!

### Something else!

If you're trying to get Omarchy running on a configuration that isn't the default, you should join the #omarchy-on-other channel on [our community Discord](https://discord.gg/tXFUdasqhY).
