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

for value in \
  BACKEND_IMAGE UI_IMAGE OPENEMS_DOMAIN EDGE_DOMAIN ACME_EMAIL \
  KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD \
  KEYCLOAK_CLIENT_SECRET OPENEMS_ADMIN_PASSWORD \
  INFLUXDB_USERNAME INFLUXDB_PASSWORD INFLUXDB_TOKEN; do
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
docker compose up -d --remove-orphans --wait --wait-timeout 360

# FileInstall watches the Backend config volume. Generate the OAuth files inside
# the container so the Keycloak client secret never needs to live in Git.
docker compose exec -T \
  -e KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET" \
  -e OPENEMS_DOMAIN="$OPENEMS_DOMAIN" \
  backend sh -eu -c '
    config_dir=/var/opt/openems/config
    oauth_dir="$config_dir/Authentication/OAuth"
    client_dir="$oauth_dir/ClientConfig"
    mkdir -p "$client_dir"
    cat > "$oauth_dir.config" <<EOF
realm="openems"
baseKeycloakUrl="http://keycloak:8080"
issuerUrl="http://keycloak:8080/realms/openems"
loginUrl="http://keycloak:8080/realms/openems/protocol/openid-connect/auth"
tokenUrl="http://keycloak:8080/realms/openems/protocol/openid-connect/token"
certsUrl="http://keycloak:8080/realms/openems/protocol/openid-connect/certs"
rateLimitedBucketSize=I"10"
rateLimitedRefillRate=I"1"
maxConcurrentRequests=I"10"
debugMode="OFF"
service.pid="Authentication.OAuth"
EOF
    {
      printf "%s\n" \
        "oem=\"openems\"" \
        "clientId=\"openems\"" \
        "clientSecret=\"$KEYCLOAK_CLIENT_SECRET\"" \
        "redirectUri=\"https://$OPENEMS_DOMAIN/\"" \
        "serviceAccount=B\"true\"" \
        "service.factoryPid=\"Authentication.OAuth.ClientConfig\"" \
        "service.pid=\"Authentication.OAuth.ClientConfig.openems\""
    } > "$client_dir/openems.config"
    chmod 600 \
      "$oauth_dir.config" \
      "$client_dir/openems.config"
    chown 1000:1000 \
      "$oauth_dir.config" \
      "$client_dir/openems.config"
    chown 1000:1000 "$config_dir/Authentication" "$oauth_dir" "$client_dir"
    rm -f \
      "$config_dir/Authentication.OAuth.config" \
      "$config_dir/Authentication.OAuth.ClientConfig~openems.config" \
      "$oauth_dir/ClientConfig~openems.config"
  '

"$SCRIPT_DIR/check.sh"

echo "Deployment completed: $BACKEND_IMAGE / $UI_IMAGE"
