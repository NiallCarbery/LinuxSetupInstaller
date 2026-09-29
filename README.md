# CachyOS Legion desktop setup

This repository rebuilds the user's CachyOS Hyprland/Noctalia desktop on a
Legion 5 15ACH6H (AMD GPU `05:00.0`, NVIDIA GPU `01:00.0`). The Lua files are
this desktop overlay. `install.sh` installs the CachyOS desktop base and places
each tracked file at its appropriate destination.

## Start on a fresh CachyOS installation

Use a normal user account with `sudo` access. Install CachyOS with its NVIDIA
driver first. In a terminal:

```bash
sudo pacman -S --needed git
git clone https://github.com/YOUR_USERNAME/cachyos-dotfiles.git ~/cachyos-dotfiles
cd ~/cachyos-dotfiles
./install.sh
```

The installer updates the system, installs separate system, desktop,
development, research, gaming, video and power package groups, then sets up
Git/GitHub SSH, paru and LazyVim. GitHub login uses the normal user's `gh`
session; it never calls `sudo gh`. It prompts for Git identity if absent and
creates `~/.ssh/id_ed25519` only if no default key exists.

It next creates AMD/NVIDIA DRM aliases, configures locale and power profiles,
installs the NVIDIA power controller, overlays Hyprland/UWSM settings, and
installs a Firefox launcher directed at the AMD render node. It finds the
official PIA `.run` installer in `~/Downloads` if one has been downloaded;
otherwise it prints the official download URL and continues. Package-owned
system Firefox files are not edited. Existing different user configuration
files are backed up before replacement.

Log out or reboot, select **Hyprland (UWSM)** and check:

```bash
hyprctl configerrors
powerprofilesctl get
sudo -n /usr/local/sbin/nvidia-power-mode status
LIBVA_DRIVER_NAME=radeonsi vainfo --display drm \
  --device /dev/dri/by-path/pci-0000:05:00.0-render
```

Restart Firefox completely after installing. The launcher and UWSM environment
set `MOZ_DRM_DEVICE` and `LIBVA_DRIVER_NAME` for AMD VA-API. Available AV1
decode support depends on the AMD GPU and codec; check `vainfo` and Firefox's
`about:support` to confirm active decoding for the video being played.

Power-saver and balanced apply the RTX 3060's 405–600 MHz graphics-clock range;
performance resets the clock restriction. This caps boost without forcing a
constant 600 MHz clock. GameMode does not automatically change the power
profile: choose performance before a GPU-heavy game if you want unrestricted
NVIDIA clocks.

## Optional Legion fan presets

```bash
./install.sh --fans
```

This installs the LenovoLegionLinux AUR CLI and DKMS packages if needed, then
saves six fan presets. If the module has not loaded yet, reboot and rerun the
same command. The script checks the number of fan points, backs up the active
curve, and restores it after saving the presets. It writes a second PWM curve
only when the driver exposes one.

## Updating

```bash
cd ~/cachyos-dotfiles
git pull --ff-only
./install.sh
```

Do not commit private keys, VPN credentials, browser profiles or other secrets.
This is tailored to the stated GPU PCI addresses and Samsung/eDP monitor modes;
the installer stops if the GPU addresses differ. The original Lua bindings
invoke Noctalia IPC commands, so check the launcher and media bindings after
Noctalia updates.
