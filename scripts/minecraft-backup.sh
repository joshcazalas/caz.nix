#!/usr/bin/env bash
set -Eeuo pipefail

data_dir="$1"
backup_dir="$2"
retention_days="$3"
# The timer and deployment share the same oneshot service. Even back-to-back
# invocations in the same second must publish distinct archives.
archive="$backup_dir/minecraft-$(date --utc +%Y%m%dT%H%M%SZ)-${INVOCATION_ID:?}.tar.zst"

running="$(docker inspect --type container --format '{{.State.Running}}' minecraft)"
if [[ "$running" != true ]]; then
  echo "Minecraft is not running; cannot create a consistent backup." >&2
  exit 1
fi

temporary_archive="$(mktemp --tmpdir="$backup_dir" .minecraft-backup.XXXXXX)"
restore_saving=true
cleanup() {
  if [[ "$restore_saving" == true ]]; then
    docker exec minecraft rcon-cli save-on || true
  fi
  rm -f -- "$temporary_archive"
}
trap cleanup EXIT

docker exec minecraft rcon-cli save-off
docker exec minecraft rcon-cli save-all flush
tar --create --zstd --file "$temporary_archive" \
  --exclude='./cache' --exclude='./crash-reports' --exclude='./logs' \
  --directory "$data_dir" .

docker exec minecraft rcon-cli save-on
restore_saving=false
[[ -s "$temporary_archive" ]]
mv -T -- "$temporary_archive" "$archive"

find "$backup_dir" -maxdepth 1 -type f -name 'minecraft-*.tar.zst' \
  -mtime "+$((retention_days - 1))" -delete
echo "Created $archive"
