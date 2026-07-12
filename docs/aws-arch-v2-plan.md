# AWS Architecture v2 — Production Plan (piecewise)

**Status:** Draft — for team approval
**Branch:** `feature/aws-arch-v2` (based on `local-deployment`)
**Date:** 2026-07-12
**Supersedes/extends:** `docs/aws-production-architecture.md` (2026-04-15 draft)

Strategy: **strangler-fig, not big-bang.** First make the existing
single-task ECS deployment actually work (it cannot boot today — see PR-A),
with state moved to RDS so it's a stable base to test against. Then each
subsequent PR extracts one component. Every PR is independently reviewable,
leaves the system working, and has an explicit cost delta and exit test.

A key shape change from the current stack: **the edge container is removed
from AWS entirely.** Edges are external by definition — the SL-RP4 in the
field, or a simulated edge on a laptop — connecting in over the backend's
edge websocket. AWS runs only the cloud side (backend, Odoo, UI, data
stores). Simulated edges for demos run locally via `setup.sh` or, if ever
needed in-cloud, as a separate non-prod stack.

---

## Standing architecture decisions

These hold across all PRs; each lands in the PR where it becomes relevant.

### D1 — Backend version: pin 2026.1.0; edges track latest

"Latest backend" is not usable with our stack today:

- From **2026.2.0** the backend split into two tiers (backend jar with
  `Edge.Manager` :8093 + separate `openems/backend-edge` gateway :8081);
  the released jar alone cannot accept edges.
- 2026.2.0 release notes, verbatim: *"large changes to the OpenEMS Backend
  authentication flow to Odoo and KeyCloak … not yet included in the
  Odoo-Addon and the Docker-Compose setups. For now it is recommended to use
  older OpenEMS Backend (namely 2026.1.0) to prevent problems and cyber
  security risks."* Our vendored addon (`odoo/addons/openems`, 16.0.1.0.1)
  predates that rework.
