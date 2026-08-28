#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO_HTTPS_URL="https://github.com/joshcazalas/caz.nix.git"
readonly REPO_SSH_URL="git@github.com:joshcazalas/caz.nix.git"
readonly EXPECTED_USER="joshcaz"
readonly HOME_PROFILE="joshcaz@wsl"
readonly DEFAULT_REPO_DIR="$HOME/develop/caz.nix"
readonly GITHUB_KEYS_URL="https://github.com/settings/ssh/new"
readonly GITHUB_FINGERPRINTS_URL="https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints"
readonly NIX_INSTALL_URL="https://nixos.org/nix/install"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR=""
SKIP_DOCKER=false
USE_SSH_CLONE=false
NIX_INSTALLER=""
DOCKER_GROUP_CHANGED=false

cleanup() {
  if [[ -n "$NIX_INSTALLER" && -f "$NIX_INSTALLER" ]]; then
    rm -f -- "$NIX_INSTALLER"
  fi
}

on_error() {
  local exit_code=$1
  local line_number=$2
  local command=$3

  trap - ERR
  printf '\nBootstrap stopped at line %s (exit %s) while running:\n  %s\nFix the reported problem and rerun; completed steps are safe to repeat.\n' \
    "$line_number" "$exit_code" "$command" >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

say() {
  printf '\n==> %s\n' "$*"
}

note() {
  printf '    %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt=$1
  local default=${2:-yes}
  local answer

  [[ -t 0 ]] || die "This bootstrap is interactive and requires a terminal."

  if [[ "$default" == "yes" ]]; then
    read -r -p "$prompt [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Bootstrap an Ubuntu WSL2 development environment from caz.nix.

Options:
  --repo-dir PATH  Use or clone the repository at PATH.
                   Default: $DEFAULT_REPO_DIR
  --skip-docker    Do not install or configure Docker Engine.
  --ssh-clone      Use authenticated SSH instead of public HTTPS when cloning.
  -h, --help       Show this help.

The script is idempotent: rerunning it skips completed installation steps and
reapplies the pinned Home Manager configuration.
EOF
}

while (($# > 0)); do
  case "$1" in
    --repo-dir)
      (($# >= 2)) || die "--repo-dir requires a path."
      REPO_DIR=$2
      shift 2
      ;;
    --skip-docker)
      SKIP_DOCKER=true
      shift
      ;;
    --ssh-clone)
      USE_SSH_CLONE=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

check_platform() {
  local os_release
  os_release="$(uname -r)"

  [[ "$os_release" == *icrosoft* || -n "${WSL_INTEROP:-}" ]] ||
    die "This script only supports Ubuntu under WSL2."
  [[ "$(uname -m)" == "x86_64" ]] ||
    die "The current flake supports x86_64 WSL installations only."
  [[ -r /etc/os-release ]] || die "Cannot identify the Linux distribution."

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] ||
    die "This bootstrap supports Ubuntu; detected ${ID:-unknown}."
  [[ "$USER" == "$EXPECTED_USER" ]] ||
    die "The Home Manager profile expects WSL user '$EXPECTED_USER', but this session is '$USER'. See bootstrap/README.md."
}

ensure_systemd() {
  local init_name
  init_name="$(ps -p 1 -o comm= | tr -d '[:space:]')"
  if [[ "$init_name" == "systemd" ]]; then
    return 0
  fi

  say "WSL systemd setup is required"
  note "Nix's multi-user daemon and Docker Engine both use systemd."

  if [[ -f /etc/wsl.conf ]] && grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf; then
    note "/etc/wsl.conf already enables systemd."
  elif [[ -f /etc/wsl.conf ]] && grep -Eq '^[[:space:]]*\[boot\][[:space:]]*$' /etc/wsl.conf; then
    warn "/etc/wsl.conf already has a [boot] section, so it will not be edited automatically."
    cat <<'EOF'

Add this setting beneath the existing [boot] heading:

  systemd=true
EOF
  elif confirm "Add systemd=true to /etc/wsl.conf now?"; then
    local wsl_conf_tmp
    wsl_conf_tmp="$(mktemp)"
    if [[ -f /etc/wsl.conf ]]; then
      cp -- /etc/wsl.conf "$wsl_conf_tmp"
      printf '\n[boot]\nsystemd=true\n' >>"$wsl_conf_tmp"
    else
      printf '[boot]\nsystemd=true\n' >"$wsl_conf_tmp"
    fi
    sudo install -m 0644 "$wsl_conf_tmp" /etc/wsl.conf
    rm -f -- "$wsl_conf_tmp"
    note "Updated /etc/wsl.conf."
  else
    die "systemd must be enabled before continuing."
  fi

  cat <<'EOF'

From PowerShell, run:

  wsl.exe --shutdown

Then reopen Ubuntu and rerun this script. No completed work will be lost.
EOF
  exit 2
}

install_prerequisites() {
  local -a packages=()

  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v ssh >/dev/null 2>&1 || packages+=(openssh-client)
  command -v xz >/dev/null 2>&1 || packages+=(xz-utils)
  dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed' ||
    packages+=(ca-certificates)

  ((${#packages[@]} > 0)) || return 0

  say "Ubuntu prerequisites"
  note "Missing apt packages: ${packages[*]}"
  confirm "Install these packages with apt?" || die "Required packages were not installed."
  sudo apt-get update
  sudo apt-get install -y "${packages[@]}"
}

select_repo_dir() {
  if [[ -n "$REPO_DIR" ]]; then
    REPO_DIR="$(realpath -m -- "$REPO_DIR")"
  elif [[ -f "$SCRIPT_REPO_DIR/flake.nix" && -d "$SCRIPT_REPO_DIR/.git" ]]; then
    REPO_DIR=$SCRIPT_REPO_DIR
  else
    REPO_DIR=$DEFAULT_REPO_DIR
  fi
}

find_public_key() {
  local key
  local -a public_keys=()

  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    printf '%s\n' "$HOME/.ssh/id_ed25519.pub"
    return 0
  fi

  shopt -s nullglob
  public_keys=("$HOME/.ssh"/*.pub)
  shopt -u nullglob
  for key in "${public_keys[@]}"; do
    if grep -q '^ssh-ed25519 ' "$key"; then
      printf '%s\n' "$key"
      return 0
    fi
  done

  return 1
}

create_ssh_key() {
  local key_path="$HOME/.ssh/id_ed25519"

  install -d -m 0700 "$HOME/.ssh"
  if [[ -f "$key_path" && ! -f "$key_path.pub" ]]; then
    say "Recovering the public half of the existing SSH key"
    ssh-keygen -y -f "$key_path" >"$key_path.pub"
    chmod 0644 "$key_path.pub"
  elif [[ ! -e "$key_path" ]]; then
    say "Creating an Ed25519 SSH key"
    note "ssh-keygen will ask for an optional passphrase; using one protects the key if the file is copied."
    ssh-keygen -t ed25519 -a 100 -C "${USER}@$(hostname)" -f "$key_path"
  else
    die "$key_path exists but its public key could not be prepared safely."
  fi

  printf '%s\n' "$key_path.pub"
}

open_github_keys_page() {
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process '$GITHUB_KEYS_URL'" >/dev/null 2>&1 || true
  fi
}

ensure_github_ssh_access() {
  local public_key
  local attempt

  say "Checking GitHub SSH access"
  if [[ -d "$REPO_DIR/.git" ]]; then
    note "An existing checkout is available; skipping the clone authentication check."
    return 0
  fi
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    note "If SSH asks to trust GitHub, compare the fingerprint with:"
    note "$GITHUB_FINGERPRINTS_URL"
  fi
  if git ls-remote "$REPO_SSH_URL" HEAD >/dev/null; then
    note "GitHub accepted the existing SSH identity."
    return 0
  fi

  public_key="$(find_public_key || true)"
  if [[ -z "$public_key" ]]; then
    confirm "No Ed25519 public key was found. Generate one now?" ||
      die "An SSH key is required because --ssh-clone was selected."
    public_key="$(create_ssh_key)"
  fi

  say "Add this SSH public key to GitHub"
  cat "$public_key"
  if command -v clip.exe >/dev/null 2>&1; then
    clip.exe <"$public_key"
    note "The public key was copied to the Windows clipboard."
  fi
  note "Opening: $GITHUB_KEYS_URL"
  note "GitHub host-key fingerprints: $GITHUB_FINGERPRINTS_URL"
  open_github_keys_page

  cat <<EOF

In GitHub:
  1. Give the key a descriptive title such as "$(hostname)-WSL".
  2. Keep the key type set to Authentication Key.
  3. Paste the copied public key and select Add SSH key.
EOF
  read -r -p "Press Enter after GitHub has saved the key... "

  for attempt in 1 2 3; do
    if git ls-remote "$REPO_SSH_URL" HEAD >/dev/null; then
      note "GitHub SSH authentication succeeded."
      return 0
    fi
    ((attempt == 3)) && break
    warn "GitHub still rejected the key. Check the uploaded key and try again."
    read -r -p "Press Enter to retry... "
  done

  die "Could not authenticate to $REPO_SSH_URL over SSH."
}

ensure_repository() {
  local clone_url=$REPO_HTTPS_URL
  local remote_url

  if [[ "$USE_SSH_CLONE" == true ]]; then
    clone_url=$REPO_SSH_URL
  fi

  if [[ -e "$REPO_DIR" ]]; then
    [[ -d "$REPO_DIR/.git" && -f "$REPO_DIR/flake.nix" ]] ||
      die "$REPO_DIR already exists but is not a caz.nix checkout. It was left untouched."
    remote_url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
    [[ "$remote_url" == "$REPO_HTTPS_URL" || "$remote_url" == "$REPO_SSH_URL" ]] ||
      warn "The existing checkout uses an unexpected origin: '$remote_url'."
    note "Using existing checkout: $REPO_DIR"
    return 0
  fi

  say "Cloning caz.nix"
  mkdir -p -- "$(dirname -- "$REPO_DIR")"
  git clone "$clone_url" "$REPO_DIR"
}

configure_repository_hooks() {
  say "Configure repository Git hooks"
  git -C "$REPO_DIR" config core.hooksPath .githooks
  note "Commits in this checkout will scan staged changes with Gitleaks."
}

load_nix_environment() {
  local profile_script

  for profile_script in \
    "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" \
    "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    if [[ -r "$profile_script" ]]; then
      set +u
      # shellcheck disable=SC1090
      source "$profile_script"
      set -u
      break
    fi
  done
}

install_nix() {
  load_nix_environment
  if command -v nix >/dev/null 2>&1; then
    note "Nix is already installed: $(nix --version)"
    return 0
  fi

  say "Install the Nix package manager"
  cat <<EOF
The official installer will create /nix, build users, and the nix-daemon
system service. It invokes sudo and may ask for your Ubuntu password.

Installer source: $NIX_INSTALL_URL
Documentation:    https://nix.dev/manual/nix/stable/installation/installing-binary.html
EOF
  confirm "Download and run the official multi-user Nix installer?" ||
    die "Nix is required to activate Home Manager."

  NIX_INSTALLER="$(mktemp)"
  curl --proto '=https' --tlsv1.2 --fail --show-error --location \
    "$NIX_INSTALL_URL" --output "$NIX_INSTALLER"
  bash "$NIX_INSTALLER" --daemon
  load_nix_environment
  command -v nix >/dev/null 2>&1 ||
    die "Nix installed, but this shell cannot find it. Open a new Ubuntu shell and rerun the bootstrap."
  sudo systemctl start nix-daemon
  note "Installed $(nix --version)."
}

install_docker() {
  local docker_arch
  local docker_codename
  local docker_key_tmp
  local docker_source_tmp

  if [[ "$SKIP_DOCKER" == true ]]; then
    note "Docker installation skipped by request."
    return 0
  fi

  if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed' \
    && systemctl is-enabled --quiet docker \
    && systemctl is-active --quiet docker \
    && id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    note "Docker Engine is already installed, enabled, running, and available to $USER."
    return 0
  fi

  if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    note "Docker Engine is already installed."
  else
    say "Docker Engine inside Ubuntu"
    note "This uses Docker's official Ubuntu apt repository, not Docker Desktop."
    confirm "Install Docker Engine, Buildx, and the Compose plugin?" || {
      note "Docker installation skipped. Rerun without --skip-docker when ready."
      return 0
    }

    # shellcheck disable=SC1091
    source /etc/os-release
    docker_codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    docker_arch="$(dpkg --print-architecture)"
    docker_key_tmp="$(mktemp)"
    docker_source_tmp="$(mktemp)"

    curl --proto '=https' --tlsv1.2 --fail --show-error --location \
      https://download.docker.com/linux/ubuntu/gpg --output "$docker_key_tmp"
    cat >"$docker_source_tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $docker_codename
Components: stable
Architectures: $docker_arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo install -m 0644 "$docker_key_tmp" /etc/apt/keyrings/docker.asc
    sudo install -m 0644 "$docker_source_tmp" /etc/apt/sources.list.d/docker.sources
    rm -f -- "$docker_key_tmp" "$docker_source_tmp"

    sudo apt-get update
    sudo apt-get install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  fi

  sudo systemctl enable --now docker
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    DOCKER_GROUP_CHANGED=true
  fi
  sudo docker version >/dev/null
  note "Docker daemon is running."
}

activate_home_manager() {
  local flake_ref="$REPO_DIR#$HOME_PROFILE"
  local backup_extension

  say "Validate caz.nix"
  if [[ -n "${NIX_CONFIG:-}" ]]; then
    export NIX_CONFIG="$NIX_CONFIG"$'\nexperimental-features = nix-command flakes'
  else
    export NIX_CONFIG="experimental-features = nix-command flakes"
  fi

  nix flake check --no-build "$REPO_DIR"

  say "Activate Home Manager profile $HOME_PROFILE"
  backup_extension="pre-caz-nix-$(date +%Y%m%d-%H%M%S)"
  note "Unmanaged dotfiles that conflict will be preserved with .$backup_extension appended."
  nix run "$REPO_DIR#home-manager" -- switch -b "$backup_extension" --flake "$flake_ref"
  note "Home Manager activation completed."
}

print_summary() {
  cat <<EOF

Bootstrap complete.

Repository:   $REPO_DIR
Home profile: $HOME_PROFILE
Prompt:       Gruvbox Rainbow with MesloLGL Nerd Font

Open a fresh Ubuntu terminal to load the new Bash environment. Useful first
checks in that new terminal:

  atuin doctor
  fzf --version
  starship --version
  z foo
  home-manager generations

Shell controls:
  Up Arrow  directory-scoped Atuin history
  Ctrl-R    global Atuin history
  Right     accept a ble.sh ghost suggestion
  Ctrl-T    fuzzy file picker
  Alt-C     fuzzy directory picker
EOF

  if [[ "$DOCKER_GROUP_CHANGED" == true ]]; then
    cat <<'EOF'

Docker group membership changed. Run `wsl.exe --shutdown` from PowerShell and
reopen Ubuntu before using Docker without sudo. Then verify with:

  docker run --rm hello-world
  docker compose version
EOF
  fi
}

main() {
  say "caz.nix WSL bootstrap"
  check_platform
  ensure_systemd
  install_prerequisites
  select_repo_dir
  if [[ "$USE_SSH_CLONE" == true ]]; then
    ensure_github_ssh_access
  fi
  ensure_repository
  configure_repository_hooks
  install_nix
  install_docker
  activate_home_manager
  print_summary
}

main
