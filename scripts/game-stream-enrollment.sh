#!/usr/bin/env bash

set -Eeuo pipefail

readonly request_schema="caz.nix/game-stream-request/v1"
readonly response_schema="caz.nix/game-stream-enrollment/v1"
readonly state_schema="caz.nix/game-stream-gateway-state/v1"
readonly state_marker="# caz.nix-enrollment-state-v1 = "
readonly sops_index='["gameStreamGatewayConfig"]'

usage() {
  cat >&2 <<'EOF'
usage:
  game-stream-enrollment.sh init-host REQUEST \
    --host-endpoint LAN_HOST:PORT --client-endpoint PUBLIC_HOST:PORT \
    --gateway-address IPV4/32 --host-address IPV4/32 --client-pool IPV4/28 \
    --output RESPONSE [--listen-port PORT] \
    [--secrets-file FILE]
  game-stream-enrollment.sh add-client REQUEST --output RESPONSE \
    [--secrets-file FILE]
  game-stream-enrollment.sh remove-client REQUEST_ID [--secrets-file FILE]
  game-stream-enrollment.sh status [--secrets-file FILE]

The Windows request contains only an opaque request ID and public key. This
tool generates the gateway key during init-host, allocates exact client /32s,
updates the SOPS-encrypted gateway document, and emits private enrollment
responses without ever receiving a Windows private key.
EOF
  exit 2
}

die() {
  echo "game-stream-enrollment: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_key() {
  local key="$1"
  local decoded_length

  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  decoded_length="$(printf '%s' "$key" | base64 --decode 2>/dev/null | wc -c)"
  [[ "$decoded_length" -eq 32 ]]
}

