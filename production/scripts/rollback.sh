#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$DEPLOY_DIR"

if [[ ! -f .previous-release ]]; then
  echo "No .previous-release file is available." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
# shellcheck disable=SC1091
source .previous-release
set +a

sed -i.bak \
  -e "s|^BACKEND_IMAGE=.*|BACKEND_IMAGE=$BACKEND_IMAGE|" \
  -e "s|^UI_IMAGE=.*|UI_IMAGE=$UI_IMAGE|" .env
rm -f .env.bak

docker compose config --quiet
docker compose pull backend ui
docker compose up -d --remove-orphans --wait --wait-timeout 180
"$SCRIPT_DIR/check.sh"

echo "Rolled back to: $BACKEND_IMAGE / $UI_IMAGE"
