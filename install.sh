#!/usr/bin/env bash
# Run from a Git clone, as the desktop user. Re-run after git pull.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run as your regular user.' >&2; exit 1; }
[[ -f /etc/arch-release ]] || { echo 'Expected CachyOS/Arch.' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fans=0
for arg in "$@"; do case "$arg" in
  --fans) fans=1;;
  *) echo "Usage: $0 [--fans]" >&2; exit 2;;
esac; done

# Start with CachyOS's complete Hyprland + Noctalia environment and Lua loader.
sudo pacman -Syu --needed -- cachyos-hypr-noctalia base-devel git neovim ripgrep fd kitty zathura zathura-pdf-mupdf texlive-basic texlive-latexrecommended texlive-latexextra power-profiles-daemon firefox dolphin gnome-text-editor gnome-calculator btop hyprpicker qt6ct glib2

install_paru() {
  command -v paru >/dev/null && return
  local build_dir="$HOME/.cache/cachyos-dotfiles/paru"
  mkdir -p "$(dirname "$build_dir")"
  if [[ -d "$build_dir/.git" ]]; then
    git -C "$build_dir" pull --ff-only
  else
    git clone https://aur.archlinux.org/paru.git "$build_dir"
  fi
  (cd "$build_dir" && makepkg -si --needed)
  command -v paru >/dev/null || { echo 'Paru installation failed.' >&2; exit 1; }
}

install_lazyvim() {
  local target="$HOME/.config/nvim" starter="$HOME/.cache/cachyos-dotfiles/lazyvim-starter"
  if [[ -e "$target/init.lua" ]]; then
    if rg -q 'LazyVim|lazy.nvim' "$target/init.lua" "$target/lua" 2>/dev/null; then
      echo 'Existing LazyVim/lazy.nvim config retained.'
    else
      echo "Existing Neovim config retained at $target; install LazyVim manually if you want to replace it." >&2
    fi
    return
  fi
  if [[ -e "$target" ]]; then
    mv -- "$target" "$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$(dirname "$starter")" "$target"
  if [[ ! -d "$starter/.git" ]]; then
    git clone --depth 1 https://github.com/LazyVim/starter "$starter"
  fi
  git -C "$starter" archive HEAD | tar -x -C "$target"
  echo 'LazyVim starter installed. Run nvim to download plugins, then :LazyHealth.'
}

install_paru
install_lazyvim

install_gpu_aliases() {
  local amd=/sys/bus/pci/devices/0000:05:00.0/vendor
  local nvidia=/sys/bus/pci/devices/0000:01:00.0/vendor
  if [[ ! -r "$amd" || ! -r "$nvidia" || $(<"$amd") != 0x1002 || $(<"$nvidia") != 0x10de ]]; then
    echo 'Expected AMD GPU at 05:00.0 and NVIDIA GPU at 01:00.0; refusing to install Legion-specific GPU aliases.' >&2
    exit 1
  fi
  local source="$repo/system/80-legion-drm-aliases.rules"
  local target=/etc/udev/rules.d/80-legion-drm-aliases.rules
  if ! sudo test -e "$target" || ! sudo cmp -s "$source" "$target"; then
    if sudo test -e "$target"; then
      sudo cp -a "$target" "$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
    fi
    sudo install -m 0644 "$source" "$target"
  fi
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=drm --action=add
  sudo udevadm settle
  for device in /dev/dri/amd-igpu /dev/dri/nvidia-dgpu; do
    [[ -e "$device" ]] || { echo "GPU alias $device is missing; load the driver or reboot before starting Hyprland." >&2; exit 1; }
  done
}

# UWSM/Hyprland refers to these names, so create them before copying its config.
install_gpu_aliases
sudo localectl set-locale LANG=en_IE.UTF-8
sudo localectl set-keymap uk
sudo localectl set-x11-keymap gb pc105 '' terminate:ctrl_alt_bksp
sudo systemctl enable --now power-profiles-daemon
if [[ ! -e /etc/modprobe.d/90-legion-audio-powersave.conf ]]; then
  echo 'options snd_hda_intel power_save=1' | sudo tee /etc/modprobe.d/90-legion-audio-powersave.conf >/dev/null
fi
# The CachyOS package supplies the Lua entrypoint and default Noctalia config.
if [[ ! -f "$HOME/.config/hypr/hyprland.lua" && ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  if [[ -d /etc/skel/.config/hypr ]]; then
    mkdir -p "$HOME/.config/hypr"
    cp -a -n /etc/skel/.config/hypr/. "$HOME/.config/hypr/"
  fi
fi
if [[ ! -e "$HOME/.config/noctalia/config.toml" && -f /etc/skel/.config/noctalia/config.toml ]]; then
  mkdir -p "$HOME/.config/noctalia"
  cp -n /etc/skel/.config/noctalia/config.toml "$HOME/.config/noctalia/config.toml"
fi

install_one() {
  local src=$1 dest=$2 backup
  mkdir -p -- "$(dirname -- "$dest")"
  if [[ -e "$dest" ]] && cmp -s -- "$src" "$dest"; then return; fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    backup="$dest.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$dest" "$backup"
    echo "Backup: $backup"
  fi
  install -m 0644 -- "$src" "$dest"
}
for src in "$repo"/config/hypr/config/*.lua; do
  install_one "$src" "$HOME/.config/hypr/config/${src##*/}"
done
for src in "$repo"/config/uwsm/*; do
  install_one "$src" "$HOME/.config/uwsm/${src##*/}"
done
mkdir -p "$HOME/.local/bin"
if [[ -e "$HOME/.local/bin/hypr-power-profile" ]] && ! cmp -s "$repo/scripts/hypr-power-profile" "$HOME/.local/bin/hypr-power-profile"; then
  cp -a "$HOME/.local/bin/hypr-power-profile" "$HOME/.local/bin/hypr-power-profile.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
fi
install -m 0755 "$repo/scripts/hypr-power-profile" "$HOME/.local/bin/hypr-power-profile"
if (( fans )); then
  if ! command -v legion_cli >/dev/null || ! find /sys/class/hwmon -maxdepth 2 -name name -exec grep -lqx legion_hwmon {} + 2>/dev/null | grep -q .; then
    if command -v paru >/dev/null; then
      paru -S --needed -- lenovolegionlinux-dkms-git lenovolegionlinux-git
    else
      echo 'Paru is missing despite the bootstrap step.' >&2
      echo 'Reboot/load the driver and re-run --fans.' >&2
      exit 1
    fi
  fi
  if ! find /sys/class/hwmon -maxdepth 2 -name name -exec grep -lqx legion_hwmon {} + 2>/dev/null | grep -q .; then
    echo 'legion_hwmon is not loaded yet; reboot and re-run --fans.' >&2
    exit 1
  fi
  sudo bash "$repo/scripts/setup-legion-fans"
fi
for app in noctalia uwsm hyprctl gdbus; do
  command -v "$app" >/dev/null || echo "Missing prerequisite: $app" >&2
done
for device in /dev/dri/amd-igpu /dev/dri/nvidia-dgpu /dev/dri/by-path/pci-0000:05:00.0-render; do
  [[ -e "$device" ]] || echo "Check GPU path: $device" >&2
done
[[ -e "$HOME/.config/hypr/hyprland.conf" ]] || echo 'Check that your Hyprland Lua entrypoint loads these config modules.' >&2
echo 'Installed. Log out and back in, then run: hyprctl configerrors'
