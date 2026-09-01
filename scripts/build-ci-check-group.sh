#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  echo "usage: $0 {validate|homeserver|wsl|integration}" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

requested_group="$1"
case "${requested_group}" in
  validate | homeserver | wsl | integration) ;;
  *)
    usage
    exit 2
    ;;
esac

nix_system="x86_64-linux"
check_names="$(
  nix eval --raw ".#checks.${nix_system}" \
    --apply 'checks: builtins.concatStringsSep "\n" (builtins.attrNames checks)'
)"

declare -a selected_checks=()
unclassified=false

while IFS= read -r check_name; do
  [[ -n "${check_name}" ]] || continue

  case "${check_name}" in
    homeserver) check_group=homeserver ;;
    wsl-*) check_group=wsl ;;
    game-stream-* | home-access-gateway | network-policy) check_group=integration ;;
    *)
      echo "Flake check '${check_name}' has no CI group." >&2
      unclassified=true
      continue
      ;;
  esac

  if [[ "${requested_group}" == "${check_group}" ]]; then
    selected_checks+=(".#checks.${nix_system}.${check_name}")
  fi
done <<<"${check_names}"

if [[ "${unclassified}" == true ]]; then
  echo "Assign every check in scripts/build-ci-check-group.sh before CI may pass." >&2
  exit 1
fi

if [[ "${requested_group}" == validate ]]; then
  echo "Every flake check belongs to a CI group."
  exit 0
fi

if (( ${#selected_checks[@]} == 0 )); then
  echo "No ${requested_group} checks are declared; nothing to build."
  exit 0
fi

printf 'Building %s checks:' "${requested_group}"
printf ' %s' "${selected_checks[@]}"
printf '\n'

nix build --no-link --print-build-logs "${selected_checks[@]}"
