#!/usr/bin/env bash
# provision-edge.sh — run on the PI (32-bit Raspberry Pi OS).
#
# Turns this Pi into a registered OpenEMS edge running as a memory-capped
# systemd service that coexists with OpenPLC. Idempotent: re-run any time to
# update config. Get the exact command (with --api-key) from register-edge.sh
# on the laptop.
#
#   sudo ./provision-edge.sh --edge-id bronx-05 --api-key <secret> \
#        --backend ws://10.0.0.188:8081 --place-name "Bronx Community"
#
# Native (no Docker), 32-bit only. Installs BellSoft Liberica JRE 21 (arm32) +
# the OpenEMS edge jar under /opt/openems-edge.
set -euo pipefail

# --- pinned artifacts -------------------------------------------------------
OPENEMS_VERSION="2026.6.0"
EDGE_JAR_URL="https://github.com/OpenEMS/openems/releases/download/${OPENEMS_VERSION}/openems-edge.jar"
# BellSoft Liberica JRE 21, 32-bit ARM hard-float (matches Raspbian armv7l).
JRE_VERSION="21.0.11+11"
JRE_URL="https://github.com/bell-sw/Liberica/releases/download/${JRE_VERSION}/bellsoft-jre${JRE_VERSION}-linux-arm32-vfp-hflt.tar.gz"
JRE_SHA1="9900953206bc09fc2d3fb034d2b6a37dc6e7a201"

BASE=/opt/openems-edge
JRE_DIR="$BASE/jre"
JAR="$BASE/openems-edge.jar"
CFG="$BASE/config.d"
UNIT=/etc/systemd/system/openems-edge.service

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[provision] $*"; }

# --- args -------------------------------------------------------------------
EDGE_ID="" API_KEY="" BACKEND="" PLACE="" LAT="" LON="" POSTCODE="" REGION=""
PV_SCALE="" MAX_MEM="384M" DRY_RUN=0
BACKEND_CA="" KEYSTORE="" KEYSTORE_PASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --edge-id)    EDGE_ID="$2"; shift 2;;
    --api-key)    API_KEY="$2"; shift 2;;
    --backend)    BACKEND="$2"; shift 2;;
    --place-name) PLACE="$2"; shift 2;;
    --lat)        LAT="$2"; shift 2;;
    --lon)        LON="$2"; shift 2;;
    --postcode)   POSTCODE="$2"; shift 2;;
    --region)     REGION="$2"; shift 2;;
    --pv-scale)   PV_SCALE="$2"; shift 2;;
    --max-mem)    MAX_MEM="$2"; shift 2;;   # JVM heap (-Xmx); cgroup cap derived
    # --- TLS (P4): use these with a wss:// backend ---
    --backend-ca)      BACKEND_CA="$2"; shift 2;;       # CA cert (PEM) to trust the backend
    --keystore)        KEYSTORE="$2"; shift 2;;         # PKCS12 with this edge's client cert (mTLS)
    --keystore-pass)   KEYSTORE_PASS="$2"; shift 2;;
    --dry-run)    DRY_RUN=1; shift;;        # render config to a temp dir & exit (any arch)
    -h|--help)    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

# --- arg validation (always) ------------------------------------------------
[ -n "$EDGE_ID" ]  || die "--edge-id is required"
[ -n "$API_KEY" ]  || die "--api-key is required (from register-edge.sh)"
[ -n "$BACKEND" ]  || die "--backend is required, e.g. ws://10.0.0.188:8081"
[[ "$EDGE_ID" =~ [0-9]+$ ]] || die "--edge-id must end in digits"

# --- guards / dry-run -------------------------------------------------------
ARCH="$(uname -m)"
if [ "$DRY_RUN" -eq 1 ]; then
  BASE="$(mktemp -d)"; JRE_DIR="$BASE/jre"; JAR="$BASE/openems-edge.jar"; CFG="$BASE/config.d"
  echo "[provision] DRY RUN — rendering config to $CFG (no install, any arch)"
