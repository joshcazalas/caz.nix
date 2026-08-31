#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
profile="workstation"
profile_set=false
check=false

usage() {
  cat <<'EOF'
Usage: bootstrap/windows.sh [PROFILE] [--check]

Apply or check Windows configuration from WSL. Windows PowerShell and WinGet
run natively on Windows; Git, SSH keys, and the repository remain in WSL.

The game-stream-host and game-stream-client roles use one focused native
PowerShell entry point instead of WinGet Configuration or DSC.

Examples:
  ./bootstrap/windows.sh workstation
  ./bootstrap/windows.sh workstation --check
  ./bootstrap/windows.sh game-stream-host
  ./bootstrap/windows.sh game-stream-host --check
  ./bootstrap/windows.sh game-stream-client
  ./bootstrap/windows.sh game-stream-client --check
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --check)
      check=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [[ "${profile_set}" == false ]] || die 'Specify only one Windows profile.'
      profile=$1
      profile_set=true
      shift
      ;;
  esac
done

[[ -n "${WSL_INTEROP:-}" || "$(uname -r)" == *icrosoft* ]] ||
  die 'This entry point must run inside WSL.'
command -v powershell.exe >/dev/null 2>&1 ||
  die 'Windows PowerShell interoperability is unavailable in this WSL environment.'
command -v wslpath >/dev/null 2>&1 || die 'wslpath is unavailable.'
[[ "${profile}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid Windows profile: ${profile}"

case "${profile}" in
  game-stream-host | game-stream-client)
    role=${profile#game-stream-}
    role=${role^}
    windows_script="$(wslpath -w "${repo_root}/bootstrap/windows-game-stream.ps1")"
    arguments=(
      powershell.exe
      -NoLogo
      -NoProfile
      -NonInteractive
      -ExecutionPolicy Bypass
      -File "${windows_script}"
      -Role "${role}"
    )
    ;;
  *)
    [[ -f "${repo_root}/windows/profiles/${profile}.json" ]] ||
      die "Unknown Windows profile: ${profile}"
    windows_script="$(wslpath -w "${repo_root}/bootstrap/windows.ps1")"
    arguments=(
      powershell.exe
      -NoLogo
      -NoProfile
      -NonInteractive
      -ExecutionPolicy Bypass
      -File "${windows_script}"
      -Profile "${profile}"
    )
    ;;
esac

if [[ "${check}" == true ]]; then
  arguments+=(-Check)
fi

action=Applying
if [[ "${check}" == true ]]; then
  action=Checking
fi
printf '==> %s Windows profile %s\n' "${action}" "${profile}"
"${arguments[@]}"
