#!/usr/bin/env bash
# Run under fakeroot with the production backup script as the first argument.
set -Eeuo pipefail

script="$(realpath "$1")"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export CAZ_BACKUP_STATE_ROOT="$fixture/root"
export CAZ_BACKUP_DIRECTORY="$fixture/backups"
export CAZ_BACKUP_STATE_PATHS="var/lib/AdGuardHome var/lib/other"
export CAZ_CONTAINER_MAINTENANCE_LOCK_HELD=true
export CAZ_BACKUP_FACTORIO=false
unset CAZ_BACKUP_PAUSE_UNITS
systemctl() { [[ "$1" == start && "$2" == minecraft-backup.service ]]; }
export -f systemctl

public="$CAZ_BACKUP_STATE_ROOT/var/lib/AdGuardHome"
private="$CAZ_BACKUP_STATE_ROOT/var/lib/private/AdGuardHome"
mkdir -p "$private/data" "$CAZ_BACKUP_STATE_ROOT/var/lib/other"
printf 'schema_version: 32\n' > "$private/AdGuardHome.yaml"
printf 'saved filter\n' > "$private/data/filter.txt"
ln -s filter.txt "$private/data/current"
ln -s private/AdGuardHome "$public"

restore_and_check() {
  local member="$1" restore="$fixture/restore"
  bash "$script"
  local archives=("$CAZ_BACKUP_DIRECTORY"/state-*.tar.zst)
  [[ "${#archives[@]}" == 1 ]]
  mkdir "$restore"
  tar --extract --zstd --file "${archives[0]}" --directory "$restore"
  [[ -d "$restore/$member" && ! -L "$restore/$member" ]]
  cmp "$public/AdGuardHome.yaml" "$restore/$member/AdGuardHome.yaml"
  cmp "$public/data/filter.txt" "$restore/$member/data/filter.txt"
  [[ "$(readlink "$restore/$member/data/current")" == filter.txt ]]
  [[ -d "$restore/var/lib/other" ]]
  rm -r -- "$restore" "${archives[0]}"
}

restore_and_check var/lib/private/AdGuardHome
unlink "$public"
mv "$private" "$public"
restore_and_check var/lib/AdGuardHome

# A different valid source must not mask missing or misdirected AdGuard data.
mv "$public" "$fixture/unexpected"
ln -s "$fixture/unexpected" "$public"
if bash "$script"; then exit 1; fi
unlink "$public"
mkdir "$public"
if bash "$script"; then exit 1; fi
ln -s "$fixture/unexpected/AdGuardHome.yaml" "$public/AdGuardHome.yaml"
if bash "$script"; then exit 1; fi
[[ -z "$(ls -A "$CAZ_BACKUP_DIRECTORY")" ]]
