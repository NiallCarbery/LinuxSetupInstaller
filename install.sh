#!/usr/bin/env bash
# CachyOS Legion rebuild. Clone this repository, then run ./install.sh [--fans].
# Run as your desktop user. Re-running updates packages and repository-owned files.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_FANS=0
AMD_RENDER=/dev/dri/by-path/pci-0000:05:00.0-render

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./install.sh [--fans]
  --fans   Install LenovoLegionLinux and apply scripts/setup-legion-fans
  --help   Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --fans) INSTALL_FANS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $arg" ;;
    esac
done

require_file() { [[ -f "$1" ]] || die "Required repository file missing: $1"; }

preflight() {
    [[ $EUID -ne 0 ]] || die 'Run as your regular user, not root.'
    [[ -f /etc/arch-release ]] || die 'This script requires Arch Linux or CachyOS.'
    command -v sudo >/dev/null || die 'sudo is required.'
    command -v pacman >/dev/null || die 'pacman is required.'
    [[ -t 0 ]] || die 'Run from an interactive terminal for GitHub login and sudo.'
    require_file "$REPO/system/80-legion-drm-aliases.rules"
    require_file "$REPO/scripts/hypr-power-profile"
    require_file "$REPO/scripts/nvidia-power-mode"
    require_file "$REPO/scripts/firefox-amd"
    [[ -d "$REPO/config/hypr/config" ]] || die 'Missing config/hypr/config.'
    require_file "$REPO/config/uwsm/env-hyprland"
    if (( INSTALL_FANS )); then require_file "$REPO/scripts/setup-legion-fans"; fi
    grep -Fq 'nvidia-power-mode' "$REPO/scripts/hypr-power-profile" ||
        die 'Add the eco/performance nvidia-power-mode calls to scripts/hypr-power-profile first.'
    grep -Fq '/dev/dri/amd-igpu:/dev/dri/nvidia-dgpu' "$REPO/config/uwsm/env-hyprland" ||
        die 'config/uwsm/env-hyprland must set AQ_DRM_DEVICES with AMD first.'
    [[ -r /sys/bus/pci/devices/0000:05:00.0/vendor &&
       -r /sys/bus/pci/devices/0000:01:00.0/vendor ]] ||
        die 'Expected Legion GPU PCI addresses 05:00.0 and 01:00.0.'
    [[ $(</sys/bus/pci/devices/0000:05:00.0/vendor) == 0x1002 &&
       $(</sys/bus/pci/devices/0000:01:00.0/vendor) == 0x10de ]] ||
        die 'GPU PCI addresses do not match AMD iGPU and NVIDIA dGPU.'
    command -v nvidia-smi >/dev/null ||
        die 'Install the CachyOS NVIDIA driver before running this installer.'
    sudo -v
}

# Packages are grouped so each part can be changed independently.
SYSTEM_PACKAGES=(base-devel git github-cli openssh glib2)
DESKTOP_PACKAGES=(cachyos-hypr-noctalia kitty dolphin firefox
                  gnome-text-editor gnome-calculator btop hyprpicker qt6ct)
DEVELOPMENT_PACKAGES=(neovim ripgrep fd)
RESEARCH_PACKAGES=(texlive-basic texlive-latexrecommended texlive-latexextra
                   texlive-binextra zathura zathura-pdf-mupdf calibre)
GAMING_PACKAGES=(steam gamemode mangohud)
VIDEO_PACKAGES=(mesa libva-mesa-driver libva-utils desktop-file-utils)
POWER_PACKAGES=(power-profiles-daemon)

install_packages() {
    info 'Updating all system packages'
    sudo pacman -Syu
    local group
    for group in SYSTEM DESKTOP DEVELOPMENT RESEARCH GAMING VIDEO POWER; do
        local array="${group}_PACKAGES[@]"
        local items=("${!array}")
        info "Installing $group packages"
        sudo pacman -S --needed -- "${items[@]}"
    done
}

