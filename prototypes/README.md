# Prototypes — edge → backend groundwork for the AWS deployment

Working prototypes built for [#79](https://github.com/energy-iot/docker-openems/issues/79),
shared here so the conclusions behind `docs/aws-arch-v2-plan.md` are
reproducible. Each directory is self-contained (own compose file / scripts)
and has a `README.md` (how to run + verify) and a `LEARNINGS.md` (what broke
and why). They were developed on a laptop + a Synergy Logic SL-RP4
(Raspberry Pi 4, 2 GB, 32-bit); numbering has a gap — P3 (MQTT meter
ingestion) was planned but not built.

| Prototype | Proves | Key takeaway |
|---|---|---|
| **p1-edge-to-backend** | N simulated edges → one backend → InfluxDB, telemetry read back out via the UI websocket (probe scripts included) | Backend pinned to **2026.1.0** (last monolithic release — upstream's own recommendation); Felix config path == PID rule; Metadata.Dummy loses edge identity across restarts |
| **p2-edge-on-pi** | The edge runs natively on the real 2 GB Pi and onboards through an apikey registry (`register-edge.sh` → `provision-edge.sh`) | Metadata.File registry persists identity; edge coexists with OpenPLC under a systemd memory cap; apikey ≠ edge-id |
| **p4-secure-edge-backend** | wss + mTLS in front of the backend (nginx TLS proxy, internal CA, per-edge client certs) | No OpenEMS code change needed — JVM truststore/keystore flags suffice; apikey confirmed hidden on the wire vs plaintext ws |
| **p5-two-tier-backend** | The newer split backend (2026.6.0, `backend` + `backend-edge`) does NOT accept directly-connected edges with file metadata | Independently reproduces the blockers behind upstream PRs #3795–#3798; validates keeping the monolith pin until they land |

Credentials note: everything in here uses **throwaway local-dev secrets**
(documented in the READMEs). Simulator apikeys equal their edge-ids by
design. The one real device key (`slrp4-09`) has been redacted from
`p1-edge-to-backend/backend/registry/edges.json` — issue a fresh one with
`p2-edge-on-pi/register-edge.sh --rotate` when reproducing the Pi steps.
TLS material for P4 is generated locally by `make-certs.sh` and gitignored.

How this maps to the AWS plan (`docs/aws-arch-v2-plan.md`): P1/P2 are the
local stand-ins for the ECS backend + field edges; the Metadata.File
registry from P2 is played by Odoo in the deployed stack; P4's nginx TLS
proxy is played by the ALB + ACM (PR-C), with its mTLS pattern reserved for
the hardening phase; P5 is the evidence behind the backend version pin
(upgrade trigger documented in the plan).