- The unblock PRs are **not merged** as of 2026-07-12:
  [#3795](https://github.com/OpenEMS/openems/pull/3795) /
  [#3796](https://github.com/OpenEMS/openems/pull/3796) closed unmerged,
  [#3797](https://github.com/OpenEMS/openems/pull/3797) /
  [#3798](https://github.com/OpenEMS/openems/pull/3798) still open.
  `~/pi-dev/prototypes/p5-two-tier-backend` reproduced the breakage
  independently on stock 2026.6.0.

Edge↔backend JSON-RPC is stable across releases (verified in pi-dev P1:
2026.6 edge ↔ 2026.1 backend), so **edges run latest (2026.7.0)**.

**Upgrade trigger (→ PR-E):** #3797/#3798 (or equivalents) merged AND the
Odoo addon ships the new auth flow. The two-tier gateway then slots in as one
extra ECS service on the same edge endpoint.

### D2 — The backend is a singleton; HA = fast replacement, not replicas

The monolithic backend cannot run as N replicas: each edge holds one
persistent websocket, and two backends behind one endpoint would split the
fleet and double-write InfluxDB (load-balancing edge connections is exactly
what upstream's two-tier split is for). Therefore:

- `desired_count = 1`, deployment `minimum_healthy_percent = 0`,
  `maximum_percent = 100` (stop-then-start; never two writers).
- Deploy/recovery downtime ≈ 1–2 min task replacement. Edges tolerate it:
  they buffer locally (RRD4J) and auto-reconnect (P1/P2 verified).
- **Accepted, monitored risk:** cloud-side telemetry gap during backend
  downtime — upstream resend/backfill to plain InfluxDB is broken (#3798).
  The data still exists on the edge. Mitigation: rare fast deploys + a gap
  alarm (PR-E).

### D3 — Data placement

- **RDS Postgres** = the Odoo database only: `openems_device` registry (edge
  names + apikeys), users/partners, setup protocols, mail. Never telemetry.
- **InfluxDB** = all telemetry history (`Timedata.InfluxDB`,
  `queryLanguage=INFLUX_QL` — the P1-proven combination).
- **RRD4J on each edge** = local buffer riding out backend outages.

### D4 — Terraform hygiene

The existing `iac/` state has drifted (task-def revision 8 was iterated by
the pipeline outside Terraform). Task definitions become Terraform-owned
again in PR-A; the CI "render + deploy" flow updates images only. Same S3
state bucket + DynamoDB lock table (that is all they're used for).

---

## The PRs

### PR-A — The base: CI safety + working monolith + RDS (combined)

One PR so there's a testable, durable base to build on. Three parts:

**A1. CI/CD safety** *(merge-blocking for everything else)*
- `destroy-pipeline.yml`: `workflow_dispatch` only, with a typed
  confirmation input. **Today it runs `terraform destroy` on every push to
  main, racing the deploy pipeline.**
- Remove the broken `if: needs.deploy_aws_infrastructure.output.…` guards
  (the path doesn't exist, so they're always true — the destroy pipeline
  currently also builds and deploys).
- Fix the task-def render chain: odoo-db is rendered with the **odoo** image
  (`IMAGE_NAME_VALUE_4` used twice), and the final deploy step uses
  `render-backend-container`'s output — silently dropping the odoo, odoo-db,
  and edge image updates.
- Replace long-lived AWS keys with GitHub OIDC → IAM role (if org policy
  allows; otherwise keep keys, scoped down).

**A2. Make the monolith task actually boot** *(port `local-deployment`'s
proven compose topology into ECS)*
- **Remove the `edge` container** from the task definition, Terraform, and
  pipeline (edges are external — see intro).
- Fix in-task addressing: containers in one Fargate task share a network
  namespace, so compose-style hostnames (`HOST=db`, `pgHost=db`,
  `odooHost=odoo16`) all become **`localhost`**.
- Backend config aligned with `local-deployment`: `Metadata.Odoo` +
  `Timedata.InfluxDB` (not Dummy/embedded).
- Add an `influxdb:1.8` container to the task. ⚠️ **Telemetry is ephemeral
  until PR-B** (lost on task replacement) — acceptable for the test base,
  not for customers.
- Correct `essential` flags (backend, odoo, influxdb essential — today only
  the UI is) and container health checks; task right-sized to
  2 vCPU / 6 GB.

**A3. Odoo state → RDS** *(the extraction that makes the base durable)*
- Security group fix: RDS rule is **3306 (MySQL) but the DB is Postgres** —
  becomes 5432, source = the task SG only (no CIDR). Today the app literally
  cannot reach RDS.
- Credentials into **Secrets Manager**, injected via ECS `secrets`; removes
  the hardcoded and mismatched passwords (`openemspassword` vs
  `openempassword`) from tfvars/task-def.
- Odoo (`HOST`) and backend (`Metadata.Odoo` `pgHost`) point at the RDS
  endpoint; **drop the odoo-db container** from the task.
- RDS production settings: deletion protection, automated backups (14 d),
  `skip_final_snapshot = false`. (Multi-AZ can wait for PR-E cost review.)

**Cost delta:** ~$0 (RDS already runs; task shrinks 4/12 → 2/6).
**Exit test:** push to main deploys cleanly (and cannot destroy); UI loads
via the task's public IP; Odoo admin reachable (temporarily) and shows the
OpenEMS app; a **local edge connects from outside AWS** (see runbook below)
and its data appears live in the UI; redeploy the task → edge registry and
users still intact (RDS), edge reconnects by itself.

#### Testing with a local edge against the AWS base

Until PR-C there's no domain/TLS — the edge connects to the task's public IP
over plaintext `ws://` with its apikey. Fine for testing; **not for real
customer edges** (that's PR-C's gate).

1. Get the task's current public IP (changes on every deploy):
   `aws ecs list-tasks / describe-tasks` → ENI → public IP.
2. Register the edge in Odoo (OpenEMS app → Devices → Create; name must end
   in globally-unique digits, e.g. `guru-lap-01` — the number becomes the
   InfluxDB tag). The 20-char apikey is generated on save; no restart needed
   (`Metadata.Odoo` queries live — unlike P2's read-once `Metadata.File`).
3. Run a local edge (compose sim edge from this repo, or a Pi via
   `~/pi-dev` `provision-edge.sh`) with
   `BACKEND_URI=ws://<task-public-ip>:8081` and the apikey.
4. Verify the pi-dev ladder: edge log `ctrlBackend0[Connected]` → backend
   log `Edge [guru-lap-01]: Update version …` → live data in the UI (login
   with an Odoo user linked to the device).

### PR-B — InfluxDB out of the task

Replace the in-task `influxdb:1.8` with a managed store; after this the task
is fully stateless and telemetry survives deploys.

Where people generally host InfluxDB on AWS, ranked:
1. **Amazon Timestream for InfluxDB** — managed InfluxDB 2.7 (GA 2024):
   backups, optional Multi-AZ, VPC-private endpoint. ~$70–90/mo small.
   Works with OpenEMS via v2 token + `INFLUX_QL` + a DBRP mapping (P1-proven).
2. **Self-hosted EC2 + EBS** (t4g.small + gp3) — ~$18/mo; what much of the
   OpenEMS community runs; we own patching + EBS-snapshot backups.
3. ECS + EFS — TSDB on NFS latency; avoid.
4. InfluxDB Cloud SaaS — external dependency + egress; avoid.

**Recommendation: Timestream for InfluxDB** (needs budget sign-off — open
question Q2). SG: 8086 from the task SG only. Local dev compose unchanged.
**Cost delta:** +$70–90/mo (or +$18 on EC2).
**Exit test:** force-replace the task → history query (`probe_history.py`
pattern / UI history view) returns pre-replacement data.

### PR-C — Ingress: Route 53 + ACM + ALB (wss). Gate for field edges.

- ACM cert (auto-renewing) on an ALB, one HTTPS :443 listener, host routing:
  `ems.<domain>` → ui:8089 · `ui-ws.<domain>` → backend:8082 (the UI nginx
  is static-only; the browser dials the backend websocket directly) ·
  **`edge.<domain>` → backend:8081 — edges now use `wss://`**.
- Public cert ⇒ edge JVMs trust it natively — **no truststore /
  `--backend-ca` flags** (improvement over P4's private-CA setup).
- ALB idle timeout ≥ 300 s; health checks (backend :8075, ui :8089, odoo
  `/web/health`).
- Close everything: ALB SG :443 from internet; task SG app ports from ALB SG
  only; task loses its public exposure. Odoo admin (:8069) internal-only via
  SSM port-forward.
- mTLS (per-edge client certs, P4's second half) deliberately deferred to
  PR-E; apikey-over-wss is the interim posture.

**Cost delta:** ~$20–25/mo (ALB + hosted zone).
**Exit test:** local edge and the SL-RP4 connect via `wss://edge.<domain>`;
plaintext `ws://` path no longer reachable; UI works over HTTPS; first field
Pi onboarded end-to-end using the PR-A runbook with the wss URL.

### PR-D — Split the task (one component per sub-PR)

- **D-1: UI out** → own tiny service (2 × 0.25 vCPU) or S3 + CloudFront.
- **D-2: Odoo out** → own service; requires **EFS** for the Odoo filestore
  (attachments/assets are on-disk and currently die with the task) and
  **ECS Service Connect** so the backend's `odooHost` resolves across tasks.
  Odoo can later scale to 2 tasks (ALB sticky sessions; EFS already shared).
- Remainder: the backend alone in its task — a true singleton with the D2
  stop-then-start deploy policy.

**Cost delta:** +$15–25/mo (extra tasks + EFS), partially offset by
shrinking the backend task.
**Exit test:** deploy the UI alone — backend/odoo tasks untouched, no edge
disconnect.

### PR-E — Observability, hardening, and the deferred items

- CloudWatch alarms: backend task restarts, edge-fleet disconnect count,
  **telemetry-gap alarm** (D2's accepted risk gets a pager), RDS/EFS/ALB
  standard alarms; a dashboard; log retention.
- **SES** (domain-verified) for the Odoo addon's alerting emails
  (edge-offline, fault state) and user registration — request production
  sending early, it has lead time.
- RDS Multi-AZ + NAT/VPC-endpoint cost review (Q3).
- **mTLS** per edge: ALB native mutual-TLS trust store, or NLB passthrough →
  nginx `ssl_verify_client` (exact P4 pattern). Cert issuance joins the
  registration flow.
- **Two-tier backend migration** when D1's trigger fires: `backend-edge`
  gateway becomes a new ECS service taking over `edge.<domain>`; backend
  drops :8081. WAF on the ALB.

---

## Open questions (need answers before the marked PR)

| # | Question | Blocks |
|---|---|---|
| Q1 | Which domain / Route 53 zone? (P1 notes mention Aaron's `openems.nearlyfreeenergy.com` test backend) | PR-C |
| Q2 | InfluxDB: Timestream (~$70–90/mo, zero ops) vs EC2+EBS (~$18/mo, we operate) | PR-B |
| Q3 | NAT: per-AZ (≈$70/mo) vs single (≈$35/mo); and is prod a separate AWS account? | PR-E (review) |
| Q4 | Who besides engineering needs Odoo admin? (SSM tunnel only vs internal listener + SSO) | PR-C |