configure_git_github() {
    info 'Configuring Git, GitHub CLI and user SSH key'
    local git_name git_email ssh_dir private_key public_key remote_keys local_key
    git_name=$(git config --global --get user.name || true)
    git_email=$(git config --global --get user.email || true)
    if [[ -z $git_name ]]; then
        read -r -p 'Git name: ' git_name
        [[ -n $git_name ]] || die 'Git name cannot be empty.'
        git config --global user.name "$git_name"
    fi
    if [[ -z $git_email ]]; then
        read -r -p 'Git email: ' git_email
        [[ -n $git_email ]] || die 'Git email cannot be empty.'
        git config --global user.email "$git_email"
    fi
    git config --global init.defaultBranch main

    ssh_dir="$HOME/.ssh"
    private_key="$ssh_dir/id_ed25519"
    public_key="$private_key.pub"
    mkdir -p -- "$ssh_dir"
    chmod 700 "$ssh_dir"
    if [[ -f $private_key ]]; then
        if [[ ! -f $public_key ]]; then
            ssh-keygen -y -f "$private_key" > "$public_key"
        fi
    elif [[ -e $private_key || -e $public_key ]]; then
        die "Resolve the incomplete SSH key pair at $private_key before rerunning."
    else
        ssh-keygen -t ed25519 -C "$git_email" -f "$private_key"
    fi
    chmod 600 "$private_key"
    chmod 644 "$public_key"

    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        gh auth login --hostname github.com --git-protocol ssh \
            --web --skip-ssh-key --scopes admin:public_key
    fi
    gh config set git_protocol ssh --host github.com

    if ! remote_keys=$(gh api user/keys --paginate --jq '.[].key'); then
        gh auth refresh --hostname github.com --scopes admin:public_key
        remote_keys=$(gh api user/keys --paginate --jq '.[].key')
    fi
    local_key=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$public_key")
    [[ -n $local_key ]] || die "Invalid public key: $public_key"
    if ! grep -Fxq -- "$local_key" <<< "$remote_keys"; then
        if ! gh ssh-key add "$public_key" --title "$(hostname)-CachyOS" --type authentication; then
            gh auth refresh --hostname github.com --scopes admin:public_key
            gh ssh-key add "$public_key" --title "$(hostname)-CachyOS" --type authentication
        fi
    fi

    local origin github_path
    origin=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
    case "$origin" in
        https://github.com/*)
            github_path=${origin#https://github.com/}
            git -C "$REPO" remote set-url origin "git@github.com:$github_path"
            ;;
    esac
    info "GitHub authenticated as $(gh api user --jq .login); SSH key: $public_key"
}

install_paru() {
    command -v paru >/dev/null 2>&1 && return
    info 'Installing paru from its AUR source'
    local build_dir="$HOME/.cache/cachyos-dotfiles/paru"
    mkdir -p -- "$(dirname -- "$build_dir")"
    if [[ -d "$build_dir/.git" ]]; then
        git -C "$build_dir" pull --ff-only
    else
        [[ ! -e "$build_dir" ]] || die "Unexpected file at $build_dir"
        git clone https://aur.archlinux.org/paru.git "$build_dir"
    fi
    (cd "$build_dir" && makepkg -si --needed)
    command -v paru >/dev/null || die 'paru installation failed.'
}

install_lazyvim() {
    info 'Preparing LazyVim starter'
    local target="$HOME/.config/nvim"
    local starter="$HOME/.cache/cachyos-dotfiles/lazyvim-starter"
    if [[ -f "$target/init.lua" ]]; then
        info "Retaining existing Neovim configuration: $target"
        return
    fi
    if [[ -e $target ]]; then
        mv -- "$target" "$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p -- "$target" "$(dirname -- "$starter")"
    if [[ -d "$starter/.git" ]]; then
        git -C "$starter" pull --ff-only
    else
        [[ ! -e $starter ]] || die "Unexpected file at $starter"
        git clone --depth 1 https://github.com/LazyVim/starter "$starter"
    fi
    git -C "$starter" archive HEAD | tar -x -C "$target"
}

backup_if_changed() {
    local source=$1 target=$2
    if [[ -e $target || -L $target ]]; then
        cmp -s -- "$source" "$target" && return 1
        local backup="$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
        cp -a -- "$target" "$backup"
        info "Backed up $target to $backup"
    fi
    return 0
}

install_user_file() {
    local source=$1 target=$2 mode=${3:-0644}
    mkdir -p -- "$(dirname -- "$target")"
    if backup_if_changed "$source" "$target"; then
        install -m "$mode" -- "$source" "$target"
    else
        chmod "$mode" "$target"
    fi
}

install_gpu_aliases() {
    info 'Installing stable Legion DRM aliases'
    local source="$REPO/system/80-legion-drm-aliases.rules"
    local target=/etc/udev/rules.d/80-legion-drm-aliases.rules
    if ! sudo test -e "$target" || ! sudo cmp -s "$source" "$target"; then
        if sudo test -e "$target"; then
            sudo cp -a -- "$target" "$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
        fi
        sudo install -m 0644 "$source" "$target"
    fi
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=drm --action=add
    sudo udevadm settle
    for device in /dev/dri/amd-igpu /dev/dri/nvidia-dgpu "$AMD_RENDER"; do
        [[ -e $device ]] || die "GPU device missing after udev reload: $device"
    done
}

configure_machine() {
    info 'Setting Irish locale and UK/Irish keyboard mapping'
    sudo localectl set-locale LANG=en_IE.UTF-8
    sudo localectl set-keymap uk
    sudo localectl set-x11-keymap gb pc105 '' terminate:ctrl_alt_bksp
    info 'Enabling power-profiles-daemon'
    sudo systemctl enable --now power-profiles-daemon
    local audio_conf=/etc/modprobe.d/90-legion-audio-powersave.conf
    if ! sudo test -e "$audio_conf"; then
        printf '%s\n' 'options snd_hda_intel power_save=1' |
            sudo tee "$audio_conf" >/dev/null
    fi
}

install_nvidia_mode() {
    info 'Installing root-owned NVIDIA clock controller'
    local target=/usr/local/sbin/nvidia-power-mode
    local rule=/etc/sudoers.d/90-nvidia-power-mode
    local tmp
    if ! sudo test -e "$target" || ! sudo cmp -s "$REPO/scripts/nvidia-power-mode" "$target"; then
        if sudo test -e "$target"; then
            sudo cp -a "$target" "$target.before-dotfiles-$(date +%Y%m%d-%H%M%S)"
        fi
        sudo install -o root -g root -m 0755 "$REPO/scripts/nvidia-power-mode" "$target"
    fi
    tmp=$(sudo mktemp /etc/sudoers.d/.90-nvidia-power-mode.XXXXXX)
    printf '%s ALL=(root) NOPASSWD: %s eco, %s gaming, %s performance, %s status\n' \
        "$(id -un)" "$target" "$target" "$target" "$target" |
        sudo tee "$tmp" >/dev/null
    sudo chmod 0440 "$tmp"
    if sudo visudo -cf "$tmp" >/dev/null; then
        sudo mv -f -- "$tmp" "$rule"
    else
        sudo rm -f -- "$tmp"
        die 'NVIDIA sudoers validation failed.'
    fi
}

install_desktop_base() {
    info 'Preparing CachyOS Hyprland and Noctalia defaults'
    if [[ ! -f "$HOME/.config/hypr/hyprland.lua" &&
          ! -f "$HOME/.config/hypr/hyprland.conf" &&
          -d /etc/skel/.config/hypr ]]; then
        mkdir -p "$HOME/.config/hypr"
        cp -a -n /etc/skel/.config/hypr/. "$HOME/.config/hypr/"
    fi
    if [[ ! -e "$HOME/.config/noctalia/config.toml" &&
          -f /etc/skel/.config/noctalia/config.toml ]]; then
        mkdir -p "$HOME/.config/noctalia"
        cp -n /etc/skel/.config/noctalia/config.toml "$HOME/.config/noctalia/config.toml"
    fi
}

install_desktop_overlay() {
    info 'Installing Hyprland and UWSM configuration'
    local source
    local configs=("$REPO"/config/hypr/config/*.lua)
    ((${#configs[@]})) || die 'No Hyprland Lua files in config/hypr/config.'
    for source in "${configs[@]}"; do
        install_user_file "$source" "$HOME/.config/hypr/config/${source##*/}"
    done
    configs=("$REPO"/config/uwsm/*)
    for source in "${configs[@]}"; do
        [[ -f $source ]] || continue
        install_user_file "$source" "$HOME/.config/uwsm/${source##*/}"
    done
    install_user_file "$REPO/scripts/hypr-power-profile" \
        "$HOME/.local/bin/hypr-power-profile" 0755
}

install_firefox_amd() {
    info 'Setting Firefox VA-API decoding to the AMD render node'
    [[ -e $AMD_RENDER ]] || die "AMD render node missing: $AMD_RENDER"
    local wrapper="$HOME/.local/bin/firefox-amd"
    local system_desktop=/usr/share/applications/firefox.desktop
    local local_desktop="$HOME/.local/share/applications/firefox.desktop"
    require_file "$system_desktop"
    install_user_file "$REPO/scripts/firefox-amd" "$wrapper" 0755

    # User desktop entry overrides the package entry, including desktop actions.
    local temp_desktop
    temp_desktop=$(mktemp)
    sed -E \
        "s#^Exec=(/usr/bin/firefox|/usr/lib/firefox/firefox|firefox)([[:space:]].*)?\$#Exec=$wrapper\\2#" \
        "$system_desktop" > "$temp_desktop"
    if ! grep -Fq "Exec=$wrapper" "$temp_desktop"; then
        rm -f -- "$temp_desktop"
        die 'Firefox desktop entry has an unexpected Exec format.'
    fi
    install_user_file "$temp_desktop" "$local_desktop"
    rm -f -- "$temp_desktop"
    update-desktop-database "$HOME/.local/share/applications"
}

install_legion_fans() {
    (( INSTALL_FANS )) || return 0
    info 'Installing LenovoLegionLinux and fan profiles'
    if ! command -v legion_cli >/dev/null 2>&1; then
        paru -S --needed -- lenovolegionlinux-dkms-git lenovolegionlinux-git
    fi
    if ! find /sys/class/hwmon -maxdepth 2 -name name \
        -exec grep -lqx legion_hwmon {} + 2>/dev/null | grep -q .; then
        warn 'legion_hwmon is not loaded. Reboot and rerun ./install.sh --fans.'
        return 0
    fi
    sudo bash "$REPO/scripts/setup-legion-fans"
}

install_pia() {
    info 'Checking official Private Internet Access installer'
    if command -v piactl >/dev/null 2>&1 || [[ -x /opt/piavpn/bin/piactl ]]; then
        return 0
    fi
    local downloads="$HOME/Downloads" installer=''
    if [[ -d $downloads ]]; then
        installer=$(find "$downloads" -maxdepth 1 -type f -name 'pia-linux-*.run' \
            -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')
    fi
    if [[ -z $installer ]]; then
        warn 'PIA installer absent. Download the official Linux .run from https://www.privateinternetaccess.com/download/linux-vpn into ~/Downloads and rerun.'
        return 0
    fi
    printf 'Run official PIA installer: %s\n' "$installer"
    bash "$installer"  # Its installer requests privilege escalation as needed.
}

validate() {
    info 'Checking installed commands and devices'
    local app device
    for app in git gh ssh paru nvim firefox calibre noctalia uwsm hyprctl \
               powerprofilesctl vainfo nvidia-smi; do
        if command -v "$app" >/dev/null 2>&1; then
            printf '[OK] %s\n' "$app"
        else
            warn "Missing command: $app"
        fi
    done
    for device in /dev/dri/amd-igpu /dev/dri/nvidia-dgpu "$AMD_RENDER"; do
        [[ -e $device ]] && printf '[OK] %s\n' "$device" || warn "Missing: $device"
    done
    if LIBVA_DRIVER_NAME=radeonsi vainfo --display drm --device "$AMD_RENDER" \
        >/dev/null 2>&1; then
        printf '[OK] AMD VA-API\n'
    else
        warn 'AMD VA-API failed; inspect vainfo output.'
    fi
    [[ -x /usr/local/sbin/nvidia-power-mode ]] || warn 'NVIDIA power helper missing.'
    [[ -x "$HOME/.local/bin/firefox-amd" ]] || warn 'Firefox AMD launcher missing.'
    [[ -f "$HOME/.config/hypr/hyprland.conf" ||
       -f "$HOME/.config/hypr/hyprland.lua" ]] || warn 'Hyprland entrypoint missing.'
    if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        hyprctl configerrors || true
    fi
}

main() {
    preflight
    install_packages
    configure_git_github
    install_paru
    install_lazyvim
    install_gpu_aliases
    configure_machine
    install_nvidia_mode
    install_desktop_base
    install_desktop_overlay
    install_firefox_amd
    install_legion_fans
    install_pia
    validate
    info 'Done. Log out or reboot, then check hyprctl configerrors and powerprofilesctl get.'
    printf '%s\n' 'Restart Firefox completely for the new decoding environment.'
}

shopt -s nullglob
main
