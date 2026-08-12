#!/usr/bin/env bash

set -Eeuo pipefail

readonly default_repository="joshcazalas/caz.nix"
readonly api_version="2026-03-10"
readonly expected_installable=".#nixosConfigurations.homeserver.config.system.build.toplevel"

usage() {
  cat <<'EOF'
usage: caz-stage-server-release [--check-only]

Verify the latest immutable caz.nix release, reproduce its homeserver build,
and stage it as the next NixOS boot generation. The command never activates a
new configuration or reboots the machine.

  --check-only  verify and build, but do not stage or record the release
EOF
}

check_only=false
case "${1:-}" in
  "") ;;
  --check-only) check_only=true ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

repository="${CAZ_RELEASE_REPOSITORY:-${default_repository}}"
if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid GitHub repository name: ${repository}" >&2
  exit 1
fi

if [[ "${check_only}" == false && ${EUID} -ne 0 ]]; then
  echo "Staging a NixOS release requires root; use sudo or --check-only." >&2
  exit 1
fi

state_directory="${CAZ_RELEASE_STATE_DIRECTORY:-${STATE_DIRECTORY:-/var/lib/caz-release-updater}}"
runtime_parent="${RUNTIME_DIRECTORY:-/tmp}"

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

accepted_state="${state_directory}/accepted-release.json"
if [[ "${check_only}" == false && -e "${accepted_state}" ]]; then
  if ! previous_release_id="$(jq --exit-status --raw-output '.releaseId | select(type == "number")' "${accepted_state}")"; then
    echo "Refusing to use malformed state: ${accepted_state}" >&2
    exit 1
  fi

  if ((release_id == previous_release_id)); then
    echo "Release ${release_tag} is already accepted; nothing to do."
    exit 0
  fi

  if ((release_id < previous_release_id)); then
    echo "Refusing release ${release_tag}: its ID predates the accepted release." >&2
    exit 1
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

boot_profile="$(readlink --canonicalize /nix/var/nix/profiles/system 2>/dev/null || true)"
if [[ "${boot_profile}" == "${built_store_path}" ]]; then
  deployment_status="already-staged"
  echo "==> ${release_tag} is already the next boot generation"
else
  echo "==> Staging ${release_tag} for the next boot"
  nixos-rebuild boot --flake "${flake_reference}#homeserver"

  boot_profile="$(readlink --canonicalize /nix/var/nix/profiles/system)"
  if [[ "${boot_profile}" != "${built_store_path}" ]]; then
    echo "The NixOS boot profile does not match the verified build after staging." >&2
    exit 1
  fi
  deployment_status="staged-for-next-boot"
fi

state_tmp="$(mktemp "${state_directory}/.accepted-release.XXXXXX")"
trap 'rm -rf "${work_directory}"; rm -f "${state_tmp:-}"' EXIT
jq --null-input \
  --argjson releaseId "${release_id}" \
  --arg release "${release_tag}" \
  --arg commit "${commit_sha}" \
  --arg publishedAt "${published_at}" \
  --arg storePath "${built_store_path}" \
  --arg derivation "${built_derivation}" \
  --arg status "${deployment_status}" \
  --arg stagedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" '
    {
      schemaVersion: 1,
      releaseId: $releaseId,
      release: $release,
      commit: $commit,
      publishedAt: $publishedAt,
      storePath: $storePath,
      derivation: $derivation,
      status: $status,
      stagedAt: $stagedAt
    }
  ' >"${state_tmp}"
chmod 0600 "${state_tmp}"
mv "${state_tmp}" "${accepted_state}"
trap 'rm -rf "${work_directory}"' EXIT

echo "Release ${release_tag} is verified and staged. Reboot manually when ready."
