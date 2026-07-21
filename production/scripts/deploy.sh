#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$DEPLOY_DIR"

if [[ ! -f .env ]]; then
  echo "Missing $DEPLOY_DIR/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for value in BACKEND_IMAGE UI_IMAGE OPENEMS_DOMAIN EDGE_DOMAIN ACME_EMAIL INFLUXDB_USERNAME INFLUXDB_PASSWORD INFLUXDB_TOKEN; do
  if [[ -z "${!value:-}" ]]; then
    echo "Missing required value: $value" >&2
    exit 1
  fi
done

if [[ "$BACKEND_IMAGE" != *@sha256:* || "$UI_IMAGE" != *@sha256:* ]]; then
  echo "BACKEND_IMAGE and UI_IMAGE must be pinned by sha256 digest." >&2
  exit 1
fi

docker compose config --quiet

if [[ -f .current-release ]]; then
  cp .current-release .previous-release
fi
printf 'BACKEND_IMAGE=%q\nUI_IMAGE=%q\n' "$BACKEND_IMAGE" "$UI_IMAGE" > .current-release

docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 180
"$SCRIPT_DIR/check.sh"

echo "Deployment completed: $BACKEND_IMAGE / $UI_IMAGE"
