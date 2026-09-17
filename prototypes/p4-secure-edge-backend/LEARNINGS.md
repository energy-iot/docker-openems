# P4 — what happened, what we tried, and what we learned

Goal: secure the edge→backend hop. P1/P2 ran over plaintext `ws://` with the
apikey in a cleartext HTTP header. P4 makes it `wss://` (TLS) + **mTLS** (client
certs), verified on the SL-RP4. The backend/edge software is unchanged — P4 is an
nginx TLS proxy in front + standard JVM SSL properties on the edge.

## Approach

A TLS-terminating **nginx** reverse proxy sits in front of the backend
(`:8443` wss → `:8081` ws inside Docker), with `ssl_verify_client on` for mTLS.
A small internal CA (`make-certs.sh`, openssl-only) issues a server cert (IP SAN,
since there's no domain on the LAN) and a per-edge client cert. The edge trusts
the CA and presents its client cert via `-Djavax.net.ssl.{trustStore,keyStore}`.

## The two things that bit us (and the fixes)

### 1. Does the edge even do TLS for wss? — yes, via the default SSLContext
The edge's `AbstractWebsocketClient` does `new WebSocketClient(uri, …)` with **no**
`setSocketFactory(...)`. The worry: `java_websocket` might use a plain socket for
`wss://` (→ no TLS) or a custom context that ignores JVM properties. Reading the
source was inconclusive, so we tested empirically: the first wss attempt failed
with `InvalidAlgorithmParameterException: trustAnchors must be non-empty` — which
*proves* it was performing a real TLS handshake using the **default SSLContext**.
→ Conclusion: the standard `-Djavax.net.ssl.trustStore`/`keyStore` system
properties apply, so trust + client-cert can be injected with **zero OpenEMS code
change**. (Big deal — it means wss + mTLS is purely a deployment concern.)

### 2. The truststore gotcha: openssl `pkcs12 -nokeys` ≠ a Java truststore
We first built the truststore with `openssl pkcs12 -export -nokeys -in ca.crt`.
The JVM loaded it but found **zero trust anchors** (the same `trustAnchors must be
non-empty` error). Reason: openssl stores the CA as a plain certificate bag, but
Java only treats a cert as a trust anchor if it's a **`trustedCertEntry`**, which
openssl doesn't produce.
→ Fix: build the truststore with **`keytool -importcert`** (the Liberica JRE on
the Pi has it). `provision-edge.sh` now ships `ca.crt` (PEM) and runs keytool on
the Pi to make a proper truststore. Note the asymmetry: the **keyStore** (client
key+cert) from `openssl pkcs12 -export` *is* fine — Java reads a `keyEntry`
normally; it's only the trust-anchor case that needs keytool.

## Verified on the wire

- **mTLS enforcement:** no client cert → nginx returns 400; valid client cert →
  proxied to the backend. Server cert validates against the CA (`Verify code 0`).
- **Encryption, demonstrated:** same apikey header sent over both ports while
  tcpdump ran on the Pi — `Apikey: SNIFFME-WS-8081` was **readable** in the
  `ws://:8081` capture; `SNIFFME-WSS-8443` was **absent** from the `wss://:8443`
  capture (42 TLS packets, none revealing it).
- **End-to-end:** `ctrlBackend0[Connected]`, live telemetry via `probe_backend.py`,
  all flowing edge → nginx(wss/mTLS) → backend.

## Durable learnings

- **wss + mTLS on OpenEMS edge is a deployment concern, not a code change** — the
  edge uses the JVM default SSLContext, so trust and client identity are injected
  with `-Djavax.net.ssl.*`. This is the key enabler for the "skip the VPN" path.
- **Java trust anchors need `keytool`,** not an openssl cert-only PKCS12. Symptom
  is the misleading `trustAnchors parameter must be non-empty`.
- **IP-SAN certs** let you do TLS on a LAN with no DNS — put the backend IP in the
  server cert's `subjectAltName`.
- **nginx logs a WebSocket only when it closes** (it's a long-lived upgrade), so
  "nothing in the access log" during a healthy connection is normal — check the
  edge's `ctrlBackend0[Connected]` instead.
- **mTLS ≈ VPN-grade device identity without a VPN:** a leaked apikey is useless
  without the device's private key. The remaining thing a VPN adds is hiding the
  backend from the internet entirely (see the ws/wss/mTLS/OpenVPN comparison).
