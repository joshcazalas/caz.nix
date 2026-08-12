#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  echo "usage: $0 RELEASE_TAG [OUTPUT_DIRECTORY]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

release_tag="$1"
repo_root="$(git rev-parse --show-toplevel)"
output_directory="${2:-${repo_root}/.release/${release_tag}}"

if [[ "${output_directory}" != /* ]]; then
  output_directory="${repo_root}/${output_directory}"
fi

if [[ -n "$(git -C "${repo_root}" status --porcelain --untracked-files=no)" ]]; then
  echo "Refusing to describe a release from a dirty tracked worktree." >&2
  exit 1
fi

mkdir -p "${output_directory}"
cd "${repo_root}"

server_installable=".#nixosConfigurations.homeserver.config.system.build.toplevel"
wsl_installable=".#homeConfigurations.joshcaz@wsl.activationPackage"

echo "==> Building exact Nix outputs"
server_store_path="$(nix build --no-link --print-out-paths "${server_installable}")"
wsl_store_path="$(nix build --no-link --print-out-paths "${wsl_installable}")"
server_derivation="$(nix path-info --derivation "${server_store_path}")"
wsl_derivation="$(nix path-info --derivation "${wsl_store_path}")"

echo "==> Recording the flake and closure metadata"
nix flake metadata --json >"${output_directory}/flake-metadata.json"
nix path-info --json --json-format 1 --recursive --closure-size "${server_store_path}" \
  >"${output_directory}/homeserver-closure.json"
nix path-info --json --json-format 1 --recursive --closure-size "${wsl_store_path}" \
  >"${output_directory}/wsl-home-closure.json"
cp flake.lock "${output_directory}/flake.lock"

echo "==> Generating the homeserver SBOMs"
sbomnix "${server_installable}" \
  --cdx "${output_directory}/homeserver.cdx.json" \
  --spdx "${output_directory}/homeserver.spdx.json" \
  --csv "${output_directory}/homeserver.csv"

echo "==> Generating SLSA provenance from the Nix derivation"
provenance "${server_store_path}" \
  --out "${output_directory}/homeserver-provenance.json"

commit_sha="$(git rev-parse HEAD)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg release "${release_tag}" \
  --arg commit "${commit_sha}" \
  --arg createdAt "${created_at}" \
  --arg serverInstallable "${server_installable}" \
  --arg serverStorePath "${server_store_path}" \
  --arg serverDerivation "${server_derivation}" \
  --arg wslInstallable "${wsl_installable}" \
  --arg wslStorePath "${wsl_store_path}" \
  --arg wslDerivation "${wsl_derivation}" \
  '{
    schemaVersion: 1,
    release: $release,
    source: {
      commit: $commit,
      createdAt: $createdAt
    },
    outputs: {
      homeserver: {
        installable: $serverInstallable,
        storePath: $serverStorePath,
        derivation: $serverDerivation
      },
      wslHome: {
        installable: $wslInstallable,
        storePath: $wslStorePath,
        derivation: $wslDerivation
      }
    }
  }' >"${output_directory}/manifest.json"

cat >"${output_directory}/RELEASE_NOTES.md" <<EOF
# ${release_tag}

Declarative caz.nix build from commit \`${commit_sha}\`.

The attached manifest identifies the exact immutable Nix store paths and
derivations built for the NixOS homeserver and WSL Home Manager profile. The
homeserver has CycloneDX and SPDX SBOMs plus Nix-derived SLSA provenance.

Verify the downloaded metadata with:

\`\`\`bash
sha256sum --check SHA256SUMS
\`\`\`
EOF

echo "==> Hashing every release artifact"
checksum_file="$(mktemp)"
trap 'rm -f "${checksum_file}"' EXIT
(
  cd "${output_directory}"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' \
    | sort -z \
    | xargs -0 sha256sum >"${checksum_file}"
)
mv "${checksum_file}" "${output_directory}/SHA256SUMS"
trap - EXIT

echo "Release artifacts written to ${output_directory}"
