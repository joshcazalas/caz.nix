#!/usr/bin/env bash

set -Eeuo pipefail

readonly repository_root="${1:?repository root is required}"
readonly work_directory="${TMPDIR:?}/game-stream-enrollment-test-$$"
readonly fake_bin="${work_directory}/bin"
readonly secrets_file="${work_directory}/homeserver.yaml"

mkdir -p "${fake_bin}"
touch "${secrets_file}"
trap 'rm -rf -- "${work_directory}"' EXIT

cat >"${fake_bin}/wg" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
gateway_private='+MAAEjYR''wLJa9J3N''3L7IvM0U''rhK/305n''Z64BtT3C''IEM='
case "${1:-}" in
  genkey)
    echo "${gateway_private}"
    ;;
  pubkey)
    IFS= read -r private_key || [[ -n "${private_key}" ]]
    case "${private_key}" in
      "${gateway_private}")
        echo 'bW/PIeb0C8q05svQlT24VAaw58GQrk/0tErYhFsJOjQ='
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/sops" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  decrypt)
    [[ "$2" == --extract && "$4" == --output && -s "$6" ]] || exit 128
    grep -q '^# caz.nix-enrollment-state-v1 = ' "$6" || exit 128
    cp "$6" "$5"
    ;;
  set)
    [[ "$2" == --value-file && $# -eq 5 ]] || exit 2
    cp "$5" "$3"
    ;;
  *) exit 2 ;;
esac
EOF

sed -i "1c#!${BASH}" "${fake_bin}/sops" "${fake_bin}/wg"
chmod +x "${fake_bin}/sops" "${fake_bin}/wg"
export PATH="${fake_bin}:${PATH}"

host_request="${work_directory}/host-request.json"
client_one_request="${work_directory}/client-one-request.json"
client_two_request="${work_directory}/client-two-request.json"
duplicate_key_request="${work_directory}/duplicate-key-request.json"
undecryptable_secrets="${work_directory}/undecryptable-homeserver.yaml"
host_response="${work_directory}/host-response.json"
client_one_response="${work_directory}/client-one-response.json"
client_two_response="${work_directory}/client-two-response.json"

jq -n '
  {
    schema: "caz.nix/game-stream-request/v1",
    role: "host",
    requestId: "11111111-1111-4111-8111-111111111111",
    publicKey: "4r4Uo/1VVCwydWVc+1bRHMDN/ln6+b6yJI2BBOOqtlA="
  }
' >"${host_request}"
jq -n '
  {
    schema: "caz.nix/game-stream-request/v1",
    role: "client",
    requestId: "22222222-2222-4222-8222-222222222222",
    publicKey: "RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM="
  }
' >"${client_one_request}"
jq -n '
  {
    schema: "caz.nix/game-stream-request/v1",
    role: "client",
    requestId: "33333333-3333-4333-8333-333333333333",
    publicKey: "xIW4eCfneRlGcuNXvKJsGKdLUas+3XzQaln0eQfxyVg="
  }
' >"${client_two_request}"
jq -n '
  {
    schema: "caz.nix/game-stream-request/v1",
    role: "client",
    requestId: "44444444-4444-4444-8444-444444444444",
    publicKey: "RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM="
  }
' >"${duplicate_key_request}"

enrollment="${repository_root}/scripts/game-stream-enrollment.sh"

# A declared value that cannot be decrypted must never be mistaken for an
# uninitialized gateway and replaced with a fresh private key.
printf '%s\n' 'gameStreamGatewayConfig: ENC[unavailable]' >"${undecryptable_secrets}"
if bash "${enrollment}" init-host "${host_request}" \
  --host-endpoint 192.168.1.50:51820 \
  --client-endpoint stream.example.test:51820 \
  --gateway-address 192.0.2.1/32 \
  --host-address 192.0.2.2/32 \
  --client-pool 198.51.100.16/28 \
  --output "${work_directory}/undecryptable-response.json" \
  --secrets-file "${undecryptable_secrets}"; then
  echo 'An undecryptable existing gateway was unexpectedly reinitialized.' >&2
  exit 1
fi
grep -Fqx 'gameStreamGatewayConfig: ENC[unavailable]' "${undecryptable_secrets}"

bash "${enrollment}" init-host "${host_request}" \
  --host-endpoint 192.168.1.50:51820 \
  --client-endpoint stream.example.test:51820 \
  --gateway-address 192.0.2.1/32 \
  --host-address 192.0.2.2/32 \
  --client-pool 198.51.100.16/28 \
  --output "${host_response}" \
  --secrets-file "${secrets_file}"

jq -e '
  .schema == "caz.nix/game-stream-enrollment/v1"
  and .role == "host"
  and .requestId == "11111111-1111-4111-8111-111111111111"
  and .address == "192.0.2.2/32"
  and .allowedIps == "198.51.100.16/28"
  and .endpoint == "192.168.1.50:51820"
  and .persistentKeepalive == 25
' "${host_response}" >/dev/null
[[ "$(grep -c '^\[Peer\]$' "${secrets_file}")" -eq 1 ]]

cp "${secrets_file}" "${work_directory}/initialized.conf"
bash "${enrollment}" init-host "${host_request}" \
  --host-endpoint 192.168.1.50:51820 \
  --client-endpoint stream.example.test:51820 \
  --gateway-address 192.0.2.1/32 \
  --host-address 192.0.2.2/32 \
  --client-pool 198.51.100.16/28 \
  --output "${host_response}" \
  --secrets-file "${secrets_file}"
cmp "${secrets_file}" "${work_directory}/initialized.conf"

bash "${enrollment}" add-client "${client_one_request}" \
  --output "${client_one_response}" \
  --secrets-file "${secrets_file}"
jq -e '
  .role == "client"
  and .address == "198.51.100.17/32"
  and .allowedIps == "192.0.2.2/32"
  and .endpoint == "stream.example.test:51820"
' "${client_one_response}" >/dev/null
[[ "$(grep -c '^\[Peer\]$' "${secrets_file}")" -eq 2 ]]

cp "${secrets_file}" "${work_directory}/one-client.conf"
bash "${enrollment}" add-client "${client_one_request}" \
  --output "${client_one_response}" \
  --secrets-file "${secrets_file}"
cmp "${secrets_file}" "${work_directory}/one-client.conf"

bash "${enrollment}" add-client "${client_two_request}" \
  --output "${client_two_response}" \
  --secrets-file "${secrets_file}"
jq -e '.address == "198.51.100.18/32"' "${client_two_response}" >/dev/null
[[ "$(grep -c '^\[Peer\]$' "${secrets_file}")" -eq 3 ]]

if bash "${enrollment}" add-client "${duplicate_key_request}" \
  --output "${work_directory}/invalid-response.json" \
  --secrets-file "${secrets_file}"; then
  echo 'Duplicate public key unexpectedly enrolled.' >&2
  exit 1
fi

status_output="$(bash "${enrollment}" status --secrets-file "${secrets_file}")"
grep -Fqx 'Enrolled clients: 2' <<<"${status_output}"
bash "${enrollment}" remove-client '22222222-2222-4222-8222-222222222222' \
  --secrets-file "${secrets_file}"
[[ "$(grep -c '^\[Peer\]$' "${secrets_file}")" -eq 2 ]]
! grep -Fq 'RYOxSmSdLVmFheEeofQGbQMLQLxhUjX5NdLu7H2P6VM=' "${secrets_file}"

bash "${enrollment}" remove-client '22222222-2222-4222-8222-222222222222' \
  --secrets-file "${secrets_file}"

echo 'Game-stream enrollment lifecycle passed.'
