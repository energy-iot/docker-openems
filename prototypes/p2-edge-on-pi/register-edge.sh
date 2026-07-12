#!/usr/bin/env bash
# register-edge.sh — run on the LAPTOP (where the backend + registry live).
#
# Registers an edge in the backend's Metadata.File registry: generates a secret
# apikey, writes the entry, restarts the backend so it loads (Metadata.File reads
# the registry only at startup), and prints the ready-to-run provision command
# for the Pi.
#
#   ./register-edge.sh bronx-05 --place "Bronx Community" --comment "SL-RP4 #1"
#   ./register-edge.sh queens-07 --lat 40.74 --lon -73.79 --no-restart
#
# Re-running for the same edge-id keeps its apikey (idempotent) unless --rotate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/../p1-edge-to-backend"      # the shared backend stack
REGISTRY="$BACKEND_DIR/backend/registry/edges.json"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- args -------------------------------------------------------------------
[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0;; -*) die "first argument must be the edge-id";; esac
EDGE_ID="$1"; shift

COMMENT="" PLACE="" LAT="" LON="" POSTCODE="" REGION="" PV_SCALE=""
BACKEND_URI="" MAX_MEM="" NO_RESTART=0 ROTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --comment)   COMMENT="$2"; shift 2;;
    --place)     PLACE="$2"; shift 2;;
    --lat)       LAT="$2"; shift 2;;
    --lon)       LON="$2"; shift 2;;
    --postcode)  POSTCODE="$2"; shift 2;;
    --region)    REGION="$2"; shift 2;;
    --pv-scale)  PV_SCALE="$2"; shift 2;;
    --max-mem)   MAX_MEM="$2"; shift 2;;
    --backend)   BACKEND_URI="$2"; shift 2;;
    --no-restart) NO_RESTART=1; shift;;
    --rotate)    ROTATE=1; shift;;
    -h|--help)   usage 0;;
    *) die "unknown option: $1";;
  esac
done

# --- validate ---------------------------------------------------------------
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[[ "$EDGE_ID" =~ [0-9]+$ ]] || die "edge-id must end in digits (its trailing number becomes the InfluxDB tag): '$EDGE_ID'"
command -v python3 >/dev/null || die "python3 required"
command -v openssl >/dev/null || die "openssl required (for apikey generation)"

[ -n "$COMMENT" ] || COMMENT="${PLACE:-Registered edge $EDGE_ID}"
CANDIDATE_KEY="$(openssl rand -hex 24)"

# --- upsert into the registry (python: preserves other keys, enforces unique
#     trailing-number, keeps existing apikey unless --rotate). Prints the final
#     apikey on stdout. ---------------------------------------------------------
APIKEY="$(python3 - "$REGISTRY" "$EDGE_ID" "$CANDIDATE_KEY" "$COMMENT" "$ROTATE" <<'PY'
import json, re, sys
path, edge_id, candidate, comment, rotate = sys.argv[1:6]
rotate = rotate == "1"
with open(path) as f:
    doc = json.load(f)
edges = doc.setdefault("edges", {})

def trailing(s):
    m = re.search(r"(\d+)$", s)
    return int(m.group(1)) if m else None

num = trailing(edge_id)
for other, e in edges.items():
    if other != edge_id and trailing(other) == num:
        sys.exit(f"ERR trailing number {num} already used by '{other}' "
                 f"(InfluxDB tag would collide)")

existing = edges.get(edge_id)
if existing and not rotate:
    apikey = existing.get("apikey", candidate)          # idempotent: keep key
else:
    apikey = candidate
edges[edge_id] = {"apikey": apikey, "comment": comment}
if existing and existing.get("setuppassword"):
    edges[edge_id]["setuppassword"] = existing["setuppassword"]

with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(apikey)
PY
)" || die "$APIKEY"

# --- default backend URI = this laptop's LAN IP -----------------------------
if [ -z "$BACKEND_URI" ]; then
  IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$IP" ] || die "could not detect LAN IP; pass --backend ws://<ip>:8081"
  BACKEND_URI="ws://$IP:8081"
fi

# --- restart backend so Metadata.File reloads -------------------------------
if [ "$NO_RESTART" -eq 0 ]; then
  echo "restarting backend so it loads the new registry entry..."
  ( cd "$BACKEND_DIR" && docker compose restart openems-backend >/dev/null 2>&1 ) \
    && echo "backend restarted." || die "backend restart failed (is the stack up?)"
else
  echo "note: --no-restart set; restart the backend before the edge can connect:"
  echo "      ( cd $BACKEND_DIR && docker compose restart openems-backend )"
fi

# --- print the provision command --------------------------------------------
CMD="sudo ./provision-edge.sh --edge-id $EDGE_ID --api-key $APIKEY --backend $BACKEND_URI"
[ -n "$PLACE" ]    && CMD="$CMD --place-name \"$PLACE\""
[ -n "$LAT" ]      && CMD="$CMD --lat $LAT"
[ -n "$LON" ]      && CMD="$CMD --lon $LON"
[ -n "$POSTCODE" ] && CMD="$CMD --postcode $POSTCODE"
[ -n "$REGION" ]   && CMD="$CMD --region $REGION"
[ -n "$PV_SCALE" ] && CMD="$CMD --pv-scale $PV_SCALE"
[ -n "$MAX_MEM" ]  && CMD="$CMD --max-mem $MAX_MEM"

cat <<EOF

✅ Registered edge '$EDGE_ID'  (apikey ${APIKEY:0:8}…, comment: "$COMMENT")

   Copy this onto the Pi (in prototypes/p2-edge-on-pi/) and run it:

   $CMD

EOF
