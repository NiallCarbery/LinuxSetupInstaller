#!/usr/bin/env bash

# ============================================================
# CachyOS Legion Setup
# ============================================================

set -euo pipefail

# ============================================================
# GLOBALS
# ============================================================

REPO="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd
)"

INSTALL_FANS=0

# ============================================================
# OUTPUT HELPERS
# ============================================================

info() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$1"
}

warn() {
  printf '\n\033[1;33mWARNING:\033[0m %s\n' "$1" >&2
}

die() {
  printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2
  exit 1
}

# ============================================================
# ARGUMENTS
# ============================================================

parse_arguments() {
  for arg in "$@"; do
    case "$arg" in

    --fans)
      INSTALL_FANS=1
      ;;

    -h | --help)
      cat <<'EOF'
Usage:
    ./install.sh [--fans]

Options:
    --fans      Install LenovoLegionLinux and configure fan curves
    -h,--help   Show this help
EOF
      exit 0
      ;;

    *)
      die "Unknown argument: $arg"
      ;;

    esac
  done
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

preflight_checks() {
  info "Running pre-flight checks"

  if [[ $EUID -eq 0 ]]; then
    die "Run this script as your normal user, not root."
  fi

  if [[ ! -f /etc/arch-release ]]; then
    die "This installer expects CachyOS or Arch Linux."
  fi

  if [[ ! -d "$REPO/config" ]]; then
    warn "Repository config/ directory not found."
  fi

  if [[ ! -d "$REPO/scripts" ]]; then
    warn "Repository scripts/ directory not found."
  fi

  if [[ ! -d "$REPO/system" ]]; then
    warn "Repository system/ directory not found."
  fi
}

# ============================================================
# PACKAGE GROUPS
# ============================================================

#
# Keep these separated by purpose.
#
# This makes it much easier later to replace Noctalia with our
# own desktop without disturbing the rest of the system.
#

SYSTEM_PACKAGES=(
  base-devel
  git
  github-cli
  openssh
  glib2
)

NOCTALIA_DESKTOP_PACKAGES=(
  cachyos-hypr-noctalia

  kitty
  dolphin

  firefox

  gnome-text-editor
  gnome-calculator

  btop
  hyprpicker
  qt6ct
)

DEVELOPMENT_PACKAGES=(
  neovim
  ripgrep
  fd
)

RESEARCH_PACKAGES=(
  texlive-basic
  texlive-latexrecommended
  texlive-latexextra

  zathura
  zathura-pdf-mupdf

  calibre
)

POWER_PACKAGES=(
  power-profiles-daemon
)

# ============================================================
# SYSTEM UPDATE
# ============================================================

update_system() {
  info "Updating CachyOS / Arch"

  sudo pacman -Syu --noconfirm
}

# ============================================================
# PACKAGE INSTALLATION
# ============================================================

install_package_group() {
  local name="$1"
  shift

  info "Installing $name"

  sudo pacman -S \
    --needed \
    --noconfirm \
    -- "$@"
}

install_official_packages() {

  install_package_group \
    "core system tools" \
    "${SYSTEM_PACKAGES[@]}"

  install_package_group \
    "CachyOS Hyprland + Noctalia desktop" \
    "${NOCTALIA_DESKTOP_PACKAGES[@]}"

  install_package_group \
    "development tools" \
    "${DEVELOPMENT_PACKAGES[@]}"

  install_package_group \
    "research / LaTeX / Calibre tools" \
    "${RESEARCH_PACKAGES[@]}"

  install_package_group \
    "power-management tools" \
    "${POWER_PACKAGES[@]}"
}

# ============================================================
# PARU
# ============================================================

install_paru() {

  if command -v paru >/dev/null 2>&1; then
    info "paru already installed"
    return
  fi

  info "Installing paru"

  local build_dir
  build_dir="$HOME/.cache/cachyos-dotfiles/paru"

  mkdir -p "$(dirname "$build_dir")"

  if [[ -d "$build_dir/.git" ]]; then

    git -C "$build_dir" pull --ff-only

  else

    rm -rf "$build_dir"

    git clone \
      https://aur.archlinux.org/paru.git \
      "$build_dir"

  fi

  (
    cd "$build_dir"

    makepkg \
      -si \
      --needed \
      --noconfirm
  )

  command -v paru >/dev/null 2>&1 ||
    die "paru installation failed."
}

