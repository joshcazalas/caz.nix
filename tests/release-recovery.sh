#!/usr/bin/env bash
# Run inside the storage test VM in a private mount namespace. Use real system
# paths and state files, but isolate the running and next-boot generation links.
set -Eeuo pipefail
updater="$1"
export previous="$2" candidate="$3"
export fixture
fixture="$(mktemp -d)"
mkdir "$fixture/profiles" "$fixture/runtime"
mount --bind "$fixture/profiles" /nix/var/nix/profiles
mount -t tmpfs tmpfs /run
mkdir -p /run/user /boot /home /root

export CAZ_RELEASE_STATE_DIRECTORY="$fixture/state" RUNTIME_DIRECTORY="$fixture/runtime"
export CAZ_CONTAINER_MAINTENANCE_LOCK="$fixture/maintenance.lock"
state="$CAZ_RELEASE_STATE_DIRECTORY"
pending="$state/pending-release.json"
accepted="$state/accepted-release.json"
failed="$state/failed-release.json"
root="$state/rollback-system"
profile=/nix/var/nix/profiles/system
commit=0123456789ab0000000000000000000000000000
tag=caz.nix-2026.09.14-g0123456789ab

jq -n --arg tag "$tag" --arg sha "$commit" --arg path "$candidate" '{
  schemaVersion: 1, release: $tag, source: {commit: $sha}, outputs: {homeserver: {
    installable: ".#nixosConfigurations.homeserver.config.system.build.toplevel",
    storePath: $path, derivation: ($path + ".drv")}}}' > "$fixture/manifest.json"
(cd "$fixture" && sha256sum manifest.json > SHA256SUMS)
jq -n --arg tag "$tag" --arg sha "$commit" \
  --arg manifest "$(sha256sum "$fixture/manifest.json" | cut -d' ' -f1)" \
  --arg sums "$(sha256sum "$fixture/SHA256SUMS" | cut -d' ' -f1)" '{
    id: 123, tag_name: $tag, target_commitish: $sha, immutable: true, draft: false,
    prerelease: false, published_at: "2026-09-14T00:00:00Z",
    assets: ([["manifest.json", $manifest], ["SHA256SUMS", $sums]] | map({
      name: .[0], digest: ("sha256:" + .[1]),
      browser_download_url: ("https://github.com/joshcazalas/caz.nix/releases/download/" + $tag + "/" + .[0])}))}' \
  > "$fixture/release.json"

curl() {
  echo discovery >> "$fixture/calls"
  [[ "${offline:-false}" == false ]] || return 97
  local output url="${!#}"
  while [[ $1 != --output ]]; do shift; done
  output="$2"
  case "$url" in
    */latest) cp "$fixture/release.json" "$output" ;;
    */attestations/sha256:*) echo '{"attestations":[{"bundle_url":"https://fixture.blob.core.windows.net/attestations/signature"}]}' > "$output" ;;
    */attestations/signature) echo '{}' > "$output" ;;
    *) cp "$fixture/${url##*/}" "$output" ;;
  esac
}
gh() { [[ "$1 $2" == "attestation verify" ]]; }
snzip() { cat "${!#}"; }
nix() {
  case "$1" in
    build) echo "$candidate" ;;
    path-info) echo "$candidate.drv" ;;
    *) return 2 ;;
  esac
}
caz-check-deployment-storage() { echo preflight >> "$fixture/calls"; }
caz-pre-deployment-backup() { echo backup >> "$fixture/calls"; }
nix-env() {
  [[ "$1 $2 $3" == "--profile /nix/var/nix/profiles/system --set" ]] || return 2
  if [[ "${interrupt:-}" == before-profile && "$4" == "$candidate" ]]; then kill -KILL "$BASHPID"; fi
  ln -sfnT "$4" "$2"
  if [[ "${interrupt:-}" == after-profile && "$4" == "$candidate" ]]; then kill -KILL "$BASHPID"; fi
}
nix-store() {
  [[ "$1 $2 $3" == "--realise $previous --add-root" ]] || return 2
  ln -s "$2" "$4"
}
mv() {
  if [[ "${interrupt:-}" == before-accept && "${!#}" == "$CAZ_RELEASE_STATE_DIRECTORY/accepted-release.json" ]]; then
    kill -KILL "$BASHPID"
  fi
  command mv "$@" || return 1
  if [[ "${interrupt:-}" == after-accept && "${!#}" == "$CAZ_RELEASE_STATE_DIRECTORY/accepted-release.json" ]]; then
    kill -KILL "$BASHPID"
  fi
}
export -f curl gh snzip nix nix-env nix-store mv caz-check-deployment-storage caz-pre-deployment-backup

