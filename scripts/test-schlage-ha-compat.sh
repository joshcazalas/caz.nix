#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"
read -r _ image < containers/home-assistant/Dockerfile

tar -cf - tests/schlage_ha_compat.py home-assistant/custom_components/schlage_local |
  docker run --rm -i --network none --read-only --tmpfs /tmp \
    --workdir /tmp --entrypoint /bin/sh "${image}" \
    -ec 'tar -xf - && exec python -B tests/schlage_ha_compat.py -v'
