#!/usr/bin/env bash

set -Eeuo pipefail

readonly default_repository="joshcazalas/caz.nix"
readonly api_version="2026-03-10"
readonly expected_installable=".#nixosConfigurations.homeserver.config.system.build.toplevel"

usage() {
  cat <<'EOF'
usage: caz-deploy-server-release [--check-only | --deploy-now] [--force]
       caz-deploy-server-release --status

Verify the latest immutable caz.nix release, reproduce its homeserver build,
create application-consistent local backups, activate it, require service
health to stabilize, and roll back automatically if activation is unhealthy.
The command never reboots the machine.

  --check-only  verify and build without changing or recording system state
  --deploy-now  deploy immediately (this is the default when run manually)
  --force       manually retry a quarantined or already-recorded latest release
  --status      show local deployment, quarantine, and reboot state
EOF
}

mode=deploy
check_only=false
force=false
action_selected=false

while (( $# > 0 )); do
  case "$1" in
    --check-only)
      if [[ "$action_selected" == true ]]; then
        usage >&2
        exit 2
      fi
      mode=check
      check_only=true
      action_selected=true
      ;;
    --deploy-now)
      if [[ "$action_selected" == true ]]; then
        usage >&2
        exit 2
      fi
      mode=deploy
      action_selected=true
      ;;
    --force)
      force=true
      ;;
    --status)
      if [[ "$action_selected" == true ]]; then
        usage >&2
        exit 2
      fi
      mode=status
      action_selected=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$mode" != deploy && "$force" == true ]]; then
  usage >&2
  exit 2
fi

repository="${CAZ_RELEASE_REPOSITORY:-${default_repository}}"
if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository name: ${repository}" >&2
  exit 1
fi

if [[ "$mode" != check && ${EUID} -ne 0 ]]; then
  echo "Deployment state and activation require root; use sudo or --check-only." >&2
  exit 1
fi

state_directory="${CAZ_RELEASE_STATE_DIRECTORY:-${STATE_DIRECTORY:-/var/lib/caz-release-updater}}"
runtime_parent="${RUNTIME_DIRECTORY:-/tmp}"
accepted_state="${state_directory}/accepted-release.json"
failed_state="${state_directory}/failed-release.json"

if [[ "$mode" == status ]]; then
  echo "Running system:  $(readlink --canonicalize /run/current-system 2>/dev/null || echo unknown)"
  echo "Next boot:      $(readlink --canonicalize /nix/var/nix/profiles/system 2>/dev/null || echo unknown)"
  echo

  if [[ -e "$accepted_state" ]]; then
    echo "Latest accepted deployment:"
    jq . "$accepted_state"
  else
    echo "No release has been accepted by the automatic deployer yet."
  fi

  if [[ -e "$failed_state" ]]; then
    echo
    echo "Quarantined deployment:"
    jq . "$failed_state"
  fi
  exit 0
fi

if [[ "${check_only}" == false ]]; then
  mkdir -p "${state_directory}"
  chmod 0700 "${state_directory}"
  exec 9>"${state_directory}/update.lock"
  if ! flock --nonblock 9; then
    echo "Another caz.nix release update is already running; exiting."
    exit 0
  fi
fi

work_directory="$(mktemp -d "${runtime_parent}/caz-release.XXXXXX")"
trap 'rm -rf "${work_directory}"' EXIT

api_get() {
  local url="$1"
  local output="$2"

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-delay 2 \
    --retry-all-errors \
    --header 'Accept: application/vnd.github+json' \
    --header "X-GitHub-Api-Version: ${api_version}" \
    --output "${output}" \
    "${url}"
}

