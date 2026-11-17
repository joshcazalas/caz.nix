#!/usr/bin/env bash
# Run under fakeroot with the pre-deployment, Minecraft and device-network scripts.
set -Eeuo pipefail

script="$(realpath "$1")"
export minecraft_script network_script
network_script="$(realpath "$3")"
minecraft_script="$(realpath "$2")"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
export CAZ_BACKUP_STATE_ROOT="$fixture/root"
export CAZ_BACKUP_DIRECTORY="$fixture/backups"
export CAZ_BACKUP_STATE_PATHS="var/lib/AdGuardHome var/lib/other"
export CAZ_CONTAINER_MAINTENANCE_LOCK_HELD=true
export CAZ_BACKUP_FACTORIO=false
unset CAZ_BACKUP_PAUSE_UNITS
export CAZ_MINECRAFT_BACKUP_DIR="$fixture/game archives"
export game_data="$fixture/game data"
export rcon_log="$fixture/rcon.log"
mkdir -p "$CAZ_MINECRAFT_BACKUP_DIR" "$game_data/world"
printf 'saved world data\n' > "$game_data/world/level.dat"
printf 'old archive\n' > "$CAZ_MINECRAFT_BACKUP_DIR/minecraft-legacy.tar.zst"
# Newness must refer to this run even when a pre-existing file has a later mtime.
touch -d 'next year' "$CAZ_MINECRAFT_BACKUP_DIR/minecraft-legacy.tar.zst"

docker() {
  if [[ "$1" == inspect ]]; then
    [[ "$*" == "inspect --type container --format {{.State.Running}} minecraft" ]] || return 2
    case "${scenario:-}" in
      inspect_error) return 1 ;;
      stopped) echo false ;;
      *) echo true ;;
    esac
  else
    [[ "$*" == "exec minecraft rcon-cli "* ]] || return 2
    printf '%s\n' "${*:4}" >> "$rcon_log"
    case "${scenario:-}:$4" in
      flush_error:save-all|resume_error:save-on) return 1 ;;
    esac
  fi
}

systemctl() {
  if [[ "${2:-}" == fixture.service ]]; then
    echo "$1" >> "$rcon_log"
    if [[ "$1" == is-active ]]; then echo active; fi
    return 0
  fi
  if [[ "$*" != "start minecraft-backup.service" ]]; then
    echo "$*" >> "$rcon_log"
    return 1
  fi
  if [[ "${scenario:-}" == joined && ! -e "$game_data/joined" ]]; then
    touch "$game_data/joined"
    return 0
  fi
  case "${scenario:-}" in
    corrupt) printf 'invalid' > "$CAZ_MINECRAFT_BACKUP_DIR/minecraft-corrupt.tar.zst" ;;
    skipped) return 0 ;;
    partial) printf 'partial' > "$CAZ_MINECRAFT_BACKUP_DIR/.minecraft-backup.partial" ;;
    empty) touch "$CAZ_MINECRAFT_BACKUP_DIR/minecraft-empty.tar.zst" ;;
    symlink) ln -sf minecraft-legacy.tar.zst "$CAZ_MINECRAFT_BACKUP_DIR/minecraft-link.tar.zst" ;;
    *)
      INVOCATION_ID="$(cat /proc/sys/kernel/random/uuid)" \
        bash "$minecraft_script" "$game_data" "$CAZ_MINECRAFT_BACKUP_DIR" 7
      ;;
  esac
}
export -f docker systemctl

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

for scenario in inspect_error stopped flush_error resume_error skipped partial empty symlink corrupt; do
  : > "$rcon_log"
  if CAZ_BACKUP_PAUSE_UNITS=other.service scenario="$scenario" bash "$script"; then
    echo "Unexpected success: $scenario" >&2
    exit 1
  fi
  [[ ! -e "$CAZ_BACKUP_DIRECTORY" ]]
  if grep -q other.service "$rcon_log"; then exit 1; fi
  if [[ "$scenario" == flush_error || "$scenario" == resume_error ]]; then
    expected=$'save-off\nsave-all flush\nsave-on'
    if [[ "$scenario" == resume_error ]]; then expected+=$'\nsave-on'; fi
    [[ "$(cat "$rcon_log")" == "$expected" ]]
    [[ -z "$(find "$CAZ_MINECRAFT_BACKUP_DIR" -name '.minecraft-backup.*' -print -quit)" ]]
    [[ -z "$(find "$CAZ_MINECRAFT_BACKUP_DIR" -name 'minecraft-*.tar.zst' ! -name minecraft-legacy.tar.zst -print -quit)" ]]
  fi
done
unset scenario
: > "$rcon_log"
scenario=joined restore_and_check var/lib/private/AdGuardHome
[[ -f "$game_data/joined" ]]
[[ "$(cat "$rcon_log")" == $'save-off\nsave-all flush\nsave-on' ]]
archive="$(find "$CAZ_MINECRAFT_BACKUP_DIR" -name 'minecraft-*.tar.zst' -type f -size +0c ! -name minecraft-legacy.tar.zst ! -name minecraft-corrupt.tar.zst)"
tar --zstd --extract --to-stdout --file "$archive" ./world/level.dat | cmp - "$game_data/world/level.dat"
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

# Use the actual private-file reader. The key can live outside the configured
# network directory, including a path containing spaces.
unset CAZ_BACKUP_STATE_ROOT CAZ_BACKUP_STATE_PATHS
export CAZ_BACKUP_PAUSE_UNITS=fixture.service
export CAZ_BACKUP_DEVICE_NETWORK_COMMAND=network_backup
export network_config="$fixture/network.json"
key="$fixture/private input/wifi key"
mkdir -m 0700 "${key%/*}" "$fixture/restore"
printf 'synthetic passphrase\n' > "$key"
printf '{"interface":"wlan-test","address":"192.168.70.1/24","dhcp":{"start":"192.168.70.20","end":"192.168.70.50"},"wifi":{"ssid":"fixture","channel":6,"countryCode":"US","passphraseFile":"%s"}}' "$key" > "$network_config"
chmod 0600 "$network_config" "$key"
network_backup() { python3 "$network_script" --config "$network_config" "$@"; }
export -f network_backup
bash "$script"
archives=("$CAZ_BACKUP_DIRECTORY"/state-*.tar.zst)
tar --zstd -xf "${archives[0]}" -C "$fixture/restore"
for input in "$network_config" "$key"; do
  cmp "$input" "$fixture/restore/$input"
  [[ "$(stat --format=%a "$fixture/restore/$input")" == 600 ]]
done

rm -- "${archives[0]}" "$key"
: > "$rcon_log"
if bash "$script"; then exit 1; fi
[[ "$(tail -3 "$rcon_log")" == $'is-active\nstop\nstart' ]]
[[ -z "$(ls -A "$CAZ_BACKUP_DIRECTORY")" ]]