ipv4_to_integer() {
  local address="$1"
  local octet
  local -a octets

  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$address"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
  printf '%u\n' "$((
    (10#${octets[0]} << 24) |
    (10#${octets[1]} << 16) |
    (10#${octets[2]} << 8) |
    10#${octets[3]}
  ))"
}

integer_to_ipv4() {
  local value="$1"

  printf '%d.%d.%d.%d\n' \
    "$(((value >> 24) & 255))" \
    "$(((value >> 16) & 255))" \
    "$(((value >> 8) & 255))" \
    "$((value & 255))"
}

validate_exact_ipv4_route() {
  local route="$1"

  [[ "$route" == */32 ]] || return 1
  ipv4_to_integer "${route%/32}" >/dev/null
}

validate_client_pool() {
  local pool="$1"
  local address integer

  [[ "$pool" == */28 ]] || return 1
  address="${pool%/28}"
  integer="$(ipv4_to_integer "$address")" || return 1
  (( (integer & 15) == 0 ))
}

validate_request_id() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

validate_endpoint() {
  local endpoint="$1"
  local endpoint_host endpoint_port

  [[ "$endpoint" =~ ^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$ ]] || return 1
  endpoint_host="${endpoint%:*}"
  endpoint_port="${endpoint##*:}"
  [[ -n "$endpoint_host" ]] || return 1
  (( 10#$endpoint_port >= 1 && 10#$endpoint_port <= 65535 ))
}

parse_request() {
  local request_file="$1"
  local expected_role="$2"

  [[ -r "$request_file" ]] || die "the enrollment request is unavailable"
  jq --exit-status \
    --arg schema "$request_schema" \
    --arg role "$expected_role" '
      type == "object"
      and (keys | sort) == (["publicKey", "requestId", "role", "schema"] | sort)
      and .schema == $schema
      and .role == $role
      and (.requestId | type) == "string"
      and (.publicKey | type) == "string"
    ' "$request_file" >/dev/null || die "the enrollment request has an invalid schema or role"

  request_id="$(jq --raw-output '.requestId' "$request_file")"
  request_public_key="$(jq --raw-output '.publicKey' "$request_file")"
  validate_request_id "$request_id" || die "the enrollment request ID is malformed"
  validate_key "$request_public_key" || die "the enrollment request public key is malformed"
}

metadata_from_configuration() {
  local configuration_file="$1"
  local encoded
  local -a encoded_values

  mapfile -t encoded_values < <(
    sed -n "s|^${state_marker//./\\.}||p" "$configuration_file"
  )
  [[ ${#encoded_values[@]} -eq 1 ]] ||
    die "the gateway configuration is not managed by this enrollment tool"
  encoded="${encoded_values[0]}"
  state_json="$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)" ||
    die "the encrypted enrollment state is malformed"
  state_json="$(jq --compact-output --sort-keys . <<<"$state_json")" ||
    die "the encrypted enrollment state is not valid JSON"
}

configuration_interface_value() {
  local configuration_file="$1"
  local wanted="$2"

  awk -F= -v wanted="$wanted" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[Interface\][[:space:]]*$/ { in_interface = 1; next }
    /^[[:space:]]*\[/ { in_interface = 0; next }
    in_interface && index($0, "=") {
      key = trim($1)
      value = substr($0, index($0, "=") + 1)
      if (tolower(key) == tolower(wanted)) print trim(value)
    }
  ' "$configuration_file"
}

validate_state() {
  local client_count index client_id client_key client_address
  local gateway_address gateway_public_key host_address host_id host_key
  local host_endpoint client_endpoint listen_port client_pool
  local pool_network pool_broadcast address_integer
  local -a unique_values

  jq --exit-status --arg schema "$state_schema" '
    type == "object"
    and (keys | sort) == (
      ["clientEndpoint", "clientPool", "clients", "gateway", "host", "hostEndpoint", "listenPort", "schema"] | sort
    )
    and .schema == $schema
    and (.hostEndpoint | type) == "string"
    and (.clientEndpoint | type) == "string"
    and (.listenPort | type) == "number"
    and (.clientPool | type) == "string"
    and (.gateway | type) == "object"
    and (.gateway | keys | sort) == (["address", "publicKey"] | sort)
    and (.host | type) == "object"
    and (.host | keys | sort) == (["address", "publicKey", "requestId"] | sort)
    and (.clients | type) == "array"
    and all(.clients[];
      type == "object"
      and (keys | sort) == (["address", "publicKey", "requestId"] | sort)
      and (.address | type) == "string"
      and (.publicKey | type) == "string"
      and (.requestId | type) == "string"
    )
  ' <<<"$state_json" >/dev/null || die "the encrypted enrollment state schema is invalid"

  host_endpoint="$(jq --raw-output '.hostEndpoint' <<<"$state_json")"
  client_endpoint="$(jq --raw-output '.clientEndpoint' <<<"$state_json")"
  listen_port="$(jq --raw-output '.listenPort' <<<"$state_json")"
  gateway_address="$(jq --raw-output '.gateway.address' <<<"$state_json")"
  gateway_public_key="$(jq --raw-output '.gateway.publicKey' <<<"$state_json")"
  host_address="$(jq --raw-output '.host.address' <<<"$state_json")"
  host_id="$(jq --raw-output '.host.requestId' <<<"$state_json")"
  host_key="$(jq --raw-output '.host.publicKey' <<<"$state_json")"
  client_pool="$(jq --raw-output '.clientPool' <<<"$state_json")"

  validate_endpoint "$host_endpoint" || die "the encrypted host endpoint is invalid"
  validate_endpoint "$client_endpoint" || die "the encrypted client endpoint is invalid"
  [[ "$listen_port" =~ ^[1-9][0-9]{0,4}$ ]] || die "the encrypted listener port is invalid"
  (( 10#$listen_port >= 1 && 10#$listen_port <= 65535 )) ||
    die "the encrypted listener port is invalid"
  [[ "${host_endpoint##*:}" == "$listen_port" ]] ||
    die "the encrypted host endpoint and listener port differ"
  [[ "${client_endpoint##*:}" == "$listen_port" ]] ||
    die "the encrypted client endpoint and listener port differ"
  validate_exact_ipv4_route "$gateway_address" || die "the encrypted gateway address is invalid"
  validate_exact_ipv4_route "$host_address" || die "the encrypted host address is invalid"
  [[ "$gateway_address" != "$host_address" ]] || die "the gateway and host addresses overlap"
  validate_client_pool "$client_pool" || die "the encrypted client pool must be an aligned IPv4 /28"
  validate_key "$gateway_public_key" || die "the encrypted gateway public key is invalid"
  validate_key "$host_key" || die "the encrypted host public key is invalid"
  validate_request_id "$host_id" || die "the encrypted host request ID is invalid"

  pool_network="$(ipv4_to_integer "${client_pool%/28}")"
  pool_broadcast=$((pool_network + 15))
  for address in "$gateway_address" "$host_address"; do
    address_integer="$(ipv4_to_integer "${address%/32}")"
    if (( address_integer >= pool_network && address_integer <= pool_broadcast )); then
      die "the gateway or host address overlaps the client pool"
    fi
  done

  client_count="$(jq '.clients | length' <<<"$state_json")"
  for ((index = 0; index < client_count; index++)); do
    client_id="$(jq --raw-output ".clients[$index].requestId" <<<"$state_json")"
    client_key="$(jq --raw-output ".clients[$index].publicKey" <<<"$state_json")"
    client_address="$(jq --raw-output ".clients[$index].address" <<<"$state_json")"
    validate_request_id "$client_id" || die "an encrypted client request ID is invalid"
    validate_key "$client_key" || die "an encrypted client public key is invalid"
    validate_exact_ipv4_route "$client_address" || die "an encrypted client address is invalid"
    address_integer="$(ipv4_to_integer "${client_address%/32}")"
    if (( address_integer <= pool_network || address_integer >= pool_broadcast )); then
      die "an encrypted client address is outside the usable /28 pool"
    fi
  done

  mapfile -t unique_values < <(jq --raw-output '
    [.host.requestId] + [.clients[].requestId] | .[]
  ' <<<"$state_json" | sort --unique)
  [[ ${#unique_values[@]} -eq $((client_count + 1)) ]] ||
    die "the encrypted enrollment state repeats a request ID"
  mapfile -t unique_values < <(jq --raw-output '
    [.gateway.publicKey, .host.publicKey] + [.clients[].publicKey] | .[]
  ' <<<"$state_json" | sort --unique)
  [[ ${#unique_values[@]} -eq $((client_count + 2)) ]] ||
    die "the encrypted enrollment state repeats a public key"
  mapfile -t unique_values < <(jq --raw-output '
    [.gateway.address, .host.address] + [.clients[].address] | .[]
  ' <<<"$state_json" | sort --unique)
  [[ ${#unique_values[@]} -eq $((client_count + 2)) ]] ||
    die "the encrypted enrollment state repeats an address"
}

render_configuration() {
  local output_file="$1"
  local metadata gateway_address listen_port host_key host_address
  local client_key client_address

  metadata="$(printf '%s' "$state_json" | base64 --wrap=0)"
  gateway_address="$(jq --raw-output '.gateway.address' <<<"$state_json")"
  listen_port="$(jq --raw-output '.listenPort' <<<"$state_json")"
  host_key="$(jq --raw-output '.host.publicKey' <<<"$state_json")"
  host_address="$(jq --raw-output '.host.address' <<<"$state_json")"

  {
    printf '%s%s\n\n' "$state_marker" "$metadata"
    printf '[Interface]\n'
    printf 'Address = %s\n' "$gateway_address"
    printf 'PrivateKey = %s\n' "$gateway_private_key"
    printf 'ListenPort = %s\n\n' "$listen_port"
    printf '[Peer]\n'
    printf 'PublicKey = %s\n' "$host_key"
    printf 'AllowedIPs = %s\n' "$host_address"
    while IFS=$'\t' read -r client_key client_address; do
      [[ -n "$client_key" ]] || continue
      printf '\n[Peer]\n'
      printf 'PublicKey = %s\n' "$client_key"
      printf 'AllowedIPs = %s\n' "$client_address"
    done < <(
      jq --raw-output '.clients | sort_by(.address)[] | [.publicKey, .address] | @tsv' \
        <<<"$state_json"
    )
  } >"$output_file"
  chmod 0600 "$output_file"
}

load_configuration() {
  local canonical_file="$temporary_directory/canonical.conf"
  local -a private_keys

  if ! sops decrypt \
    --extract "$sops_index" \
    --output "$configuration_file" \
    "$secrets_file" 2>"$temporary_directory/sops-decrypt.log"; then
    return 1
  fi
  chmod 0600 "$configuration_file"
  metadata_from_configuration "$configuration_file"
  validate_state
  mapfile -t private_keys < <(configuration_interface_value "$configuration_file" PrivateKey)
  [[ ${#private_keys[@]} -eq 1 ]] || die "the encrypted gateway private key is missing or repeated"
  gateway_private_key="${private_keys[0]}"
  validate_key "$gateway_private_key" || die "the encrypted gateway private key is malformed"
  [[ "$(printf '%s' "$gateway_private_key" | wg pubkey)" == \
    "$(jq --raw-output '.gateway.publicKey' <<<"$state_json")" ]] ||
    die "the encrypted gateway public and private keys do not match"

  render_configuration "$canonical_file"
  cmp --silent "$configuration_file" "$canonical_file" ||
    die "the encrypted gateway document differs from its canonical enrollment state"
}

configuration_is_declared() {
  grep -Eq '^(gameStreamGatewayConfig:|# caz\.nix-enrollment-state-v1 = )' "$secrets_file"
}

save_configuration() {
  local value_file="$temporary_directory/gateway-value.json"

  render_configuration "$configuration_file"
  jq --raw-input --slurp . "$configuration_file" >"$value_file"
  chmod 0600 "$value_file"
  sops set --value-file "$secrets_file" "$sops_index" "$value_file" >/dev/null ||
    die "SOPS could not update the encrypted gateway document"
}

write_response() {
  local role="$1"
  local id="$2"
  local output_file="$3"
  local address allowed_ips endpoint

  if [[ "$role" == host ]]; then
    address="$(jq --raw-output '.host.address' <<<"$state_json")"
    allowed_ips="$(jq --raw-output '.clientPool' <<<"$state_json")"
    endpoint="$(jq --raw-output '.hostEndpoint' <<<"$state_json")"
  else
    address="$(jq --raw-output --arg id "$id" '
      .clients[] | select(.requestId == $id) | .address
    ' <<<"$state_json")"
    [[ -n "$address" ]] || die "the requested client is not enrolled"
    allowed_ips="$(jq --raw-output '.host.address' <<<"$state_json")"
    endpoint="$(jq --raw-output '.clientEndpoint' <<<"$state_json")"
  fi

  jq --null-input \
    --arg schema "$response_schema" \
    --arg role "$role" \
    --arg requestId "$id" \
    --arg gatewayPublicKey "$(jq --raw-output '.gateway.publicKey' <<<"$state_json")" \
    --arg endpoint "$endpoint" \
    --arg address "$address" \
    --arg allowedIps "$allowed_ips" '
      {
        schema: $schema,
        role: $role,
        requestId: $requestId,
        gatewayPublicKey: $gatewayPublicKey,
        endpoint: $endpoint,
        address: $address,
        allowedIps: $allowedIps,
        persistentKeepalive: 25
      }
    ' >"$output_file"
  chmod 0600 "$output_file"
}

allocate_client_address() {
  local client_pool pool_network pool_broadcast candidate candidate_route

  client_pool="$(jq --raw-output '.clientPool' <<<"$state_json")"
  pool_network="$(ipv4_to_integer "${client_pool%/28}")"
  pool_broadcast=$((pool_network + 15))
  for ((candidate = pool_network + 1; candidate < pool_broadcast; candidate++)); do
    candidate_route="$(integer_to_ipv4 "$candidate")/32"
    if ! jq --exit-status --arg address "$candidate_route" '
      any(.clients[]; .address == $address)
    ' <<<"$state_json" >/dev/null; then
      printf '%s\n' "$candidate_route"
      return 0
    fi
  done
  return 1
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
secrets_file="$repo_root/secrets/homeserver.yaml"
listen_port=51820
request_file=""
request_id_argument=""
output_file=""
host_endpoint=""
client_endpoint=""
gateway_address=""
host_address=""
client_pool=""

[[ $# -ge 1 ]] || usage
action="$1"
shift

case "$action" in
  init-host | add-client)
    [[ $# -ge 1 ]] || usage
    request_file="$1"
    shift
    ;;
  remove-client)
    [[ $# -ge 1 ]] || usage
    request_id_argument="$1"
    shift
    ;;
  status) ;;
  *) usage ;;
esac

while (( $# > 0 )); do
  case "$1" in
    --host-endpoint | --client-endpoint | --gateway-address | --host-address | --client-pool | --output | --listen-port | --secrets-file)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --host-endpoint) host_endpoint="$2" ;;
        --client-endpoint) client_endpoint="$2" ;;
        --gateway-address) gateway_address="$2" ;;
        --host-address) host_address="$2" ;;
        --client-pool) client_pool="$2" ;;
        --output) output_file="$2" ;;
        --listen-port) listen_port="$2" ;;
        --secrets-file) secrets_file="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

require_command base64
require_command cmp
require_command flock
require_command jq
require_command realpath
require_command sops
require_command wg
[[ -f "$secrets_file" ]] || die "the SOPS secrets file is unavailable: $secrets_file"
secrets_file="$(realpath "$secrets_file")"
if [[ -n "$request_file" ]]; then
  request_file="$(realpath "$request_file")"
fi
if [[ -n "$output_file" ]]; then
  output_file="$(realpath --canonicalize-missing "$output_file")"
  [[ "$output_file" != "$secrets_file" && "$output_file" != "$request_file" ]] ||
    die "the response output must not overwrite an input or the SOPS secrets file"
fi

umask 077
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/caz-game-stream-enrollment.XXXXXX")"
configuration_file="$temporary_directory/gateway.conf"
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

lock_digest="$(printf '%s' "$secrets_file" | sha256sum | cut -d ' ' -f 1)"
exec 9>"${TMPDIR:-/tmp}/caz-game-stream-enrollment-${lock_digest}.lock"
flock --exclusive 9

case "$action" in
  init-host)
    [[ -n "$output_file" && -n "$host_endpoint" && -n "$client_endpoint" && -n "$gateway_address" && -n "$host_address" && -n "$client_pool" ]] || usage
    [[ "$listen_port" =~ ^[1-9][0-9]{0,4}$ ]] || die "the listener port is invalid"
    (( 10#$listen_port >= 1 && 10#$listen_port <= 65535 )) || die "the listener port is invalid"
    validate_endpoint "$host_endpoint" || die "the host endpoint must be LAN_HOST:PORT"
    validate_endpoint "$client_endpoint" || die "the client endpoint must be PUBLIC_HOST:PORT"
    [[ "${host_endpoint##*:}" == "$listen_port" ]] || die "the host endpoint and listener port must match"
    [[ "${client_endpoint##*:}" == "$listen_port" ]] || die "the client endpoint and listener port must match"
    validate_exact_ipv4_route "$gateway_address" || die "the gateway address must be one IPv4 /32"
    validate_exact_ipv4_route "$host_address" || die "the host address must be one IPv4 /32"
    [[ "$gateway_address" != "$host_address" ]] || die "the gateway and host addresses must differ"
    validate_client_pool "$client_pool" || die "the client pool must be one aligned IPv4 /28"
    parse_request "$request_file" host

    if configuration_is_declared; then
      load_configuration || die "SOPS could not decrypt the existing gateway configuration"
      jq --exit-status \
        --arg hostEndpoint "$host_endpoint" \
        --arg clientEndpoint "$client_endpoint" \
        --argjson listenPort "$listen_port" \
        --arg gatewayAddress "$gateway_address" \
        --arg hostAddress "$host_address" \
        --arg clientPool "$client_pool" \
        --arg requestId "$request_id" \
        --arg publicKey "$request_public_key" '
          .hostEndpoint == $hostEndpoint
          and .clientEndpoint == $clientEndpoint
          and .listenPort == $listenPort
          and .gateway.address == $gatewayAddress
          and .host.address == $hostAddress
          and .clientPool == $clientPool
          and .host.requestId == $requestId
          and .host.publicKey == $publicKey
        ' <<<"$state_json" >/dev/null ||
        die "init-host differs from the existing encrypted gateway state"
    else
      gateway_private_key="$(wg genkey)"
      validate_key "$gateway_private_key" || die "wg generated a malformed gateway private key"
      gateway_public_key="$(printf '%s' "$gateway_private_key" | wg pubkey)"
      validate_key "$gateway_public_key" || die "wg generated a malformed gateway public key"
      state_json="$(jq --compact-output --sort-keys --null-input \
        --arg schema "$state_schema" \
        --arg hostEndpoint "$host_endpoint" \
        --arg clientEndpoint "$client_endpoint" \
        --argjson listenPort "$listen_port" \
        --arg gatewayAddress "$gateway_address" \
        --arg gatewayPublicKey "$gateway_public_key" \
        --arg hostAddress "$host_address" \
        --arg hostRequestId "$request_id" \
        --arg hostPublicKey "$request_public_key" \
        --arg clientPool "$client_pool" '
          {
            schema: $schema,
            hostEndpoint: $hostEndpoint,
            clientEndpoint: $clientEndpoint,
            listenPort: $listenPort,
            gateway: {address: $gatewayAddress, publicKey: $gatewayPublicKey},
            host: {
              address: $hostAddress,
              requestId: $hostRequestId,
              publicKey: $hostPublicKey
            },
            clientPool: $clientPool,
            clients: []
          }
        ')"
      validate_state
      save_configuration
    fi
    write_response host "$request_id" "$output_file"
    echo "Host enrollment is ready at $output_file. Add at least one client before the remote pilot."
    ;;

  add-client)
    [[ -n "$output_file" ]] || usage
    parse_request "$request_file" client
    load_configuration || die "initialize the host before adding a client"

    existing_client_count="$(jq --arg id "$request_id" '
      [.clients[] | select(.requestId == $id)] | length
    ' <<<"$state_json")"
    if (( existing_client_count == 1 )); then
      [[ "$(jq --raw-output --arg id "$request_id" '
        .clients[] | select(.requestId == $id) | .publicKey
      ' <<<"$state_json")" == "$request_public_key" ]] ||
        die "the existing request ID belongs to a different public key"
    else
      if jq --exit-status --arg key "$request_public_key" '
        .host.publicKey == $key or any(.clients[]; .publicKey == $key)
      ' <<<"$state_json" >/dev/null; then
        die "the public key is already enrolled under another request ID"
      fi
      allocated_address="$(allocate_client_address)" || die "the client /28 pool is full"
      state_json="$(jq --compact-output --sort-keys \
        --arg requestId "$request_id" \
        --arg publicKey "$request_public_key" \
        --arg address "$allocated_address" '
          .clients += [{requestId: $requestId, publicKey: $publicKey, address: $address}]
          | .clients |= sort_by(.address)
        ' <<<"$state_json")"
      validate_state
      save_configuration
    fi
    write_response client "$request_id" "$output_file"
    echo "Client enrollment is ready at $output_file."
    ;;

  remove-client)
    validate_request_id "$request_id_argument" || die "the client request ID is malformed"
    load_configuration || die "initialize the host before removing a client"
    if jq --exit-status --arg id "$request_id_argument" '
      any(.clients[]; .requestId == $id)
    ' <<<"$state_json" >/dev/null; then
      state_json="$(jq --compact-output --sort-keys --arg id "$request_id_argument" '
        .clients |= map(select(.requestId != $id))
      ' <<<"$state_json")"
      validate_state
      save_configuration
      echo "Removed client request $request_id_argument from the encrypted gateway state."
    else
      echo "Client request $request_id_argument is already absent."
    fi
    echo "Also remove that device from Sunshine's paired clients before considering revocation complete."
    ;;

  status)
    load_configuration || die "the game-stream gateway has not been initialized"
    echo "Host request: $(jq --raw-output '.host.requestId' <<<"$state_json")"
    echo "Enrolled clients: $(jq '.clients | length' <<<"$state_json")"
    jq --raw-output '.clients[] | "  - " + .requestId' <<<"$state_json"
    ;;
esac
