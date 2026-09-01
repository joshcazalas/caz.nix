#!/usr/bin/env bash

set -Eeuo pipefail

backup_directory="${CAZ_BACKUP_DIRECTORY:-/var/backup/caz-release-updater}"
retention_count="${CAZ_BACKUP_RETENTION_COUNT:-3}"

if (( EUID != 0 )); then
  echo "Pre-deployment backups require root." >&2
  exit 1
fi

if [[ ! "$retention_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "CAZ_BACKUP_RETENTION_COUNT must be a positive integer." >&2
  exit 1
fi

if [[ "${CAZ_CONTAINER_MAINTENANCE_LOCK_HELD:-false}" != true ]]; then
  container_maintenance_lock="${CAZ_CONTAINER_MAINTENANCE_LOCK:-/run/caz-container-maintenance/lock}"
  exec 7>"$container_maintenance_lock"
  echo "==> Waiting for exclusive container maintenance access"
  flock --exclusive 7
fi

echo "==> Creating an application-consistent Minecraft backup"
systemctl start minecraft-backup.service

declare -a stopped_units=()
services_restarted=false

restart_services() {
  if (( ${#stopped_units[@]} > 0 )); then
    echo "==> Restarting services paused for the state backup"
    systemctl start "${stopped_units[@]}"
  fi
  services_restarted=true
}

cleanup() {
  local status=$?

  if [[ "$services_restarted" == false ]]; then
    restart_services || true
  fi
  if [[ -n "${temporary_archive:-}" ]]; then
    rm -f -- "$temporary_archive"
  fi
  exit "$status"
}
trap cleanup EXIT

echo "==> Pausing mutable applications for a consistent local state archive"
for unit in ${CAZ_BACKUP_PAUSE_UNITS:-}; do
  if systemctl is-active --quiet "$unit"; then
    systemctl stop "$unit"
    stopped_units+=("$unit")
  fi
done

mkdir -p "$backup_directory"
chmod 0700 "$backup_directory"

declare -a state_paths=()
for path in ${CAZ_BACKUP_STATE_PATHS:-}; do
  if [[ -e "/$path" ]]; then
    state_paths+=("$path")
  fi
done

if (( ${#state_paths[@]} == 0 )); then
  echo "No configured application state paths exist; refusing an empty backup." >&2
  exit 1
fi

temporary_archive="$(mktemp \
  --tmpdir="$backup_directory" \
  --suffix=.tar.zst \
  .pre-deploy.XXXXXX)"
archive="$backup_directory/state-$(date --utc +%Y%m%dT%H%M%SZ).tar.zst"

tar \
  --create \
  --zstd \
  --acls \
  --xattrs \
  --file "$temporary_archive" \
  --exclude='var/lib/jellyfin/log' \
  --exclude='var/lib/samba/private/msg.sock' \
  --exclude='var/lib/samba/winbindd_privileged/pipe' \
  --directory / \
  "${state_paths[@]}"
chmod 0600 "$temporary_archive"
mv -- "$temporary_archive" "$archive"
temporary_archive=""

restart_services
trap - EXIT

mapfile -t archives < <(
  find "$backup_directory" \
    -maxdepth 1 \
    -type f \
    -name 'state-*.tar.zst' \
    -printf '%T@ %p\n' \
    | sort --numeric-sort --reverse \
    | cut --delimiter=' ' --fields=2-
)

for ((index = retention_count; index < ${#archives[@]}; index++)); do
  rm -f -- "${archives[$index]}"
done

echo "Created $archive"
