#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
usage: caz-server-health [--wait SECONDS] [--stabilize SECONDS]

Check every service required by the current homeserver configuration.

  --wait SECONDS       wait up to this long for all checks to become healthy
  --stabilize SECONDS  require checks to stay healthy for this long afterward
EOF
}

wait_seconds=0
stabilization_seconds=0

while (( $# > 0 )); do
  case "$1" in
    --wait)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      wait_seconds="$2"
      shift 2
      ;;
    --stabilize)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      stabilization_seconds="$2"
      shift 2
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
done

for value in "$wait_seconds" "$stabilization_seconds"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Health-check durations must be non-negative integer seconds." >&2
    exit 2
  fi
done

declare -a failures=()

check_systemd_unit() {
  local unit="$1"

  if ! systemctl is-active --quiet "$unit"; then
    failures+=("systemd:$unit")
  fi
}

check_http() {
  local name="$1"
  local url="$2"
  local status

  status="$(curl \
    --silent \
    --show-error \
    --max-time 5 \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$url" 2>/dev/null || true)"

  # A redirect or authentication response still proves that the intended HTTP
  # application is accepting and processing requests. Server errors do not.
  if [[ ! "$status" =~ ^[234][0-9][0-9]$ ]]; then
    failures+=("http:$name")
  fi
}

check_once() {
  failures=()

  for unit in ${CAZ_HEALTH_REQUIRED_UNITS:-}; do
    check_systemd_unit "$unit"
  done

  for unit in ${CAZ_HEALTH_REQUIRED_SOCKETS:-}; do
    check_systemd_unit "$unit"
  done

  for endpoint in ${CAZ_HEALTH_HTTP_ENDPOINTS:-}; do
    check_http "${endpoint%%=*}" "${endpoint#*=}"
  done

  if [[ "${CAZ_HEALTH_CHECK_DNS:-false}" == true ]]; then
    if ! dig \
      +time=3 \
      +tries=1 \
      @127.0.0.1 \
      example.com \
      A 2>/dev/null \
      | grep --quiet 'status: NOERROR'; then
      failures+=("dns:adguardhome")
    fi
  fi

  if [[ "${CAZ_HEALTH_CHECK_MINECRAFT:-false}" == true ]]; then
    if [[ "$(docker inspect --format '{{.State.Running}}' minecraft 2>/dev/null || true)" != true ]] \
      || ! docker exec minecraft rcon-cli list >/dev/null 2>&1; then
      failures+=("minecraft:rcon")
    fi
  fi

  if (( ${#failures[@]} > 0 )); then
    printf 'Unhealthy checks: %s\n' "$(IFS=,; echo "${failures[*]}")" >&2
    return 1
  fi

  return 0
}

wait_for_health() {
  local timeout="$1"
  local deadline=$((SECONDS + timeout))

  while ! check_once; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 10
  done
}

if ! wait_for_health "$wait_seconds"; then
  echo "The homeserver did not become healthy within ${wait_seconds} seconds." >&2
  exit 1
fi

# A single failed sample is not a failed deployment. Every check above is a
# point-in-time probe, and the DNS one leaves the machine entirely, so any of
# them can miss for reasons the release under test had no part in. Confirm a
# failure before rolling back on it: whatever is genuinely broken is still
# broken a few seconds later, and a blip is not.
stabilization_recheck_seconds=5

if (( stabilization_seconds > 0 )); then
  echo "All checks passed; observing a ${stabilization_seconds}-second stabilization window."
  stabilization_deadline=$((SECONDS + stabilization_seconds))

  while (( SECONDS < stabilization_deadline )); do
    sleep 10

    check_once && continue

    echo "Re-checking in ${stabilization_recheck_seconds}s before calling that a failure." >&2
    sleep "$stabilization_recheck_seconds"

    if ! check_once; then
      echo "A homeserver check failed twice during the stabilization window." >&2
      exit 1
    fi
  done
fi

echo "All homeserver health checks passed."