# ============================================================
# GIT / GITHUB / SSH
# ============================================================

configure_git_github() {

  info "Configuring Git, GitHub CLI and SSH"

  local git_name
  local git_email

  # --------------------------------------------------------
  # Git identity
  # --------------------------------------------------------

  git_name="$(
    git config --global --get user.name 2>/dev/null || true
  )"

  if [[ -z "$git_name" ]]; then

    echo
    read -r -p "Git name: " git_name

    [[ -n "$git_name" ]] ||
      die "Git user.name cannot be empty."

    git config --global user.name "$git_name"

  else
    info "Existing Git name retained: $git_name"
  fi

  git_email="$(
    git config --global --get user.email 2>/dev/null || true
  )"

  if [[ -z "$git_email" ]]; then

    echo
    read -r -p "Git email: " git_email

    [[ -n "$git_email" ]] ||
      die "Git user.email cannot be empty."

    git config --global user.email "$git_email"

  else
    info "Existing Git email retained: $git_email"
  fi

  # New repositories default to main.
  git config --global init.defaultBranch main

  # --------------------------------------------------------
  # SSH directory
  # --------------------------------------------------------

  local ssh_dir
  local private_key
  local public_key

  ssh_dir="$HOME/.ssh"
  private_key="$ssh_dir/id_ed25519"
  public_key="$private_key.pub"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # --------------------------------------------------------
  # SSH key
  # --------------------------------------------------------

  if [[ -f "$private_key" ]]; then

    info "Existing SSH private key retained:"
    echo "    $private_key"

    #
    # Recreate the public key if for some reason only the
    # private half exists.
    #

    if [[ ! -f "$public_key" ]]; then

      info "Recreating missing SSH public key"

      ssh-keygen \
        -y \
        -f "$private_key" \
        >"$public_key"

      chmod 644 "$public_key"
    fi

  else

    info "Creating new Ed25519 SSH key"

    echo
    echo "You may enter a passphrase for the SSH key."
    echo

    ssh-keygen \
      -t ed25519 \
      -C "$git_email" \
      -f "$private_key"

  fi

  chmod 600 "$private_key"
  chmod 644 "$public_key"

  # --------------------------------------------------------
  # GitHub authentication
  # --------------------------------------------------------

  if gh auth status \
    --hostname github.com \
    >/dev/null 2>&1; then

    info "GitHub CLI is already authenticated"

  else

    info "Authenticating GitHub CLI"

    echo
    echo "A browser will be opened for GitHub authentication."
    echo

    #
    # We manage the SSH key ourselves below, so tell gh
    # not to create/upload another key during login.
    #

    gh auth login \
      --hostname github.com \
      --git-protocol ssh \
      --web \
      --skip-ssh-key \
      --scopes admin:public_key
  fi

  # --------------------------------------------------------
  # Prefer SSH for GitHub
  # --------------------------------------------------------

  info "Setting GitHub Git protocol to SSH"

  gh config set \
    git_protocol ssh \
    --host github.com

  # --------------------------------------------------------
  # Ensure GitHub CLI has SSH-key permissions
  # --------------------------------------------------------

  local remote_keys

  if ! remote_keys="$(
    gh api \
      user/keys \
      --paginate \
      --jq '.[].key' \
      2>/dev/null
  )"; then

    info "Requesting GitHub SSH-key permissions"

    gh auth refresh \
      --hostname github.com \
      --scopes admin:public_key

    remote_keys="$(
      gh api \
        user/keys \
        --paginate \
        --jq '.[].key'
    )"
  fi

  # --------------------------------------------------------
  # Upload SSH key if GitHub doesn't already have it
  # --------------------------------------------------------

  local local_key
  local key_title

  #
  # Ignore the trailing comment/email because GitHub may
  # return only:
  #
  # ssh-ed25519 AAAA....
  #

  local_key="$(
    awk '
            NF >= 2 {
                print $1 " " $2
                exit
            }
        ' "$public_key"
  )"

  if grep -Fxq "$local_key" <<<"$remote_keys"; then

    info "SSH key already registered with GitHub"

  else

    key_title="$(hostname)-CachyOS"

    info "Adding SSH key to GitHub"

    gh ssh-key add \
      "$public_key" \
      --title "$key_title" \
      --type authentication

  fi

  # --------------------------------------------------------
  # Convert this setup repository to SSH if necessary
  # --------------------------------------------------------

  local origin
  local github_path

  origin="$(
    git -C "$REPO" \
      remote get-url origin \
      2>/dev/null ||
      true
  )"

  case "$origin" in

  https://github.com/*)

    github_path="${origin#https://github.com/}"

    info "Converting installer repository remote to SSH"

    git -C "$REPO" \
      remote set-url \
      origin \
      "git@github.com:${github_path}"

    ;;

  git@github.com:*)

    info "Installer repository already uses GitHub SSH"
    ;;

  "")

    warn "Installer repository has no Git origin"
    ;;

  *)

    info "Repository origin left unchanged:"
    echo "    $origin"
    ;;

  esac

  # --------------------------------------------------------
  # Summary
  # --------------------------------------------------------

  info "Git / GitHub configuration complete"

  echo
  echo "Git identity:"
  echo
  echo "    Name:  $(git config --global user.name)"
  echo "    Email: $(git config --global user.email)"
  echo
  echo "SSH key:"
  echo
  echo "    $public_key"
  echo
  echo "GitHub account:"
  echo

  gh api user \
    --jq '"    \(.login)"'
}

