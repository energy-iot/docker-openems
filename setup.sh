#!/usr/bin/env bash
# setup.sh — One-command bootstrap for the OpenEMS Docker stack.
# Safe to run on a fresh clone or after destroying all containers/images/volumes.
# Idempotent: skips steps that are already done.
#
# Usage:
#   ./setup.sh                    # full setup, 1 edge (default)
#   ./setup.sh --edges 3          # full setup with 3 simulated edges
#   ./setup.sh --skip-build       # skip docker compose build (images already exist)
#   ./setup.sh --edges 3 --skip-build

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*" >&2; }

SKIP_BUILD=false
EDGE_COUNT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --edges)
      if [ -z "${2:-}" ]; then
        err "--edges requires a numeric argument"
        exit 1
      fi
      EDGE_COUNT="$2"
      shift 2
      ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# Validate --edges value
if ! [[ "$EDGE_COUNT" =~ ^[0-9]+$ ]] || [ "$EDGE_COUNT" -lt 1 ]; then
  err "--edges must be a positive integer (got: $EDGE_COUNT)"
  exit 1
fi
if [ "$EDGE_COUNT" -gt 9 ]; then
  err "--edges supports up to 9 edges (port scheme 8{i}80/8{i}85 collides at 10)"
  exit 1
fi

# Odoo password — must match openems-backend/config.d/Metadata/Odoo.config (odooPassword)
ODOO_PASSWORD="Icui4cyou"
# Template directory for edge configs
EDGE_TEMPLATE_DIR="openems-edge/config.d"

# ── Helper: generate random 20-char alphanumeric API key ──────────────
generate_apikey() {
  # Matches Odoo model format: 20 chars from [a-zA-Z0-9]
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20
}

# ── Helper: portable in-place sed (macOS vs GNU) ─────────────────────
# macOS sed requires -i '' while GNU sed requires -i without argument.
sedi() {
  if sed --version >/dev/null 2>&1; then
    # GNU sed
    sed -i "$@"
  else
    # macOS/BSD sed
    sed -i '' "$@"
  fi
}

# ── Helper: generate a new UUID ───────────────────────────────────────
generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # Fallback using /proc/sys/kernel/random/uuid (Linux)
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
      python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

