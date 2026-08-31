#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
profile="workstation"
stage=""
stage_set=false
check=false
profile_set=false
lifecycle_action=""
lifecycle_path=""

usage() {
  cat <<'EOF'
Usage: bootstrap/windows.sh [PROFILE] [--stage lan|remote] [--check]
       bootstrap/windows.sh game-stream-{host|client} --prepare OUTPUT
       bootstrap/windows.sh game-stream-{host|client} --enroll RESPONSE
       bootstrap/windows.sh game-stream-{host|client} --reset-enrollment

Apply or check a declarative Windows profile from WSL. Windows PowerShell and
WinGet still run natively on Windows; Git and the repository remain in WSL.

Profiles default to workstation. Both game-stream profiles default to their LAN
stage so Sunshine and Moonlight can be proven locally before WireGuard enrollment.
Prepare, enroll, and reset are WSL-first wrappers around the elevated native
Windows lifecycle; private keys never leave Windows and Windows Git is not used.

Examples:
  ./bootstrap/windows.sh workstation
  ./bootstrap/windows.sh game-stream-host
  ./bootstrap/windows.sh game-stream-host --check
  ./bootstrap/windows.sh game-stream-client
  ./bootstrap/windows.sh game-stream-host --prepare /tmp/host.game-stream-request.json
  ./bootstrap/windows.sh game-stream-host --enroll /tmp/host.game-stream-enrollment.json
  ./bootstrap/windows.sh game-stream-host --stage remote
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
    --stage)
      (($# >= 2)) || die '--stage requires lan or remote.'
      stage=$2
      stage_set=true
      shift 2
      ;;
    --prepare)
      (($# >= 2)) || die '--prepare requires an output path.'
      [[ -z "${lifecycle_action}" ]] || die 'Choose only one enrollment lifecycle action.'
      lifecycle_action=prepare
      lifecycle_path=$2
      shift 2
      ;;
    --enroll)
      (($# >= 2)) || die '--enroll requires a response path.'
      [[ -z "${lifecycle_action}" ]] || die 'Choose only one enrollment lifecycle action.'
      lifecycle_action=enroll
      lifecycle_path=$2
      shift 2
      ;;
    --reset-enrollment)
      [[ -z "${lifecycle_action}" ]] || die 'Choose only one enrollment lifecycle action.'
      lifecycle_action=reset
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
[[ -f "${repo_root}/windows/profiles/${profile}.json" ]] ||
  die "Unknown Windows profile: ${profile}"

game_stream_role=false
case "${profile}" in
  game-stream-host)
    game_stream_role=true
    stage=${stage:-lan}
    ;;
  game-stream-client)
    game_stream_role=true
    stage=${stage:-lan}
    ;;
  *)
    [[ -z "${stage}" ]] || die '--stage is accepted only by a game-stream profile.'
    ;;
esac

if [[ "${game_stream_role}" == true ]]; then
  [[ "${stage}" == lan || "${stage}" == remote ]] || die '--stage requires lan or remote.'
fi

if [[ -n "${lifecycle_action}" ]]; then
  [[ "${game_stream_role}" == true ]] ||
    die 'Enrollment lifecycle actions require game-stream-host or game-stream-client.'
  [[ "${check}" == false ]] || die '--check cannot be combined with an enrollment lifecycle action.'
  [[ "${stage_set}" == false ]] ||
    die '--stage cannot be combined with an enrollment lifecycle action.'
  command -v realpath >/dev/null 2>&1 || die 'realpath is unavailable.'

  role=${profile#game-stream-}
  role=${role^}
  lifecycle_script="$(wslpath -w "${repo_root}/bootstrap/windows-game-stream-lifecycle.ps1")"
  arguments=(
    powershell.exe
    -NoLogo
    -NoProfile
    -NonInteractive
    -ExecutionPolicy Bypass
    -File "${lifecycle_script}"
    -Role "${role}"
  )

  case "${lifecycle_action}" in
    prepare)
      lifecycle_path="$(realpath -m -- "${lifecycle_path}")"
      case "${lifecycle_path}" in
        "${repo_root}" | "${repo_root}"/*)
          die 'Keep enrollment request and response files outside the repository.'
          ;;
      esac
      mkdir -p -- "$(dirname -- "${lifecycle_path}")"
      arguments+=(-Prepare -Output "$(wslpath -w "${lifecycle_path}")")
      ;;
    enroll)
      [[ -f "${lifecycle_path}" ]] || die "Enrollment response is unavailable: ${lifecycle_path}"
      lifecycle_path="$(realpath -- "${lifecycle_path}")"
      case "${lifecycle_path}" in
        "${repo_root}" | "${repo_root}"/*)
          die 'Keep enrollment request and response files outside the repository.'
          ;;
      esac
      command -v git >/dev/null 2>&1 || die 'Linux Git is required for game-stream source identity.'
      source_commit="$(git -C "${repo_root}" rev-parse --verify 'HEAD^{commit}')"
      [[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || die 'Could not derive the reviewed Git commit in WSL.'
      arguments+=(
        -Enroll "$(wslpath -w "${lifecycle_path}")"
        -SourceCommit "${source_commit}"
      )
      ;;
    reset)
      arguments+=(-ResetEnrollment)
      ;;
  esac

  printf '==> Running %s lifecycle for Windows profile %s\n' "${lifecycle_action}" "${profile}"
  "${arguments[@]}"
  exit
fi

windows_bootstrap="$(wslpath -w "${repo_root}/bootstrap/windows.ps1")"
arguments=(
  powershell.exe
  -NoLogo
  -NoProfile
  -NonInteractive
  -ExecutionPolicy Bypass
  -File "${windows_bootstrap}"
  -Profile "${profile}"
)

if [[ "${check}" == true ]]; then
  arguments+=(-Check)
fi
if [[ "${game_stream_role}" == true ]]; then
  arguments+=(-GameStreamStage "${stage^}")
  if [[ "${check}" == false ]]; then
    command -v git >/dev/null 2>&1 || die 'Linux Git is required for game-stream source identity.'
    source_commit="$(git -C "${repo_root}" rev-parse --verify 'HEAD^{commit}')"
    [[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || die 'Could not derive the reviewed Git commit in WSL.'
    arguments+=(-SourceCommit "${source_commit}")
  fi
fi

action=Applying
if [[ "${check}" == true ]]; then
  action=Checking
fi
printf '==> %s Windows profile %s' "${action}" "${profile}"
if [[ "${game_stream_role}" == true ]]; then
  printf ' (%s stage)' "${stage}"
fi
printf '\n'

"${arguments[@]}"
