#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  echo "usage: $0 [--all]" >&2
}

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--all" ) ]]; then
  usage
  exit 2
fi

homeserver=false
wsl=false
integration=false
windows=false
changed_paths=0

mark_all() {
  homeserver=true
  wsl=true
  integration=true
  windows=true
}

if [[ ${1:-} == "--all" ]]; then
  mark_all
else
  # Read NUL-delimited paths so an unusual filename cannot alter the GitHub
  # output file. Known documentation and operational-only files need no
  # closure build. Anything unfamiliar deliberately falls back to every job.
  while IFS= read -r -d '' path; do
    ((changed_paths += 1))

    case "${path}" in
      .github/workflows/ci.yml | scripts/classify-ci-changes.sh | scripts/build-ci-check-group.sh)
        mark_all
        ;;

      flake.nix | flake.lock)
        homeserver=true
        wsl=true
        integration=true
        ;;

      settings.nix)
        homeserver=true
        wsl=true
        ;;

      .github/actions/cache-auxide/*)
        homeserver=true
        ;;

      hosts/homeserver/* | modules/nixos/* | secrets/*)
        homeserver=true
        case "${path}" in
          modules/nixos/game-stream-*) integration=true ;;
        esac
        ;;

      hosts/cazpc/*)
        wsl=true
        ;;

      modules/home/development.nix | modules/home/ssh.nix | modules/home/windows-vscode.nix)
        wsl=true
        ;;

      modules/home/*)
        # The homeserver and WSL profiles both consume the shared Home Manager
        # modules. New modules default to both until explicitly classified.
        homeserver=true
        wsl=true
        ;;

      scripts/check-server-health.sh | scripts/pre-deploy-backup.sh | scripts/stage-server-release.sh)
        homeserver=true
        ;;

      tests/*)
        integration=true
        ;;

      windows/* | scripts/check-windows.ps1 | scripts/test-windows-launcher.sh | bootstrap/windows.sh | \
        bootstrap/windows.ps1 | bootstrap/windows-vscode.ps1 | bootstrap/windows-game-stream.ps1)
        windows=true
        ;;

      README.md | SECURITY.md | LICENSE | docs/* | .gitignore | .sops.yaml | .sops.yaml.example | \
        statix.toml | .github/dependabot.yml | .github/workflows/release.yml | bootstrap/README.md | \
        bootstrap/wsl.sh | scripts/build-release-artifacts.sh | scripts/check.sh | \
        scripts/publish-release.sh | scripts/secret-scan.sh)
        ;;

      *)
        echo "Unclassified path changed; running every component: ${path@Q}" >&2
        mark_all
        ;;
    esac
  done

  # A pull request should always contain a diff. Fail safe if Git returns an
  # empty set because an event shape or checkout behavior changes.
  if (( changed_paths == 0 )); then
    echo "No changed paths were reported; running every component." >&2
    mark_all
  fi
fi

echo "CI components: homeserver=${homeserver} wsl=${wsl} integration=${integration} windows=${windows}" >&2
printf 'homeserver=%s\n' "${homeserver}"
printf 'wsl=%s\n' "${wsl}"
printf 'integration=%s\n' "${integration}"
printf 'windows=%s\n' "${windows}"
