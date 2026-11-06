#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

destination="${CAZ_SECONDARY_BACKUP_MOUNT:?}"
preflight="${CAZ_SECONDARY_BACKUP_PREFLIGHT:?}"
source_root="${CAZ_BACKUP_SOURCE_ROOT:-/var/backup}"
maintenance_lock="${CAZ_CONTAINER_MAINTENANCE_LOCK:-/run/caz-container-maintenance/lock}"

# Serialize with deployments, Factorio backups, and other maintenance. The
# standalone Minecraft job publishes archives by atomic rename; a concurrent
# source deletion makes rsync fail and prevents all retention below.
exec 7>"$maintenance_lock"
flock --exclusive 7

# Must verify the actual block device, filesystem, writable mount and available
# space before creating ANY destination directory. Never fall back to root.
"$preflight"
chmod 0700 "$destination"

groups=(minecraft factorio caz-release-updater)
sources=("${CAZ_MINECRAFT_BACKUP_DIR:-$source_root/minecraft}" "$source_root/factorio" "$source_root/caz-release-updater")
patterns=('minecraft-*.tar.zst' 'factorio-*.tar.zst' 'state-*.tar.zst')

# Validate all sources first. A missing/empty source is an error, never an
# instruction to erase its second copy.
for index in "${!groups[@]}"; do
  source_dir="${sources[$index]}"
  if [[ ! -d "$source_dir" ]]; then
    echo "Missing backup source: $source_dir" >&2
    exit 1
  fi
  count=$(find "$source_dir" -maxdepth 1 -type f -name "${patterns[$index]}" -printf x | wc -c)
  if (( count == 0 )); then
    echo "No completed archives in $source_dir; refusing to continue." >&2
    exit 1
  fi
done

for index in "${!groups[@]}"; do
  target="$destination/${groups[$index]}"
  install -d -m 0700 "$target"
  # Only finalized regular files; exclude temporary archives, subdirectories
  # and symlinks. Check content even when size and timestamps match. Rsync
  # writes temporary files and renames them rather than overwriting in place.
  rsync --dirs --times --perms --checksum --chmod=D700,F600 --exclude='*/' \
    --include="/${patterns[$index]}" --exclude='*' \
    "${sources[$index]}/" "$target/"
done

# Only prune after EVERY source copied successfully. Keep 30 days based on
# archive mtime, and always keep archives still retained on the primary SSD.
for index in "${!groups[@]}"; do
  while IFS= read -r -d '' archive; do
    if [[ ! -e "${sources[$index]}/${archive##*/}" ]]; then
      rm -- "$archive"
    fi
  done < <(find "$destination/${groups[$index]}" -maxdepth 1 -type f \
    -name "${patterns[$index]}" -mmin +43200 -print0)
done

date --utc +%FT%TZ > "$destination/last-success"
echo "Secondary backup copy completed: $destination"
