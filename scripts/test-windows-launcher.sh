#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
capture="${test_root}/powershell-arguments"

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"

cat >"${fake_bin}/wslpath" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -w && -n "${2:-}" ]]
printf '%s\n' '\\wsl.localhost\TestDistro\repo\bootstrap\windows.ps1'
EOF

cat >"${fake_bin}/powershell.exe" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\0' "$@" >"${WINDOWS_LAUNCHER_CAPTURE:?}"
EOF

chmod +x "${fake_bin}/powershell.exe" "${fake_bin}/wslpath"

run_launcher() {
  WINDOWS_LAUNCHER_CAPTURE="${capture}" \
    WSL_INTEROP=/run/WSL/test \
    PATH="${fake_bin}:${PATH}" \
    "${repo_root}/bootstrap/windows.sh" "$@" >/dev/null
  mapfile -d '' launcher_arguments <"${capture}"
}

require_pair() {
  local expected_name=$1
  local expected_value=$2
  local index

  for ((index = 0; index < ${#launcher_arguments[@]} - 1; index++)); do
    if [[ "${launcher_arguments[index]}" == "${expected_name}" ]]; then
      [[ "${launcher_arguments[index + 1]}" == "${expected_value}" ]] || {
        echo "${expected_name} had unexpected value: ${launcher_arguments[index + 1]}" >&2
        exit 1
      }
      return 0
    fi
  done
  echo "Missing launcher argument: ${expected_name}" >&2
  exit 1
}

reject_argument() {
  local rejected=$1
  local argument

  for argument in "${launcher_arguments[@]}"; do
    [[ "${argument}" != "${rejected}" ]] || {
      echo "Unexpected launcher argument: ${rejected}" >&2
      exit 1
    }
  done
}

source_commit="$(git -C "${repo_root}" rev-parse --verify 'HEAD^{commit}')"

run_launcher game-stream-host
require_pair -Profile game-stream-host
require_pair -GameStreamStage Lan
require_pair -SourceCommit "${source_commit}"
reject_argument -Check

run_launcher game-stream-host --check
require_pair -Profile game-stream-host
require_pair -GameStreamStage Lan
reject_argument -SourceCommit

run_launcher game-stream-client
require_pair -Profile game-stream-client
require_pair -GameStreamStage Lan
require_pair -SourceCommit "${source_commit}"
reject_argument -Check

run_launcher game-stream-client --stage remote --check
require_pair -Profile game-stream-client
require_pair -GameStreamStage Remote
reject_argument -SourceCommit

run_launcher workstation
require_pair -Profile workstation
reject_argument -GameStreamStage
reject_argument -SourceCommit

echo 'Validated WSL-to-Windows launcher argument routing.'
