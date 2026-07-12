#!/bin/bash
# OpenEMS backend entrypoint.
#
# Renders the Felix configs that carry environment-specific values
# (database endpoints, credentials) from environment variables before
# starting the JVM. Defaults match the local docker-compose stack, so
# running without any env set behaves exactly as before. ECS injects
# the RDS endpoint and Secrets Manager credentials through the same
# variables.
set -euo pipefail

CONFIG_DIR=/opt/openems-backend/config.d

# ── Defaults = local docker-compose values ────────────────────────────
DB_HOST="${DB_HOST:-db}"
DB_NAME="${DB_NAME:-openems}"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-Icui4cyou}"
ODOO_HOST="${ODOO_HOST:-odoo16}"
ODOO_PORT="${ODOO_PORT:-8069}"
ODOO_PASSWORD="${ODOO_PASSWORD:-$DB_PASSWORD}"
INFLUX_URL="${INFLUX_URL:-http://influxdb:8086}"
INFLUX_APIKEY="${INFLUX_APIKEY:-root:root}"
INFLUX_BUCKET="${INFLUX_BUCKET:-openemsdb/autogen}"

# Escape a value for use in a sed replacement (\, & and the | delimiter),
# and escape double quotes for the Felix .config quoted-string format.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g' -e 's/"/\\\\"/g'; }

render() { # render <file> <key> <value>  — rewrites key="..." in a .config
  sed -i "s|^${2}=\"[^\"]*\"|${2}=\"$(esc "$3")\"|" "$1"
}

ODOO_CONFIG="$CONFIG_DIR/Metadata/Odoo.config"
render "$ODOO_CONFIG" pgHost        "$DB_HOST"
render "$ODOO_CONFIG" pgUser        "$DB_USER"
render "$ODOO_CONFIG" pgPassword    "$DB_PASSWORD"
render "$ODOO_CONFIG" database      "$DB_NAME"
render "$ODOO_CONFIG" odooHost      "$ODOO_HOST"
render "$ODOO_CONFIG" odooPassword  "$ODOO_PASSWORD"
sed -i "s|^odooPort=I\"[^\"]*\"|odooPort=I\"${ODOO_PORT}\"|" "$ODOO_CONFIG"

INFLUX_CONFIG="$CONFIG_DIR/Timedata/InfluxDB/timedata0.config"
render "$INFLUX_CONFIG" url    "$INFLUX_URL"
render "$INFLUX_CONFIG" apiKey "$INFLUX_APIKEY"
render "$INFLUX_CONFIG" bucket "$INFLUX_BUCKET"

echo "[entrypoint] Rendered backend config: pgHost=${DB_HOST} odooHost=${ODOO_HOST} influx=${INFLUX_URL}"

exec /usr/bin/java -XX:+ExitOnOutOfMemoryError \
  -Dfelix.cm.dir="$CONFIG_DIR" \
  -Djava.util.concurrent.ForkJoinPool.common.parallelism=100 \
  -jar /opt/openems-backend/openems-backend.jar
