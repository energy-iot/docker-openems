#!/usr/bin/env bash
# make-certs.sh — generate an internal CA, a server cert for the backend, and a
# per-edge client cert (for mTLS). openssl-only (no keytool needed on the laptop).
#
#   ./make-certs.sh                 # CA + server cert for 10.0.0.188
#   ./make-certs.sh 10.0.0.188 slrp4-09   # + a client cert/keystore for an edge
#
# Outputs to ./certs/. These are THROWAWAY DEV credentials — the dir is
# gitignored; never commit private keys. Re-run is idempotent (won't clobber the
# CA/server once made; re-issues a client cert each time you name one).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS="$SCRIPT_DIR/certs"
IP="${1:-10.0.0.188}"
EDGE_ID="${2:-}"
P12PASS="${CERT_P12PASS:-openems}"   # dev-only keystore password
mkdir -p "$CERTS"; cd "$CERTS"

# --- 1. internal CA (once) --------------------------------------------------
if [ ! -f ca.crt ]; then
  echo "[certs] creating internal CA"
  openssl genrsa -out ca.key 4096 2>/dev/null
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt -subj "/CN=OpenEMS-P4-Dev-CA/O=pi-dev"
else
  echo "[certs] CA already exists — keeping it"
fi

# --- 2. server cert for the backend IP (once) -------------------------------
if [ ! -f server.crt ]; then
  echo "[certs] issuing server cert (SAN IP:$IP)"
  openssl genrsa -out server.key 2048 2>/dev/null
  cat > server-ext.cnf <<EOF
subjectAltName = IP:$IP, DNS:localhost, IP:127.0.0.1
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
  openssl req -new -key server.key -out server.csr -subj "/CN=openems-backend"
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 825 -sha256 -extfile server-ext.cnf
else
  echo "[certs] server cert already exists — keeping it (delete certs/server.* to reissue)"
fi

# --- 3. the edge trusts the server via the CA PEM (ca.crt). NOTE: we do NOT
# build a Java truststore here — an openssl cert-only PKCS12 is not read as a
# trust anchor by the JVM ("trustAnchors must be non-empty"). provision-edge.sh
# builds the truststore on the Pi with the JRE's keytool from this ca.crt.

# --- 4. per-edge client cert + keystore for mTLS ----------------------------
if [ -n "$EDGE_ID" ]; then
  echo "[certs] issuing client cert for '$EDGE_ID' (mTLS)"
  openssl genrsa -out "client-$EDGE_ID.key" 2048 2>/dev/null
  cat > client-ext.cnf <<EOF
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF
  openssl req -new -key "client-$EDGE_ID.key" -out "client-$EDGE_ID.csr" -subj "/CN=$EDGE_ID"
  openssl x509 -req -in "client-$EDGE_ID.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "client-$EDGE_ID.crt" -days 825 -sha256 -extfile client-ext.cnf
  # bundle key+cert into a PKCS12 the edge JVM presents as its keyStore
  openssl pkcs12 -export -in "client-$EDGE_ID.crt" -inkey "client-$EDGE_ID.key" \
    -out "client-$EDGE_ID.p12" -passout "pass:$P12PASS" -name "$EDGE_ID"
  echo "[certs] client-$EDGE_ID.p12 ready"
fi

echo
echo "[certs] done. Files in $CERTS:"
ls -1 "$CERTS" | sed 's/^/  /'
echo "  (keystore/truststore password: $P12PASS)"
