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

# ── Step 5: Start the full stack ──────────────────────────────────────
log "Starting all services..."
docker compose up -d

# ── Step 6: Wait for services to stabilize ────────────────────────────
log "Waiting for services to start (20s)..."
sleep 20

# ── Step 7: Verify the stack ──────────────────────────────────────────
log ""
log "=== Verification ==="

PASS=true

# Backend → Postgres
if docker compose logs openems-backend 2>&1 | grep -q "Caching Edges.*finished"; then
  log "  Backend -> Postgres:  OK"
else
  warn "  Backend -> Postgres:  NOT CONFIRMED (may need more time)"
  PASS=false
fi

# Backend → InfluxDB
if docker compose logs openems-backend 2>&1 | grep -q "InfluxDB"; then
  log "  Backend -> InfluxDB:  OK"
else
  warn "  Backend -> InfluxDB:  NOT CONFIRMED"
  PASS=false
fi

# Edge → Scheduler
if docker compose logs openems-edge 2>&1 | grep -q "Scheduler"; then
  log "  Edge scheduler:       OK"
else
  warn "  Edge scheduler:       NOT CONFIRMED"
  PASS=false
fi

# Edge → Backend
if docker compose logs openems-backend 2>&1 | grep -q "Edge.Websocket"; then
  log "  Edge -> Backend:      OK"
else
  warn "  Edge -> Backend:      NOT CONFIRMED (may need more time)"
  PASS=false
fi

log ""
if [ "$PASS" = true ]; then
  log "All checks passed!"
else
  warn "Some checks did not pass yet. Services may still be starting."
  warn "Re-run verification: docker compose logs --tail=50 openems-backend openems-edge"
fi

log ""
log "Stack is ready:"
log "  OpenEMS UI:      http://localhost:4200"
log "  Odoo:            http://localhost:10016"
log "  Felix Console:   http://localhost:8080"
log "  InfluxDB:        http://localhost:8086"
log ""
log "Default credentials:"
log "  OpenEMS UI:  admin / admin"
log "  Odoo:        admin / (set during DB creation, master pw: openemspassword)"