# ============================================================
# LAZYVIM
# ============================================================

install_lazyvim() {

  info "Checking Neovim / LazyVim configuration"

  local target
  local starter

  target="$HOME/.config/nvim"
  starter="$HOME/.cache/cachyos-dotfiles/lazyvim-starter"

  #
  # Don't overwrite an existing working configuration.
  #

  if [[ -e "$target/init.lua" ]]; then

    if rg -q \
      'LazyVim|lazy.nvim' \
      "$target/init.lua" \
      "$target/lua" \
      2>/dev/null; then
      info "Existing LazyVim/lazy.nvim configuration retained"
    else
      warn "Existing Neovim config retained at $target"
    fi

    return
  fi

  #
  # Back up a non-LazyVim config if one exists.
  #

  if [[ -e "$target" ]]; then

    local backup

    backup="$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"

    mv -- "$target" "$backup"

    info "Existing Neovim configuration backed up to:"
    echo "$backup"
  fi

  mkdir -p \
    "$(dirname "$starter")" \
    "$target"

  if [[ ! -d "$starter/.git" ]]; then

    git clone \
      --depth 1 \
      https://github.com/LazyVim/starter \
      "$starter"

  else

    git -C "$starter" pull --ff-only
  fi

  git -C "$starter" archive HEAD |
    tar -x -C "$target"

  info "LazyVim starter installed"

  echo "Run:"
  echo
  echo "    nvim"
  echo
  echo "Then:"
  echo
  echo "    :LazyHealth"
}

# ============================================================
# GPU DEVICE ALIASES
# ============================================================

install_gpu_aliases() {

  info "Configuring Legion AMD/NVIDIA DRM aliases"

  local amd_vendor
  local nvidia_vendor

  amd_vendor="/sys/bus/pci/devices/0000:05:00.0/vendor"
  nvidia_vendor="/sys/bus/pci/devices/0000:01:00.0/vendor"

  #
  # Protect against installing Legion-specific aliases on the
  # wrong machine.
  #

  if [[ ! -r "$amd_vendor" ]] ||
    [[ ! -r "$nvidia_vendor" ]] ||
    [[ $(<"$amd_vendor") != "0x1002" ]] ||
    [[ $(<"$nvidia_vendor") != "0x10de" ]]; then
    die "Expected AMD GPU at 05:00.0 and NVIDIA GPU at 01:00.0."
  fi

  local source
  local target

  source="$REPO/system/80-legion-drm-aliases.rules"
  target="/etc/udev/rules.d/80-legion-drm-aliases.rules"

  [[ -f "$source" ]] ||
    die "Missing GPU alias rules: $source"

  #
  # Only overwrite if the repository version changed.
  #

  if ! sudo test -e "$target" ||
    ! sudo cmp -s "$source" "$target"; then

    if sudo test -e "$target"; then

      local backup

      backup="$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"

      sudo cp -a \
        "$target" \
        "$backup"

      info "Backed up previous GPU rules to:"
      echo "$backup"
    fi

    sudo install \
      -m 0644 \
      "$source" \
      "$target"
  fi

  sudo udevadm control --reload-rules

  sudo udevadm trigger \
    --subsystem-match=drm \
    --action=add

  sudo udevadm settle

  #
  # These are used by AQ_DRM_DEVICES in the UWSM environment.
  #

  for device in \
    /dev/dri/amd-igpu \
    /dev/dri/nvidia-dgpu; do

    if [[ ! -e "$device" ]]; then
      die "GPU alias missing: $device. Reboot/load the GPU driver."
    fi

  done
}

