#!/usr/bin/env bash
# setup.sh — One-command bootstrap for the OpenEMS Docker stack.
# Safe to run on a fresh clone or after destroying all containers/images/volumes.
# Idempotent: skips steps that are already done.
#
# Usage:
#   ./setup.sh          # full setup (build + init + verify)
#   ./setup.sh --skip-build   # skip docker compose build (images already exist)

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
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    *) err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# Expected edge apikey — must match openems-edge/config.d/Controller/Api/Backend/*.config
EDGE_APIKEY="E3SZ5xdJ2FJ0jPMtajdm"
# Odoo password — must match openems-backend/config.d/Metadata/Odoo.config (odooPassword)
ODOO_PASSWORD="Icui4cyou"

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

# ── Step 4: Verify edge device registration ───────────────────────────
EDGE_KEY=$(docker compose exec -T db psql -U odoo -d openems -tAc \
  "SELECT apikey FROM openems_device WHERE name='edge0'" 2>/dev/null | tr -d '[:space:]' || echo "")

if [ -z "$EDGE_KEY" ]; then
  warn "Edge device 'edge0' not found in database."
  warn "Demo data may not have loaded. Creating edge device..."
  docker compose exec -T db psql -U odoo -d openems -c \
    "INSERT INTO openems_device (name, apikey, comment, create_uid, create_date, write_uid, write_date)
     VALUES ('edge0', '$EDGE_APIKEY', 'OpenEMS Edge #0', 1, NOW(), 1, NOW());"
  log "Edge device created."
elif [ "$EDGE_KEY" != "$EDGE_APIKEY" ]; then
  warn "Edge apikey mismatch: DB='$EDGE_KEY', expected='$EDGE_APIKEY'"
  warn "Updating database to match edge config..."
  docker compose exec -T db psql -U odoo -d openems -c \
    "UPDATE openems_device SET apikey='$EDGE_APIKEY' WHERE name='edge0';"
  log "Edge apikey updated."
else
  log "Edge device 'edge0' registered with correct apikey."
fi

# ── Step 5: Verify required config files ──────────────────────────────
if [ ! -f "openems-edge/config.d/Timedata/Rrd4j.config" ]; then
  err "Missing openems-edge/config.d/Timedata/Rrd4j.config — Edge needs RRD4j for energy channel calculation"
  exit 1
fi
log "RRD4j Timedata config verified."

# ── Step 6: Start the full stack ──────────────────────────────────────
log "Starting all services..."
docker compose up -d

# The edge doesn't auto-reconnect quickly if it started before the backend
# was ready. Restart it to ensure a clean connection.
log "Restarting edge to ensure backend connection..."
sleep 5
docker compose restart openems-edge

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
  check_logs openems-edge    "Scheduler"               || PASS=false
  check_logs openems-backend "Edge.Websocket"          || PASS=false

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
  log "  Edge scheduler:       OK"
  log "  Edge -> Backend:      OK"
  log ""
  log "All checks passed!"
else
  check_logs openems-backend "Caching Edges.*finished" && log "  Backend -> Postgres:  OK" || warn "  Backend -> Postgres:  FAILED"
  check_logs openems-backend "InfluxDB"                && log "  Backend -> InfluxDB:  OK" || warn "  Backend -> InfluxDB:  FAILED"
  check_logs openems-edge    "Scheduler"               && log "  Edge scheduler:       OK" || warn "  Edge scheduler:       FAILED"
  check_logs openems-backend "Edge.Websocket"          && log "  Edge -> Backend:      OK" || warn "  Edge -> Backend:      FAILED"
  log ""
  warn "Some checks failed after 2 minutes."
  warn "Check logs: docker compose logs --tail=50 openems-backend openems-edge"
fi

log ""
log "Stack is ready:"
log "  OpenEMS UI:      http://localhost:4200"
log "  Odoo:            http://localhost:10016"
log "  Felix Console:   http://localhost:8080"
log "  InfluxDB:        http://localhost:8086"
log ""
log "Default credentials:"
log "  OpenEMS UI:  admin / Icui4cyou"
log "  Odoo:        admin / Icui4cyou  (master pw: openemspassword)"