else
  [ "$ARCH" = "armv7l" ] || die "this provisioner targets 32-bit Raspberry Pi OS only (need armv7l, got '$ARCH'). Aborting."
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)."
  command -v systemctl >/dev/null || die "systemd (systemctl) required"
fi

# downloader
fetch() { # url dest
  if command -v curl >/dev/null; then curl -fSL "$1" -o "$2"
  elif command -v wget >/dev/null; then wget -qO "$2" "$1"
  else die "need curl or wget"; fi
}

# PV multiplier: explicit --pv-scale, else (trailing digits + 1) — the P1 rule.
if [ -n "$PV_SCALE" ]; then MULT="$PV_SCALE"; else
  N="$(printf '%s' "$EDGE_ID" | grep -oE '[0-9]+$' || echo 0)"; MULT=$(( 10#$N + 1 ));
fi
# Simulated PV values are stored as ints (max ~2.1e9). The largest base value is
# 4100, so a multiplier above ~520k overflows and the datasource config fails to
# parse. Guard it (only reachable with an absurd trailing number or --pv-scale).
[ "$MULT" -ge 1 ] 2>/dev/null || die "--pv-scale must be a positive integer"
[ "$(( 4100 * MULT ))" -le 2000000000 ] || die "pv multiplier $MULT too large (int overflow); use a smaller --pv-scale or an edge-id with fewer trailing digits"

log "edge-id=$EDGE_ID  backend=$BACKEND  pv-multiplier=x$MULT  heap=$MAX_MEM  arch=$ARCH"

# --- 1. JRE -----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then :  # skip install in dry-run
elif [ -x "$JRE_DIR/bin/java" ]; then
  log "JRE already present ($("$JRE_DIR/bin/java" -version 2>&1 | head -1))"
else
  log "installing Liberica JRE $JRE_VERSION (arm32)..."
  mkdir -p "$BASE"
  tmp="$(mktemp -d)"
  fetch "$JRE_URL" "$tmp/jre.tar.gz"
  echo "$JRE_SHA1  $tmp/jre.tar.gz" | sha1sum -c - >/dev/null || die "JRE checksum mismatch"
  mkdir -p "$tmp/x"; tar -xzf "$tmp/jre.tar.gz" -C "$tmp/x"
  # the extracted top-level dir name varies (e.g. jre-21.0.11); find the JRE
  # home by its bin/java rather than guessing the name.
  src="$(dirname "$(dirname "$(find "$tmp/x" -path '*/bin/java' -type f | head -1)")")"
  [ -n "$src" ] && [ -d "$src" ] || die "could not locate bin/java in the JRE tarball"
  rm -rf "$JRE_DIR"; mv "$src" "$JRE_DIR"
  rm -rf "$tmp"
  log "JRE installed: $("$JRE_DIR/bin/java" -version 2>&1 | head -1)"
fi

# --- 2. edge jar ------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then :  # skip download in dry-run
elif [ -f "$JAR" ]; then log "edge jar already present"; else
  log "downloading openems-edge.jar $OPENEMS_VERSION..."
  mkdir -p "$BASE"; fetch "$EDGE_JAR_URL" "$JAR"
fi

# --- 3. render config.d -----------------------------------------------------
log "rendering config.d (apikey is the secret; identity resolves on the backend)"
rm -rf "$CFG"; mkdir -p \
  "$CFG/Controller/Api/Backend" "$CFG/Controller/Debug/Log" \
  "$CFG/Scheduler/AllAlphabetically" "$CFG/Simulator/Datasource/Single/Direct" \
  "$CFG/Simulator/GridMeter/Reacting" "$CFG/Simulator/ProductionMeter/Acting"

cat > "$CFG/Controller/Api/Backend/ctrlBackend0.config" <<EOF
:org.apache.felix.configadmin.revision:=L"1"
apiTimeout=I"60"
apikey="$API_KEY"
debug=B"false"
enabled=B"true"
id="ctrlBackend0"
noOfCycles=I"10"
proxyAddress=""
proxyPort=I"0"
proxyType="HTTP"
service.factoryPid="Controller.Api.Backend"
service.pid="Controller.Api.Backend.ctrlBackend0"
uri="$BACKEND"
EOF

cat > "$CFG/Controller/Debug/Log/ctrlDebugLog0.config" <<'EOF'
:org.apache.felix.configadmin.revision:=L"1"
enabled=B"true"
id="ctrlDebugLog0"
service.factoryPid="Controller.Debug.Log"
service.pid="Controller.Debug.Log.ctrlDebugLog0"
EOF

cat > "$CFG/Scheduler/AllAlphabetically/scheduler0.config" <<'EOF'
:org.apache.felix.configadmin.revision:=L"1"
controllers.ids=[ \
  "ctrlDebugLog0", \
  ]
enabled=B"true"
id="scheduler0"
service.factoryPid="Scheduler.AllAlphabetically"
service.pid="Scheduler.AllAlphabetically.scheduler0"
EOF

# simulated PV profile, scaled by MULT (single-line values list, as P1 does)
BASE_VALS="800 1200 2000 3200 4100 3500 2400 1500"
vals=""; for b in $BASE_VALS; do vals="$vals\"$((b * MULT))\", "; done; vals="${vals%, }"
cat > "$CFG/Simulator/Datasource/Single/Direct/datasource0.config" <<EOF
:org.apache.felix.configadmin.revision:=L"1"
alias="Simulated PV profile (x$MULT)"
enabled=B"true"
id="datasource0"
service.factoryPid="Simulator.Datasource.Single.Direct"
service.pid="Simulator.Datasource.Single.Direct.datasource0"
values=i[ $vals ]
EOF

cat > "$CFG/Simulator/GridMeter/Reacting/meter0.config" <<'EOF'
:org.apache.felix.configadmin.revision:=L"1"
alias="Grid"
enabled=B"true"
id="meter0"
maxActivePower=""
minActivePower=""
service.factoryPid="Simulator.GridMeter.Reacting"
service.pid="Simulator.GridMeter.Reacting.meter0"
EOF

cat > "$CFG/Simulator/ProductionMeter/Acting/meter1.config" <<'EOF'
:org.apache.felix.configadmin.revision:=L"1"
alias="Simulated PV"
datasource.id="datasource0"
enabled=B"true"
id="meter1"
service.factoryPid="Simulator.ProductionMeter.Acting"
service.pid="Simulator.ProductionMeter.Acting.meter1"
EOF

# Core.Meta (site metadata). PID is "Core.Meta", so the file MUST live at
# Core/Meta.config (path == pid; a flat Core.Meta.config is silently ignored by
# Felix — the same rule from P1). id="_meta" is the fixed singleton id; OpenEMS
# fills the remaining Core.Meta fields with defaults. Values stored as strings,
# matching how OpenEMS persists them.
if [ -n "$PLACE$LAT$LON$POSTCODE$REGION" ]; then
  mkdir -p "$CFG/Core"
  {
    printf ':org.apache.felix.configadmin.revision:=L"1"\n'
    printf 'id="_meta"\n'
    printf 'service.pid="Core.Meta"\n'
    [ -n "$PLACE" ]    && printf 'placeName="%s"\n' "$PLACE"
    [ -n "$LAT" ]      && printf 'latitude="%s"\n' "$LAT"
    [ -n "$LON" ]      && printf 'longitude="%s"\n' "$LON"
    [ -n "$POSTCODE" ] && printf 'postcode="%s"\n' "$POSTCODE"
    [ -n "$REGION" ]   && printf 'subdivisionCode="%s"\n' "$REGION"
  } > "$CFG/Core/Meta.config"
fi

# --- dry-run: show what we rendered and stop -------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo; echo "[provision] rendered config files:"
  find "$CFG" -name '*.config' | sort | sed "s|$CFG/|  |"
  echo; echo "----- ctrlBackend0.config -----"; cat "$CFG/Controller/Api/Backend/ctrlBackend0.config"
  echo "----- datasource0.config -----"; cat "$CFG/Simulator/Datasource/Single/Direct/datasource0.config"
  [ -f "$CFG/Core/Meta.config" ] && { echo "----- Core/Meta.config -----"; cat "$CFG/Core/Meta.config"; }
  echo; echo "[provision] dry run complete (temp dir $BASE — safe to delete)"
  exit 0
fi

# --- 4. systemd service (memory-capped, coexists with OpenPLC) --------------
# Heap = --max-mem (-Xmx). cgroup MemoryMax = heap + 384 MiB headroom (metaspace,
# threads, native, buffers) so the kernel hard-caps the JVM and it can never
# starve OpenPLC. Computed in MiB with awk (handles M/G suffixes).
HEAP_MIB="$(awk -v v="$MAX_MEM" 'BEGIN{u=substr(v,length(v));n=substr(v,1,length(v)-1)+0; if(u=="G"||u=="g")n*=1024; else if(u!="M"&&u!="m")n=v+0; printf "%d", n}')"
MEMMAX_MIB=$(( HEAP_MIB + 384 ))
log "systemd: -Xmx${HEAP_MIB}M, MemoryMax=${MEMMAX_MIB}M"

# --- TLS (P4): trust the backend cert + present this edge's client cert ------
# Injected via standard JVM SSL system properties — the edge's java_websocket
# client uses the default SSLContext, so these apply with no OpenEMS code change.
TLS_ARGS=""
if [ -n "$BACKEND_CA" ]; then
  [ -f "$BACKEND_CA" ] || die "--backend-ca not found: $BACKEND_CA"
  # Build the JVM truststore with keytool (from the JRE we installed) so the CA
  # is a real trustedCertEntry — an openssl cert-only PKCS12 yields zero trust
  # anchors ("trustAnchors must be non-empty").
  rm -f "$BASE/truststore.p12"
  "$JRE_DIR/bin/keytool" -importcert -noprompt -alias openems-ca \
    -file "$BACKEND_CA" -keystore "$BASE/truststore.p12" \
    -storetype PKCS12 -storepass changeit >/dev/null 2>&1 || die "keytool truststore build failed"
  TLS_ARGS="$TLS_ARGS -Djavax.net.ssl.trustStore=$BASE/truststore.p12 -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit"
fi
if [ -n "$KEYSTORE" ]; then
  [ -f "$KEYSTORE" ] || die "--keystore not found: $KEYSTORE"
  cp "$KEYSTORE" "$BASE/keystore.p12"
  TLS_ARGS="$TLS_ARGS -Djavax.net.ssl.keyStore=$BASE/keystore.p12 -Djavax.net.ssl.keyStoreType=PKCS12"
  [ -n "$KEYSTORE_PASS" ] && TLS_ARGS="$TLS_ARGS -Djavax.net.ssl.keyStorePassword=$KEYSTORE_PASS"
fi
case "$BACKEND" in
  wss://*) [ -n "$TLS_ARGS" ] && log "TLS: wss client configured" \
           || log "WARNING: wss:// backend but no --backend-ca/--keystore given" ;;
esac

cat > "$UNIT" <<EOF
[Unit]
Description=OpenEMS Edge ($EDGE_ID)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$JRE_DIR/bin/java -XX:+ExitOnOutOfMemoryError -Xmx${HEAP_MIB}m$TLS_ARGS -Dfelix.cm.dir=$CFG -jar $JAR
WorkingDirectory=$BASE
Restart=on-failure
RestartSec=10
# Hard memory ceiling so the edge cannot starve OpenPLC on this 2 GB box.
MemoryMax=${MEMMAX_MIB}M
MemoryHigh=$(( MEMMAX_MIB - 128 ))M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openems-edge.service >/dev/null 2>&1 || true
systemctl restart openems-edge.service

sleep 2
log "service status:"
systemctl --no-pager --lines=0 status openems-edge.service || true
cat <<EOF

✅ Provisioned edge '$EDGE_ID'. It will connect to $BACKEND and appear on the backend shortly.
   Logs:   journalctl -u openems-edge -f
   Verify (from the laptop):  python3 probe_backend.py $EDGE_ID
EOF
