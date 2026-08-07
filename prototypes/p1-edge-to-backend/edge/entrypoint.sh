#!/usr/bin/env bash
# Generic OpenEMS Edge launcher.
# Each container becomes a distinct "site" by rendering two config files from
# env vars before starting OpenEMS:
#   EDGE_ID      -> apikey the backend identifies this edge by   (default edge0)
#   BACKEND_URI  -> where to push telemetry                      (default ws://openems-backend:8081)
# The simulated PV profile is scaled per-edge so every site reports different
# numbers (edge0 = 1x, edge1 = 2x, ...), making the multi-edge view meaningful.
set -e

ID="${EDGE_ID:-edge0}"
URI="${BACKEND_URI:-ws://openems-backend:8081}"
DEBUG="${EDGE_DEBUG:-false}"   # true -> log each payload sent to the backend
CLUSTER="${CLUSTER:-}"          # human label for the site/community, e.g. "Bronx Microgrid"
LAT="${LAT:-}"                  # optional decimal latitude
LON="${LON:-}"                  # optional decimal longitude
CFG=/opt/openems-edge/config.d

# trailing digits of the id ("edge3"->3, "bronx-02"->2) for PV scaling; else 0
N=$(printf '%s' "$ID" | grep -oE '[0-9]+$' || true)
[ -z "$N" ] && N=0
N=$((10#$N))          # force base-10 so "08"/"09" don't error as octal
MULT=$((N + 1))

# --- edge -> backend connector ------------------------------------------------
cat > "$CFG/Controller/Api/Backend/ctrlBackend0.config" <<EOF
:org.apache.felix.configadmin.revision:=L"1"
apiTimeout=I"60"
apikey="$ID"
debug=B"$DEBUG"
enabled=B"true"
id="ctrlBackend0"
noOfCycles=I"10"
proxyAddress=""
proxyPort=I"0"
proxyType="HTTP"
service.factoryPid="Controller.Api.Backend"
service.pid="Controller.Api.Backend.ctrlBackend0"
uri="$URI"
EOF

# --- per-site simulated PV profile (scaled) -----------------------------------
BASE="800 1200 2000 3200 4100 3500 2400 1500"
vals=""
for b in $BASE; do vals="$vals\"$((b * MULT))\", "; done
vals="${vals%, }"
cat > "$CFG/Simulator/Datasource/Single/Direct/datasource0.config" <<EOF
:org.apache.felix.configadmin.revision:=L"1"
alias="Simulated PV profile (x$MULT)"
enabled=B"true"
id="datasource0"
service.factoryPid="Simulator.Datasource.Single.Direct"
service.pid="Simulator.Datasource.Single.Direct.datasource0"
values=i[ $vals ]
EOF

# --- site/cluster metadata (Core.Meta) so the backend knows where data is from -
# PID "Core.Meta" → file MUST be at Core/Meta.config (path == pid); a flat
# Core.Meta.config is silently ignored by Felix. id="_meta" is the singleton id.
if [ -n "$CLUSTER" ] || [ -n "$LAT" ]; then
  mkdir -p "$CFG/Core"
  {
    printf ':org.apache.felix.configadmin.revision:=L"1"\n'
    printf 'id="_meta"\n'
    printf 'service.pid="Core.Meta"\n'
    [ -n "$CLUSTER" ] && printf 'placeName="%s"\n' "$CLUSTER"
    [ -n "$LAT" ] && printf 'latitude="%s"\n' "$LAT"
    [ -n "$LON" ] && printf 'longitude="%s"\n' "$LON"
  } > "$CFG/Core/Meta.config"
fi

echo "[entrypoint] EDGE_ID=$ID  cluster='${CLUSTER}'  PV_multiplier=x$MULT  BACKEND_URI=$URI"
exec java -XX:+ExitOnOutOfMemoryError -Dfelix.cm.dir="$CFG" -jar /opt/openems-edge/openems-edge.jar
