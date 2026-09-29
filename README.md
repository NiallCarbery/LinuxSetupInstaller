# CachyOS Legion desktop setup

This repo contains the user's Hyprland Lua files, UWSM environment, profile/lid watcher, udev GPU aliases, and fan presets. It targets the Legion 5 15ACH6H with AMD at `05:00.0` and NVIDIA at `01:00.0`.

## Fresh CachyOS install

Create a GitHub repository for this folder. On the fresh machine, from a regular user with sudo:

```bash
sudo pacman -S --needed git
git clone https://github.com/YOUR_USERNAME/cachyos-dotfiles.git ~/cachyos-dotfiles
cd ~/cachyos-dotfiles
bash install.sh
```

One `bash install.sh` run installs CachyOS's `cachyos-hypr-noctalia` base and the application packages, builds `paru` from its AUR PKGBUILD, installs the LazyVim starter into a fresh `~/.config/nvim`, sets locale and power profiles, creates the GPU aliases through udev, and copies the tracked config. It backs up differing existing files. It retains an existing Neovim config rather than replacing it. On first Neovim launch, plugins download; run `:LazyHealth`.

The base package supplies the Hyprland Lua loader and Noctalia defaults. If the user's config is missing, the script copies the CachyOS skeleton entrypoint and Noctalia config before applying the tracked modules. After installation, log out and choose **Hyprland (UWSM)** at the login screen. Check `hyprctl configerrors` and `hyprctl monitors all`.

The supplied bindings use `noctalia msg` calls from the user's original setup. CachyOS updates may change Noctalia's IPC; test the launcher, session and media binds after login, and update the repo's `binds.lua` if necessary. Do not publish secrets, VPN credentials, browser profiles, or SSH keys in the Git repository.

## Fan presets

To add the six original Legion fan presets:

```bash
bash install.sh --fans
```

This installs LenovoLegionLinux's AUR CLI and DKMS packages through `paru` if needed. If the module is not active immediately, reboot and run the same command again. The fan script backs up and restores the active curve after saving the presets.

## Updating

```bash
cd ~/cachyos-dotfiles
git pull --ff-only
bash install.sh
```

`AQ_DRM_DEVICES` expects the persistent `/dev/dri/amd-igpu` and `/dev/dri/nvidia-dgpu` names created by `system/80-legion-drm-aliases.rules`. The AMD Firefox render path is tied to PCI `05:00.0`. The custom monitor profile uses the attached 60 Hz eDP modeline and Samsung refresh rates of 59.95/120/144 Hz. Monitor 3 bindings remain inactive until `MONITOR3` is set to a real output.
