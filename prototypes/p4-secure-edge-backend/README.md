# P4 — secure the edge→backend hop (wss + mTLS)

The fourth prototype for [energy-iot/docker-openems#79](https://github.com/energy-iot/docker-openems/issues/79):
close the security gap from P1/P2 — the edge connected over **plaintext `ws://`
with its apikey in a cleartext header**. P4 puts TLS in front of the backend so
the edge connects over **`wss://`**, and adds **mTLS** so only edges holding a
valid client certificate can connect at all.

```
   PI edge                                   LAPTOP
 ┌────────────────────┐   wss:// + mTLS   ┌──────────────────────┐   ws://    ┌─────────────────┐
 │ openems-edge        │ ════════════════►│ nginx tls-proxy :8443 │ ─────────► │ openems-backend │
 │  trustStore (CA)    │  (encrypted;      │  • server cert        │ (plaintext │  :8081          │
 │  keyStore (client   │   client cert     │  • verifies client    │  inside    └─────────────────┘
 │   cert) via JVM -D  │   required)       │    cert (ssl_verify)  │  Docker)
 └────────────────────┘                   └──────────────────────┘
```

The backend, InfluxDB, UI, and the edge software are all unchanged — P4 is a TLS
layer in front plus a one-line URL change on the edge (`ws://` → `wss://`).

## Run it

```bash
# 1. generate an internal CA, a server cert (IP SAN), and a per-edge client cert
./make-certs.sh 10.0.0.188 slrp4-09        # → ./certs/ (gitignored; dev creds)

# 2. start the TLS proxy (joins the running P1 backend network)
docker compose up -d                        # nginx on :8443, wss + mTLS

# 3. onboard the edge over wss (P2 register-edge.sh first for the apikey), then:
#    ship certs/ca.crt + certs/client-slrp4-09.p12 to the Pi, and:
sudo ./provision-edge.sh --edge-id slrp4-09 --api-key <secret> \
     --backend wss://10.0.0.188:8443 \
     --backend-ca ~/ca.crt \
     --keystore ~/client-slrp4-09.p12 --keystore-pass openems
```
(`provision-edge.sh` lives in `../p2-edge-on-pi/`; P4 just adds the `--backend-ca`
/ `--keystore` flags and a `wss://` backend URL.)

## The certificate model

`make-certs.sh` builds a tiny PKI (openssl-only, no public CA — there's no domain
on the LAN, so Let's Encrypt isn't an option here):

| File | What it is | Used by |
|---|---|---|
| `ca.crt` / `ca.key` | the internal Certificate Authority | signs everything below |
| `server.crt` / `.key` | backend identity, **SAN `IP:10.0.0.188`** | nginx (so the edge can verify the server) |
| `client-<edge>.crt/.key/.p12` | per-edge **client** cert (CN = edge-id) | the edge presents it (mTLS) |

On the Pi, the edge's JVM is pointed at:
- a **trustStore** (built on the Pi with `keytool` from `ca.crt`) → trusts the backend;
- a **keyStore** (`client-<edge>.p12`) → presents the client cert.

Both via standard `-Djavax.net.ssl.{trustStore,keyStore}` properties — the edge's
`java_websocket` client uses the default `SSLContext`, so **no OpenEMS code
change** is needed (verified — see LEARNINGS).

## Verify (all confirmed on the SL-RP4)

- **mTLS enforced:** `curl --cacert ca.crt https://10.0.0.188:8443/` (no client
  cert) → **HTTP 400**; with `--cert/--key` → reaches the backend.
- **Server identity:** `openssl s_client … -CAfile ca.crt` → `Verify return code: 0 (ok)`.
- **Edge works end-to-end:** `ctrlBackend0[Connected]`, and
  `probe_backend.py slrp4-09` shows live data over the wss path.
- **The apikey is actually hidden** — same header captured on the wire with tcpdump:
  ```
  ws://:8081   → "Apikey: SNIFFME-WS-8081"   visible in cleartext
  wss://:8443  → "SNIFFME-WSS-8443"          NOT in the capture (encrypted)
  ```

## What mTLS buys (vs plain wss)

Plain `wss://` encrypts the hop and lets the edge verify the backend — but the
backend still trusts anyone with the (now-protected) apikey. **mTLS adds device
identity:** the edge presents its own certificate, so the backend (via nginx)
rejects any device without a valid client cert *at the TLS handshake*, before any
app logic. A leaked apikey alone is then useless. This is the "skip the VPN" path
— VPN-like device identity without running a VPN. (See the ws/wss/mTLS/OpenVPN
comparison in the chat history / LEARNINGS.)

## Production notes

- **Real deployments** use a public CA (Let's Encrypt) with a real domain and a
  load balancer terminating TLS — the nginx here is the LB's local stand-in.
- **Close the plaintext port:** P1 still publishes the backend's `ws://:8081`
  directly; in production only the `wss://` endpoint (443) should be exposed.
- **mTLS at scale** means issuing/rotating/revoking a client cert per edge — the
  same provisioning pipeline that issues the apikey would issue the cert.
- The dev certs/keys here are throwaway and **gitignored** — never commit private keys.