download_asset() {
  local name="$1"
  local metadata url declared_digest actual_digest

  metadata="$({
    jq --compact-output --exit-status --arg name "${name}" '
      [.assets[] | select(.name == $name)]
      | if length == 1 then .[0] else error("required release asset missing or duplicated") end
      | select(
          (.browser_download_url | type) == "string"
          and (.digest | type) == "string"
          and (.digest | test("^sha256:[0-9a-f]{64}$"))
        )
    ' "${work_directory}/release.json"
  })" || {
    echo "Release asset ${name} is missing or malformed." >&2
    exit 1
  }

  url="$(jq --raw-output '.browser_download_url' <<<"${metadata}")"
  declared_digest="$(jq --raw-output '.digest' <<<"${metadata}")"

  if [[ "${url}" != "https://github.com/${repository}/releases/download/${release_tag}/${name}" ]]; then
    echo "Release asset ${name} has an unexpected download URL." >&2
    exit 1
  fi

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-delay 2 \
    --retry-all-errors \
    --output "${work_directory}/${name}" \
    "${url}"

  actual_digest="sha256:$(sha256sum "${work_directory}/${name}" | cut -d ' ' -f 1)"
  if [[ "${actual_digest}" != "${declared_digest}" ]]; then
    echo "GitHub asset digest mismatch for ${name}." >&2
    exit 1
  fi
}

echo "==> Discovering the latest immutable caz.nix release"
api_get \
  "https://api.github.com/repos/${repository}/releases/latest" \
  "${work_directory}/release.json"

if ! jq --exit-status '
  (.id | type) == "number"
  and (.tag_name | type) == "string"
  and (.target_commitish | type) == "string"
  and (.published_at | type) == "string"
  and .draft == false
  and .prerelease == false
  and .immutable == true
  and (.assets | type) == "array"
' "${work_directory}/release.json" >/dev/null; then
  echo "The latest GitHub release is not a published, immutable release." >&2
  exit 1
fi

release_id="$(jq --raw-output '.id' "${work_directory}/release.json")"
release_tag="$(jq --raw-output '.tag_name' "${work_directory}/release.json")"
commit_sha="$(jq --raw-output '.target_commitish' "${work_directory}/release.json")"
published_at="$(jq --raw-output '.published_at' "${work_directory}/release.json")"

if [[ ! "${release_id}" =~ ^[0-9]+$ ]]; then
  echo "Release ID is not numeric." >&2
  exit 1
fi

if [[ ! "${release_tag}" =~ ^caz\.nix-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-g([0-9a-f]{12})$ ]]; then
  echo "Unexpected release tag: ${release_tag}" >&2
  exit 1
fi
tag_commit_prefix="${BASH_REMATCH[1]}"

if [[ ! "${commit_sha}" =~ ^[0-9a-f]{40}$ || "${commit_sha:0:12}" != "${tag_commit_prefix}" ]]; then
  echo "Release tag and target commit do not agree." >&2
  exit 1
fi

if [[ "${check_only}" == false && -e "${accepted_state}" ]]; then
  if ! previous_release_id="$(jq --exit-status --raw-output '.releaseId | select(type == "number")' "${accepted_state}")"; then
    echo "Refusing to use malformed state: ${accepted_state}" >&2
    exit 1
  fi

  if ((release_id < previous_release_id)); then
    echo "Refusing release ${release_tag}: its ID predates the accepted release." >&2
    exit 1
  fi

  if ((release_id == previous_release_id)) && [[ "$force" == false ]]; then
    accepted_store_path="$(jq --exit-status --raw-output '.storePath | select(type == "string")' \
      "$accepted_state")" || {
      echo "Refusing to use malformed state: ${accepted_state}" >&2
      exit 1
    }
    running_store_path="$(readlink --canonicalize /run/current-system)"
    if [[ "$running_store_path" == "$accepted_store_path" ]]; then
      echo "Release ${release_tag} is already deployed and accepted; nothing to do."
    else
      echo "Release ${release_tag} is accepted but is not currently running."
      echo "A manual rollback is being preserved; use --force to deploy it again."
    fi
    exit 0
  fi
fi

if [[ "${check_only}" == false && -e "$failed_state" && "$force" == false ]]; then
  failed_release_id="$(jq --exit-status --raw-output '.releaseId | select(type == "number")' \
    "$failed_state")" || {
    echo "Refusing to use malformed state: ${failed_state}" >&2
    exit 1
  }

  if ((release_id == failed_release_id)); then
    echo "Release ${release_tag} is quarantined after a failed deployment; skipping it."
    echo "Inspect ${failed_state}, then use --force to retry it deliberately."
    exit 0
  fi
fi

echo "==> Downloading the signed deployment metadata"
download_asset manifest.json
download_asset SHA256SUMS

