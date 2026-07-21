#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$DEPLOY_DIR"

docker compose ps

unhealthy="$(docker compose ps --format json | jq -r 'select(.Health != "" and .Health != "healthy") | .Service' || true)"
if [[ -n "$unhealthy" ]]; then
  echo "Unhealthy services: $unhealthy" >&2
  exit 1
fi

curl --fail --silent --show-error --max-time 15 "https://${OPENEMS_DOMAIN}/" >/dev/null
# The Edge endpoint may reject a GET without an Edge API key. A completed TLS/HTTP
# exchange is sufficient here; authenticated WebSocket registration is an acceptance test.
curl --silent --show-error --max-time 15 "https://${EDGE_DOMAIN}/" >/dev/null

echo "OpenEMS pilot health checks passed."