# ── Helper: generate per-edge config directory from template ──────────
# Copies the template, regenerates UUIDs for factory configs, updates
# service.pid values and LDAP target filters, and writes the apikey.
#
# Args: $1 = edge index (0, 1, ...), $2 = apikey for this edge
generate_edge_config() {
  local edge_idx="$1"
  local apikey="$2"
  local dest_dir="openems-edge/config-edge${edge_idx}"

  # Clean and copy template
  rm -rf "$dest_dir"
  cp -R "$EDGE_TEMPLATE_DIR" "$dest_dir"

  # Process each .config file
  while IFS= read -r -d '' config_file; do
    local rel_path="${config_file#${dest_dir}/}"
    local filename
    filename=$(basename "$config_file" .config)
    local dir_path
    dir_path=$(dirname "$config_file")

    # Determine if this is a UUID-named factory config
    # UUID pattern: 8-4-4-4-12 hex chars
    if [[ "$filename" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      local old_uuid="$filename"
      local new_uuid
      new_uuid=$(generate_uuid)

      # Read the actual service.pid from the file to get the correct prefix
      # (directory casing may differ from PID casing, e.g. Controller/IO vs Controller.Io)
      local old_pid
      old_pid=$(grep '^service\.pid=' "$config_file" | sed 's/service\.pid="//' | sed 's/"$//')
      local pid_prefix="${old_pid%.${old_uuid}}"
      local new_pid="${pid_prefix}.${new_uuid}"

      # Update service.pid in the file
      sedi "s|service\\.pid=\"${old_pid}\"|service.pid=\"${new_pid}\"|g" "$config_file"

      # Update LDAP target filters that reference the old PID
      # These appear in Component.target and datasource.target properties
      # The PID is embedded with escaped equals: service.pid\=Old.Pid.uuid
      sedi "s|service\\.pid\\\\=${old_pid}|service.pid\\\\=${new_pid}|g" "$config_file"

      # Rename the file to match the new UUID
      mv "$config_file" "${dir_path}/${new_uuid}.config"

    elif [ "$filename" = "rrd4j0" ]; then
      # Timedata/Rrd4j/rrd4j0.config — component-id filename, copy as-is
      :
    else
      # Non-factory configs (logging, Felix bindings) — copy as-is
      :
    fi
  done < <(find "$dest_dir" -name "*.config" -type f -print0)

  # Write the apikey into the Backend config
  local backend_config
  backend_config=$(find "$dest_dir/Controller/Api/Backend" -name "*.config" -type f | head -1)
  if [ -n "$backend_config" ]; then
    sedi "s|apikey=\"[^\"]*\"|apikey=\"${apikey}\"|" "$backend_config"
  else
    err "Backend config not found in $dest_dir"
    exit 1
  fi

  log "  Edge ${edge_idx}: config generated at ${dest_dir}"
}

# ── Helper: generate docker-compose.override.yml ──────────────────────
generate_compose_override() {
  local override_file="docker-compose.override.yml"
  log "Generating ${override_file} for ${EDGE_COUNT} edge(s)..."

  cat > "$override_file" <<'HEADER'
# Generated by setup.sh — do not edit manually.
# This file is auto-merged by docker compose with docker-compose.yml.
services:
  # Disable the default single-edge service from docker-compose.yml
  openems-edge:
    profiles: ["disabled"]
HEADER

  for i in $(seq 0 $((EDGE_COUNT - 1))); do
    local felix_port="8${i}80"
    local ws_port="8${i}85"

    cat >> "$override_file" <<EOF

  openems-edge-${i}:
    image: openems-edge:latest
    ports:
      - "${felix_port}:8080"
      - "${ws_port}:8085"
    volumes:
      - ./openems-edge/config-edge${i}:/etc/openems.d
EOF
  done

  log "  Override file written: ${override_file}"
}

# ── Step 0: Generate edge configs and compose override ────────────────
log "Configuring ${EDGE_COUNT} edge instance(s)..."

# Generate apikeys and config dirs for each edge
declare -a EDGE_APIKEYS=()
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  EDGE_APIKEYS+=("$(generate_apikey)")
done

for i in $(seq 0 $((EDGE_COUNT - 1))); do
  generate_edge_config "$i" "${EDGE_APIKEYS[$i]}"
done

generate_compose_override

# ── Step 1: Build images ─────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
  log "Building Docker images..."
  docker compose build
else
  log "Skipping build (--skip-build)"
fi

# ── Step 2: Start infrastructure (db + influxdb) ─────────────────────
log "Starting database services..."
docker compose up -d db influxdb

log "Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
  if docker compose exec -T db pg_isready -U odoo >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    err "Postgres did not become ready in 60 seconds."
    exit 1
  fi
  sleep 2
done
log "Postgres is ready."

# ── Step 3: Initialize Odoo database (if needed) ─────────────────────
DB_EXISTS=$(docker compose exec -T db psql -U odoo -tAc \
  "SELECT 1 FROM pg_database WHERE datname='openems'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
  log "Odoo database 'openems' already exists — skipping initialization."
else
  log "Creating Odoo database and installing OpenEMS module..."
  log "(This installs Odoo + CRM + Stock + OpenEMS. Takes 2-4 minutes.)"

  docker compose run --rm odoo16 odoo \
    -d openems \
    -i openems \
    --stop-after-init

  log "Odoo database created and OpenEMS module installed."

  # Set Odoo passwords to match backend Metadata/Odoo.config.
  # The CLI creates admin with password 'admin', but the backend expects
  # odooPassword for XML-RPC calls (used for UI user authentication).
  log "Setting Odoo passwords to match backend config..."
  docker compose up -d odoo16
  sleep 5
  docker compose exec -T odoo16 python3 -c "
import xmlrpc.client
url = 'http://localhost:8069'
db = 'openems'
uid = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/common').authenticate(db, 'admin', 'admin', {})
models = xmlrpc.client.ServerProxy(f'{url}/xmlrpc/2/object')
models.execute_kw(db, uid, 'admin', 'res.users', 'write', [[uid], {'password': '$ODOO_PASSWORD'}])
models.execute_kw(db, uid, '$ODOO_PASSWORD', 'res.users', 'write', [[1], {'password': '$ODOO_PASSWORD'}])
print('Odoo passwords updated')
"
  docker compose stop odoo16
fi

# ── Step 4: Register edge devices in database ─────────────────────────
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  EDGE_NAME="edge${i}"
  EDGE_APIKEY="${EDGE_APIKEYS[$i]}"

  EDGE_KEY=$(docker compose exec -T db psql -U odoo -d openems -tAc \
    "SELECT apikey FROM openems_device WHERE name='${EDGE_NAME}'" 2>/dev/null | tr -d '[:space:]' || echo "")

  if [ -z "$EDGE_KEY" ]; then
    warn "Edge device '${EDGE_NAME}' not found in database. Creating..."
    docker compose exec -T db psql -U odoo -d openems -c \
      "INSERT INTO openems_device (name, apikey, comment, create_uid, create_date, write_uid, write_date)
       VALUES ('${EDGE_NAME}', '${EDGE_APIKEY}', 'OpenEMS Edge #${i}', 1, NOW(), 1, NOW());"
    log "  ${EDGE_NAME} created with apikey ${EDGE_APIKEY}"
  elif [ "$EDGE_KEY" != "$EDGE_APIKEY" ]; then
    warn "Edge '${EDGE_NAME}' apikey mismatch: DB='${EDGE_KEY}', config='${EDGE_APIKEY}'"
    warn "Updating database to match generated config..."
    docker compose exec -T db psql -U odoo -d openems -c \
      "UPDATE openems_device SET apikey='${EDGE_APIKEY}' WHERE name='${EDGE_NAME}';"
    log "  ${EDGE_NAME} apikey updated."
  else
    log "  ${EDGE_NAME} registered with correct apikey."
  fi
done

# ── Step 5: Validate Edge configs ─────────────────────────────────────
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  config_dir="openems-edge/config-edge${i}"
  if ! ls "${config_dir}/Timedata/Rrd4j/"*.config 1>/dev/null 2>&1; then
    err "Missing ${config_dir}/Timedata/Rrd4j/*.config — Edge needs RRD4j for energy channel calculation"
    exit 1
  fi
  if ! ls "${config_dir}/Controller/Api/Backend/"*.config 1>/dev/null 2>&1; then
    err "Missing ${config_dir}/Controller/Api/Backend/*.config — Edge needs Backend controller"
    exit 1
  fi
done
log "Edge configs validated for ${EDGE_COUNT} edge(s)."

# ── Step 6: Start the full stack ──────────────────────────────────────
log "Starting all services..."
docker compose up -d

# The edges don't auto-reconnect quickly if they started before the backend
# was ready. Restart them to ensure clean connections.
log "Restarting edge(s) to ensure backend connection..."
sleep 5
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  docker compose restart "openems-edge-${i}"
done

# ── Step 7: Verify the stack (retry loop) ─────────────────────────────
log "Waiting for services to start..."

check_logs() {
  local service="$1"
  local pattern="$2"
  local logs
  logs=$(docker compose logs "$service" 2>/dev/null)
  echo "$logs" | grep -q "$pattern"
}

CHECKS_PASSED=false
for attempt in $(seq 1 12); do
  sleep 10
  PASS=true

  check_logs openems-backend "Caching Edges.*finished" || PASS=false
  check_logs openems-backend "InfluxDB"                || PASS=false
  check_logs openems-backend "Edge.Websocket"          || PASS=false

  for i in $(seq 0 $((EDGE_COUNT - 1))); do
    check_logs "openems-edge-${i}" "Scheduler" || PASS=false
    check_logs "openems-edge-${i}" "Rrd4j"     || PASS=false
  done

  if [ "$PASS" = true ]; then
    CHECKS_PASSED=true
    break
  fi
  log "  Waiting... (${attempt}/12)"
done

log ""
log "=== Verification ==="
if [ "$CHECKS_PASSED" = true ]; then
  log "  Backend -> Postgres:  OK"
  log "  Backend -> InfluxDB:  OK"
  log "  Backend websocket:    OK"
  for i in $(seq 0 $((EDGE_COUNT - 1))); do
    log "  Edge ${i} scheduler:    OK"
    log "  Edge ${i} RRD4j:        OK"
  done
  log ""
  log "All checks passed!"
else
  check_logs openems-backend "Caching Edges.*finished" && log "  Backend -> Postgres:  OK" || warn "  Backend -> Postgres:  FAILED"
  check_logs openems-backend "InfluxDB"                && log "  Backend -> InfluxDB:  OK" || warn "  Backend -> InfluxDB:  FAILED"
  check_logs openems-backend "Edge.Websocket"          && log "  Backend websocket:    OK" || warn "  Backend websocket:    FAILED"
  for i in $(seq 0 $((EDGE_COUNT - 1))); do
    check_logs "openems-edge-${i}" "Scheduler" && log "  Edge ${i} scheduler:    OK" || warn "  Edge ${i} scheduler:    FAILED"
    check_logs "openems-edge-${i}" "Rrd4j"     && log "  Edge ${i} RRD4j:        OK" || warn "  Edge ${i} RRD4j:        FAILED"
  done
  log ""
  warn "Some checks failed after 2 minutes."
  warn "Check logs: docker compose logs --tail=50 openems-backend"
  for i in $(seq 0 $((EDGE_COUNT - 1))); do
    warn "  docker compose logs --tail=50 openems-edge-${i}"
  done
fi

log ""
log "Stack is ready (${EDGE_COUNT} edge(s)):"
log "  OpenEMS UI:      http://localhost:4200"
log "  Odoo:            http://localhost:10016"
log "  InfluxDB:        http://localhost:8086"
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  log "  Edge ${i} Felix:    http://localhost:8${i}80"
  log "  Edge ${i} WS:       ws://localhost:8${i}85"
done
log ""
log "Default credentials:"
log "  OpenEMS UI:  admin / Icui4cyou"
log "  Odoo:        admin / Icui4cyou  (master pw: openemspassword)"
log ""
log "Edge API keys:"
for i in $(seq 0 $((EDGE_COUNT - 1))); do
  log "  edge${i}: ${EDGE_APIKEYS[$i]}"
done