manifest_digest="sha256:$(sha256sum "${work_directory}/manifest.json" | cut -d ' ' -f 1)"
api_get \
  "https://api.github.com/repos/${repository}/attestations/${manifest_digest}" \
  "${work_directory}/attestations.json"

if ! jq --exit-status '
  (.attestations | type) == "array"
  and (.attestations | length) > 0
  and all(.attestations[]; (.bundle_url | type) == "string")
' "${work_directory}/attestations.json" >/dev/null; then
  echo "GitHub returned no attestations for manifest.json." >&2
  exit 1
fi

mapfile -t bundle_urls < <(
  jq --raw-output '.attestations[].bundle_url' "${work_directory}/attestations.json"
)
: >"${work_directory}/attestations.jsonl"

for index in "${!bundle_urls[@]}"; do
  bundle_url="${bundle_urls[${index}]}"
  bundle_compressed="${work_directory}/attestation-${index}.raw"

  # GitHub's current API returns short-lived Azure Blob URLs containing raw
  # Snappy-compressed Sigstore bundles. Restrict the redirect target before
  # fetching it; the decoded bundle is still cryptographically verified below.
  if [[ ! "${bundle_url}" =~ ^https://[A-Za-z0-9.-]+\.blob\.core\.windows\.net/attestations/ ]]; then
    echo "GitHub returned an unexpected attestation bundle URL." >&2
    exit 1
  fi

  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-delay 2 \
    --retry-all-errors \
    --output "${bundle_compressed}" \
    "${bundle_url}"

  snzip -d -c -t raw "${bundle_compressed}" \
    | jq --compact-output --exit-status '.' \
    >>"${work_directory}/attestations.jsonl"
done

echo "==> Verifying keyless provenance without a GitHub credential"
mkdir "${work_directory}/gh-config"
export GH_CONFIG_DIR="${work_directory}/gh-config"
unset GH_TOKEN GITHUB_TOKEN

attestation_policy=(
  --repo "${repository}"
  --bundle "${work_directory}/attestations.jsonl"
  --signer-workflow "${repository}/.github/workflows/release.yml"
  --source-ref refs/heads/main
  --source-digest "${commit_sha}"
  --deny-self-hosted-runners
)

gh attestation verify "${work_directory}/manifest.json" "${attestation_policy[@]}"
gh attestation verify "${work_directory}/SHA256SUMS" "${attestation_policy[@]}"

manifest_checksum_count="$(awk '$2 == "manifest.json" { count++ } END { print count + 0 }' \
  "${work_directory}/SHA256SUMS")"
manifest_checksum="$(awk '$2 == "manifest.json" { print $1 }' \
  "${work_directory}/SHA256SUMS")"
if [[ "${manifest_checksum_count}" != 1 || ! "${manifest_checksum}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "SHA256SUMS does not contain exactly one valid manifest.json entry." >&2
  exit 1
fi

if [[ "sha256:${manifest_checksum}" != "${manifest_digest}" ]]; then
  echo "SHA256SUMS does not match manifest.json." >&2
  exit 1
fi

if ! jq --exit-status \
  --arg release "${release_tag}" \
  --arg commit "${commit_sha}" \
  --arg installable "${expected_installable}" '
    .schemaVersion == 1
    and .release == $release
    and .source.commit == $commit
    and .outputs.homeserver.installable == $installable
    and (.outputs.homeserver.storePath | type) == "string"
    and (.outputs.homeserver.storePath | startswith("/nix/store/"))
    and (.outputs.homeserver.derivation | type) == "string"
    and (.outputs.homeserver.derivation | startswith("/nix/store/"))
    and (.outputs.homeserver.derivation | endswith(".drv"))
  ' "${work_directory}/manifest.json" >/dev/null; then
  echo "The signed release manifest violates the deployment policy." >&2
  exit 1
fi

expected_store_path="$(jq --raw-output '.outputs.homeserver.storePath' \
  "${work_directory}/manifest.json")"
expected_derivation="$(jq --raw-output '.outputs.homeserver.derivation' \
  "${work_directory}/manifest.json")"
flake_reference="github:${repository}/${commit_sha}"

echo "==> Reproducing the exact homeserver build from ${commit_sha}"
mapfile -t built_paths < <(
  nix build \
    --no-link \
    --print-out-paths \
    "${flake_reference}#nixosConfigurations.homeserver.config.system.build.toplevel"
)

if [[ ${#built_paths[@]} -ne 1 ]]; then
  echo "Expected one homeserver output, got ${#built_paths[@]}." >&2
  exit 1
fi
built_store_path="${built_paths[0]}"
built_derivation="$(nix path-info --derivation "${built_store_path}")"

if [[ "${built_store_path}" != "${expected_store_path}" ]]; then
  echo "Built store path does not match the signed release manifest." >&2
  echo "expected: ${expected_store_path}" >&2
  echo "built:    ${built_store_path}" >&2
  exit 1
fi

if [[ "${built_derivation}" != "${expected_derivation}" ]]; then
  echo "Built derivation does not match the signed release manifest." >&2
  echo "expected: ${expected_derivation}" >&2
  echo "built:    ${built_derivation}" >&2
  exit 1
fi

if [[ "${check_only}" == true ]]; then
  echo "Release ${release_tag} passed provenance, checksum, and reproducibility checks."
  exit 0
fi

health_wait_seconds="${CAZ_RELEASE_HEALTH_WAIT_SECONDS:-300}"
stabilization_seconds="${CAZ_RELEASE_STABILIZATION_SECONDS:-60}"
for value in "$health_wait_seconds" "$stabilization_seconds"; do
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Deployment health durations must be positive integer seconds." >&2
    exit 1
  fi
done

write_accepted_state() {
  local status="$1"
  local previous_store_path="$2"
  local reboot_required="$3"
  local state_tmp

  state_tmp="$(mktemp "${state_directory}/.accepted-release.XXXXXX")"
  jq --null-input \
    --argjson releaseId "${release_id}" \
    --arg release "${release_tag}" \
    --arg commit "${commit_sha}" \
    --arg publishedAt "${published_at}" \
    --arg storePath "${built_store_path}" \
    --arg derivation "${built_derivation}" \
    --arg previousStorePath "$previous_store_path" \
    --arg status "$status" \
    --argjson rebootRequired "$reboot_required" \
    --arg deployedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schemaVersion: 2,
        releaseId: $releaseId,
        release: $release,
        commit: $commit,
        publishedAt: $publishedAt,
        storePath: $storePath,
        derivation: $derivation,
        previousStorePath: $previousStorePath,
        status: $status,
        rebootRequired: $rebootRequired,
        deployedAt: $deployedAt
      }
    ' >"$state_tmp"
  chmod 0600 "$state_tmp"
  mv "$state_tmp" "$accepted_state"

  # A newer successful release supersedes any older quarantine record, and a
  # forced successful retry clears its own quarantine.
  rm -f -- "$failed_state"
}

write_failed_state() {
  local reason="$1"
  local rollback_status="$2"
  local previous_store_path="$3"
  local state_tmp

  state_tmp="$(mktemp "${state_directory}/.failed-release.XXXXXX")"
  jq --null-input \
    --argjson releaseId "${release_id}" \
    --arg release "${release_tag}" \
    --arg commit "${commit_sha}" \
    --arg attemptedStorePath "${built_store_path}" \
    --arg previousStorePath "$previous_store_path" \
    --arg reason "$reason" \
    --arg rollbackStatus "$rollback_status" \
    --arg failedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" '
      {
        schemaVersion: 1,
        releaseId: $releaseId,
        release: $release,
        commit: $commit,
        attemptedStorePath: $attemptedStorePath,
        previousStorePath: $previousStorePath,
        reason: $reason,
        rollbackStatus: $rollbackStatus,
        failedAt: $failedAt
      }
    ' >"$state_tmp"
  chmod 0600 "$state_tmp"
  mv "$state_tmp" "$failed_state"
}

reboot_is_required() {
  local booted_components deployed_components

  booted_components="$(readlink \
    /run/booted-system/initrd \
    /run/booted-system/kernel \
    /run/booted-system/kernel-modules 2>/dev/null || true)"
  deployed_components="$(readlink \
    "${built_store_path}/initrd" \
    "${built_store_path}/kernel" \
    "${built_store_path}/kernel-modules" 2>/dev/null || true)"

  [[ -z "$booted_components" || "$booted_components" != "$deployed_components" ]]
}

current_store_path="$(readlink --canonicalize /run/current-system)"
if [[ "$current_store_path" == "$built_store_path" ]]; then
  echo "==> ${release_tag} is already the running system; adopting it as verified"
  nix-env --profile /nix/var/nix/profiles/system --set "$built_store_path"
  "${built_store_path}/bin/switch-to-configuration" boot
  caz-server-health \
    --wait "$health_wait_seconds" \
    --stabilize "$stabilization_seconds"

  reboot_required=false
  if reboot_is_required; then
    reboot_required=true
  fi
  write_accepted_state already-running "$current_store_path" "$reboot_required"
  echo "Release ${release_tag} is verified, healthy, and recorded."
  exit 0
fi

echo "==> Verifying the current generation before changing it"
caz-server-health --wait 60

echo "==> Protecting mutable application state before activation"
caz-pre-deployment-backup

previous_store_path="$current_store_path"
# Keep the rollback closure alive even after the system profile moves forward.
nix-store \
  --realise "$previous_store_path" \
  --add-root "${work_directory}/rollback-system" >/dev/null

rollback_required=false

rollback_deployment() {
  local reason="$1"
  local rollback_status=failed

  echo "Deployment failed: ${reason}" >&2
  echo "==> Rolling back to ${previous_store_path}" >&2
  write_failed_state "$reason" in-progress "$previous_store_path"

  if ! nix-env --profile /nix/var/nix/profiles/system --set "$previous_store_path"; then
    rollback_status=profile-restore-failed
  elif ! "${previous_store_path}/bin/switch-to-configuration" switch; then
    rollback_status=activation-failed
  elif [[ "$(readlink --canonicalize /run/current-system)" != "$previous_store_path" ]]; then
    rollback_status=store-path-mismatch
  elif ! caz-server-health \
    --wait "$health_wait_seconds" \
    --stabilize "$stabilization_seconds"; then
    rollback_status=health-check-failed
  else
    rollback_status=succeeded
  fi

  write_failed_state "$reason" "$rollback_status" "$previous_store_path"
  [[ "$rollback_status" == succeeded ]]
}

cleanup_after_activation() {
  local exit_status=$?
  trap - EXIT INT TERM

  if [[ "$rollback_required" == true ]]; then
    rollback_deployment "the deployment supervisor exited unexpectedly" || true
  fi
  rm -rf -- "$work_directory"
  exit "$exit_status"
}

fail_and_rollback() {
  local reason="$1"

  if rollback_deployment "$reason"; then
    echo "The previous generation is healthy again; ${release_tag} is quarantined." >&2
  else
    echo "CRITICAL: automatic rollback did not restore a healthy server." >&2
  fi
  rollback_required=false
  trap - EXIT INT TERM
  rm -rf -- "$work_directory"
  exit 1
}

trap - EXIT
trap cleanup_after_activation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rollback_required=true

echo "==> Activating verified release ${release_tag}"
nix-env --profile /nix/var/nix/profiles/system --set "$built_store_path"
if ! "${built_store_path}/bin/switch-to-configuration" switch; then
  fail_and_rollback "switch-to-configuration returned an error"
fi

if [[ "$(readlink --canonicalize /run/current-system)" != "$built_store_path" ]]; then
  fail_and_rollback "the running system path does not match the verified release"
fi

echo "==> Waiting for the deployed services to stabilize"
if ! caz-server-health \
  --wait "$health_wait_seconds" \
  --stabilize "$stabilization_seconds"; then
  fail_and_rollback "post-deployment health checks failed"
fi

reboot_required=false
if reboot_is_required; then
  reboot_required=true
fi
write_accepted_state deployed "$previous_store_path" "$reboot_required"

rollback_required=false
trap - EXIT INT TERM
rm -rf -- "$work_directory"

echo "Release ${release_tag} is verified, deployed, and healthy."
if [[ "$reboot_required" == true ]]; then
  echo "A kernel/initrd change is installed for the next ordinary reboot; no automatic reboot was requested."
fi