# ============================================================
# LOCALE / KEYBOARD
# ============================================================

configure_locale() {

  info "Configuring Irish locale and keyboard"

  sudo localectl set-locale \
    LANG=en_IE.UTF-8

  sudo localectl set-keymap \
    uk

  sudo localectl set-x11-keymap \
    gb \
    pc105 \
    '' \
    terminate:ctrl_alt_bksp
}

# ============================================================
# POWER MANAGEMENT
# ============================================================

configure_power_management() {

  info "Configuring power management"

  sudo systemctl enable \
    --now \
    power-profiles-daemon

  #
  # HDA codec power saving.
  #

  local audio_conf
  audio_conf="/etc/modprobe.d/90-legion-audio-powersave.conf"

  if [[ ! -e "$audio_conf" ]]; then

    echo 'options snd_hda_intel power_save=1' |
      sudo tee "$audio_conf" >/dev/null

  fi
}

# ============================================================
# NOCTALIA / HYPRLAND BASE
# ============================================================

install_noctalia_base() {

  info "Preparing CachyOS Hyprland + Noctalia base"

  #
  # CachyOS supplies the initial Hyprland Lua entrypoint and
  # Noctalia configuration through /etc/skel.
  #
  # We retain this as the base desktop for now.
  #

  if [[ ! -f "$HOME/.config/hypr/hyprland.lua" &&
    ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then

    if [[ -d /etc/skel/.config/hypr ]]; then

      mkdir -p \
        "$HOME/.config/hypr"

      cp -a -n \
        /etc/skel/.config/hypr/. \
        "$HOME/.config/hypr/"

    fi
  fi

  if [[ ! -e "$HOME/.config/noctalia/config.toml" &&
    -f /etc/skel/.config/noctalia/config.toml ]]; then

    mkdir -p \
      "$HOME/.config/noctalia"

    cp -n \
      /etc/skel/.config/noctalia/config.toml \
      "$HOME/.config/noctalia/config.toml"

  fi
}

# ============================================================
# SAFE CONFIG INSTALLATION
# ============================================================

install_one() {

  local src="$1"
  local dest="$2"

  mkdir -p -- "$(dirname -- "$dest")"

  #
  # Nothing to do if identical.
  #

  if [[ -e "$dest" ]] &&
    cmp -s -- "$src" "$dest"; then
    return
  fi

  #
  # Preserve existing user configuration.
  #

  if [[ -e "$dest" || -L "$dest" ]]; then

    local backup

    backup="$dest.before-dotfiles-$(date +%Y%m%d-%H%M%S)"

    cp -a \
      -- "$dest" \
      "$backup"

    echo "Backup: $backup"
  fi

  install \
    -m 0644 \
    -- "$src" \
    "$dest"
}

# ============================================================
# HYPRLAND CONFIGURATION
# ============================================================

install_hyprland_config() {

  info "Installing custom Hyprland configuration overlay"

  local config_dir
  config_dir="$REPO/config/hypr/config"

  if [[ ! -d "$config_dir" ]]; then
    warn "No Hyprland config directory found at $config_dir"
    return
  fi

  shopt -s nullglob

  local configs=(
    "$config_dir"/*.lua
  )

  shopt -u nullglob

  if ((${#configs[@]} == 0)); then
    warn "No Hyprland Lua configuration files found"
    return
  fi

  local src

  for src in "${configs[@]}"; do

    install_one \
      "$src" \
      "$HOME/.config/hypr/config/${src##*/}"

  done
}

# ============================================================
# UWSM CONFIGURATION
# ============================================================

install_uwsm_config() {

  info "Installing UWSM environment configuration"

  local config_dir
  config_dir="$REPO/config/uwsm"

  if [[ ! -d "$config_dir" ]]; then
    warn "No UWSM config directory found at $config_dir"
    return
  fi

  shopt -s nullglob

  local configs=(
    "$config_dir"/*
  )

  shopt -u nullglob

  if ((${#configs[@]} == 0)); then
    warn "No UWSM configuration files found"
    return
  fi

  local src

  for src in "${configs[@]}"; do

    [[ -f "$src" ]] || continue

    install_one \
      "$src" \
      "$HOME/.config/uwsm/${src##*/}"

  done
}

# ============================================================
# HYPRLAND POWER PROFILE SCRIPT
# ============================================================

install_hypr_power_profile() {

  info "Installing Hyprland power-profile script"

  local source
  local target

  source="$REPO/scripts/hypr-power-profile"
  target="$HOME/.local/bin/hypr-power-profile"

  [[ -f "$source" ]] ||
    die "Missing $source"

  mkdir -p \
    "$HOME/.local/bin"

  if [[ -e "$target" ]] &&
    ! cmp -s "$source" "$target"; then

    local backup

    backup="$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"

    cp -a \
      "$target" \
      "$backup"

    echo "Backup: $backup"
  fi

  install \
    -m 0755 \
    "$source" \
    "$target"
}

# ============================================================
# LENOVO LEGION FAN SUPPORT
# ============================================================

install_legion_fans() {

  ((INSTALL_FANS)) || return

  info "Installing Lenovo Legion fan support"

  if ! command -v legion_cli >/dev/null 2>&1 ||
    ! find \
      /sys/class/hwmon \
      -maxdepth 2 \
      -name name \
      -exec grep -lqx legion_hwmon {} + \
      2>/dev/null |
    grep -q .; then

    paru -S \
      --needed \
      --noconfirm \
      -- \
      lenovolegionlinux-dkms-git \
      lenovolegionlinux-git
  fi

  #
  # The module may require a reboot after its first install.
  #

  if ! find \
    /sys/class/hwmon \
    -maxdepth 2 \
    -name name \
    -exec grep -lqx legion_hwmon {} + \
    2>/dev/null |
    grep -q .; then

    warn "legion_hwmon is not loaded yet."
    echo
    echo "Reboot, then run:"
    echo
    echo "    ./install.sh --fans"
    echo

    return
  fi

  local setup_script
  setup_script="$REPO/scripts/setup-legion-fans"

  [[ -f "$setup_script" ]] ||
    die "Missing Legion fan setup script: $setup_script"

  sudo bash "$setup_script"
}

# ============================================================
# PRIVATE INTERNET ACCESS
# ============================================================

install_pia() {

  info "Checking Private Internet Access"

  #
  # Avoid reinstalling PIA if already present.
  #

  if command -v piactl >/dev/null 2>&1 ||
    [[ -x /opt/piavpn/bin/piactl ]]; then

    info "Private Internet Access already installed"
    return
  fi

  echo
  echo "PIA uses its official Linux .run installer."
  echo
  echo "Download it from:"
  echo
  echo "    https://www.privateinternetaccess.com/download/linux-vpn"
  echo
  echo "The installer will automatically be detected in:"
  echo
  echo "    ~/Downloads"
  echo

  local downloads
  downloads="$HOME/Downloads"

  if [[ ! -d "$downloads" ]]; then
    warn "~/Downloads does not exist; skipping PIA installation"
    return
  fi

  local installer

  installer="$(
    find "$downloads" \
      -maxdepth 1 \
      -type f \
      -name 'pia-linux-*.run' \
      -printf '%T@ %p\n' \
      2>/dev/null |
      sort -nr |
      head -n1 |
      cut -d' ' -f2-
  )"

  if [[ -z "${installer:-}" ]]; then

    warn "No PIA Linux installer found in ~/Downloads"

    echo
    echo "Download the .run installer and simply run this"
    echo "setup script again."
    echo

    return
  fi

  info "Found PIA installer"

  echo "$installer"

  chmod +x "$installer"

  # Do NOT sudo this.
  # The PIA installer requests privilege escalation itself

  "$installer"
}

# ============================================================
# VALIDATION
# ============================================================

validate_installation() {

  info "Validating installation"

  echo

  for app in \
    git \
    gh \
    ssh \
    noctalia \
    uwsm \
    hyprctl \
    gdbus \
    paru \
    nvim \
    firefox \
    calibre \
    powerprofilesctl; do

    if gh auth status --hostname github.com >/dev/null 2>&1; then
      printf '  [OK]      GitHub authentication\n'
    else
      printf '  [CHECK]   GitHub authentication\n' >&2
    fi

    if [[ -f "$HOME/.ssh/id_ed25519" &&
      -f "$HOME/.ssh/id_ed25519.pub" ]]; then
      printf '  [OK]      GitHub SSH key\n'
    else
      printf '  [CHECK]   GitHub SSH key\n' >&2
    fi

    if command -v "$app" >/dev/null 2>&1; then
      printf '  [OK]      %s\n' "$app"
    else
      printf '  [MISSING] %s\n' "$app" >&2
    fi

  done

  echo

  for device in \
    /dev/dri/amd-igpu \
    /dev/dri/nvidia-dgpu \
    /dev/dri/by-path/pci-0000:05:00.0-render; do

    if [[ -e "$device" ]]; then
      printf '  [OK]      %s\n' "$device"
    else
      printf '  [CHECK]   %s\n' "$device" >&2
    fi

  done

  echo

  if [[ ! -e "$HOME/.config/hypr/hyprland.conf" &&
    ! -e "$HOME/.config/hypr/hyprland.lua" ]]; then

    warn "No Hyprland entrypoint found"

  fi

  #
  # Check that the stable GPU aliases are actually referenced
  # by our environment configuration.
  #

  if grep -Rqs \
    'AQ_DRM_DEVICES=.*/dev/dri/amd-igpu.*/dev/dri/nvidia-dgpu' \
    "$HOME/.config/uwsm" \
    2>/dev/null; then

    printf '  [OK]      AQ_DRM_DEVICES GPU ordering\n'

  else

    printf '  [CHECK]   AQ_DRM_DEVICES configuration\n' >&2

  fi
}

# ============================================================
# FINISH
# ============================================================

finish() {

  info "Installation complete"

  cat <<'EOF'

Recommended next steps:

    1. Reboot or log out and back in.

    2. Check Hyprland:

           hyprctl configerrors

    3. Check GPU ordering:

           echo "$AQ_DRM_DEVICES"

    4. Check power profile:

           powerprofilesctl get

    5. Start Neovim:

           nvim

       Then run:

           :LazyHealth

EOF

  if ((INSTALL_FANS)); then

    echo "Legion fan configuration was requested."

    echo

  fi
}

# ============================================================
# MAIN
# ============================================================

main() {

  parse_arguments "$@"

  preflight_checks

  # --------------------------------------------------------
  # Stage 1: CachyOS / software
  # --------------------------------------------------------

  update_system

  install_official_packages

  # --------------------------------------------------------
  # Stage 2: development / GitHub
  # --------------------------------------------------------

  configure_git_github

  install_paru

  install_lazyvim

  # --------------------------------------------------------
  # Stage 3: machine configuration
  # --------------------------------------------------------

  install_gpu_aliases

  configure_locale

  configure_power_management

  # --------------------------------------------------------
  # Stage 4: desktop
  #
  # CachyOS + Noctalia remains the base desktop.
  # Our Git repository is an overlay.
  # --------------------------------------------------------

  install_noctalia_base

  install_hyprland_config

  install_uwsm_config

  install_hypr_power_profile

  # --------------------------------------------------------
  # Stage 5: Legion-specific extras
  # --------------------------------------------------------

  install_legion_fans

  # --------------------------------------------------------
  # Stage 6: external applications
  # --------------------------------------------------------

  install_pia

  # --------------------------------------------------------
  # Stage 7: validation
  # --------------------------------------------------------

  validate_installation

  finish
}

main "$@"