reset_fixture() {
  rm -rf -- "$state"
  : > "$fixture/calls"
  ln -sfnT "$previous" /run/current-system
  ln -sfnT "$previous" "$profile"
}
expect_exit() {
  local expected="$1" actual=0
  shift
  bash "$updater" "$@" > "$fixture/log" 2>&1 || actual=$?
  if [[ "$expected" != "$actual" ]]; then
    cat "$fixture/log" >&2
    echo "Expected updater exit $expected, got $actual" >&2
    exit 1
  fi
}
expect_recovered() {
  : > "$fixture/calls"
  offline=true expect_exit 1 --force
  grep -Fq 'Recovered the previous generation' "$fixture/log"
  [[ "$(readlink -e /run/current-system)" == "$previous" && "$(readlink -e "$profile")" == "$previous" ]]
  [[ ! -e "$pending" && ! -L "$root" ]]
  jq -e --arg prev "$previous" --arg new "$candidate" \
    '.rollbackStatus == "succeeded" and .previousStorePath == $prev and .attemptedStorePath == $new' "$failed"
  grep -Fxq "health $previous --wait 600 --stabilize 60" "$fixture/calls"
  ! grep -Eq '^(discovery|backup)$' "$fixture/calls" || exit 1
  expect_exit 0
  grep -Eq 'quarantined|manual rollback is being preserved' "$fixture/log"
}

for stage in before-profile after-profile after-switch before-accept; do
  reset_fixture
  interrupt="$stage" expect_exit 137
  [[ -f "$pending" && "$(readlink -e "$root")" == "$previous" && ! -e "$accepted" ]]
  expect_exit 0 --status
  grep -Fq 'Unfinished deployment' "$fixture/log"
  expect_exit 0 --check-only
  [[ -f "$pending" ]]
  expect_recovered
done

# A forced retry can have an older acceptance for this exact release. It
# must still roll back if interrupted before the new acceptance is committed.
reset_fixture
expect_exit 0
ln -sfnT "$previous" /run/current-system
ln -sfnT "$previous" "$profile"
interrupt=after-switch expect_exit 137 --force
offline=true fail_previous=true expect_exit 1
[[ -f "$pending" && -L "$root" ]]
jq -e '.rollbackStatus == "health-check-failed"' "$failed"
expect_recovered

reset_fixture
fail_candidate=true expect_exit 1
jq -e '.rollbackStatus == "succeeded" and .reason == "post-deployment health checks failed"' "$failed"
[[ ! -e "$pending" && ! -L "$root" && "$(readlink -e /run/current-system)" == "$previous" ]]

reset_fixture
fail_candidate=true interrupt=rollback-switch expect_exit 137
jq -e '.rollbackStatus == "in-progress"' "$failed"
expect_recovered

reset_fixture
fail_candidate=true expect_exit 1
interrupt=after-accept expect_exit 137 --force
[[ ! -e "$pending" && ! -e "$failed" && -L "$root" ]]
expect_exit 0
[[ ! -L "$root" && ! -e "$failed" && "$(readlink -e /run/current-system)" == "$candidate" ]]
jq -e '.status == "deployed"' "$accepted"

# An unrelated manual selection must keep both the administrator's choice and
# the recovery evidence. No pending record means normal adoption is available.
reset_fixture
interrupt=after-switch expect_exit 137
ln -sfnT "$fixture" "$profile"
offline=true expect_exit 1
[[ "$(readlink -e "$profile")" == "$fixture" && -e "$pending" && -L "$root" ]]
ln -sfnT "$candidate" "$profile"
cp "$pending" "$fixture/pending-copy"
echo '{}' > "$pending"
offline=true expect_exit 1
[[ "$(readlink -e /run/current-system)" == "$candidate" && -L "$root" ]]
cp "$fixture/pending-copy" "$pending"
expect_recovered

reset_fixture
ln -sfnT "$candidate" /run/current-system
fail_candidate=true expect_exit 1
[[ "$(readlink -e "$profile")" == "$previous" && ! -e "$pending" && ! -e "$accepted" ]]
expect_exit 0
[[ "$(readlink -e "$profile")" == "$candidate" && ! -e "$failed" && ! -e "$pending" ]]
jq -e '.status == "already-running"' "$accepted"
