# AWS Status & Roadmap — OpenEMS on the eiot account

Where the AWS deployment stands and what's left. Companion to
`docs/aws-deployment-runbook.md` (the *how*) and `docs/aws-arch-v2-plan.md`
(the *why*). Updated 2026-08-17.

- **Account:** `383166698084` (eiot) · **Region:** `us-east-1`
- **Work branch:** `feature/aws-setup` (base `local-deployment`)

---

## 1. What's live right now

The stack is deployed and **PR-C (secure ingress) is complete and validated
end-to-end**.

### Public endpoints
| Purpose | URL | Notes |
|---|---|---|
| OpenEMS UI | **`https://openems.eiot.energy`** | HTTP/2 200, 80→443 redirect, trusted ACM cert |
| Edge / Pi websocket | **`wss://backend.openems.eiot.energy`** | 443, host-routed at the ALB → backend :8081 |
| MBE (Backend2Backend REST) | **`https://b2b.openems.eiot.energy`** | 443, host-routed → backend :8075, HTTP Basic auth |
| Odoo admin | *(no public URL — by design)* | SSM tunnel only, see §4 blocker |

Login: `admin` / the `odoo_password` in Secrets Manager
(`openems-deployment-app-credentials`).

### Architecture (post PR-C)
```
                          ┌─────────────────────── AWS ───────────────────────┐
 browser ──https:443────► │  ALB  ──443──► UI (nginx :8089)                    │
 browser ──wss:8082─────► │ (TLS  ──8082─► Ui.Websocket (:8082)               │
 Pi/edge ──wss:443──────► │  term) ──host backend.* ─► Edge.Websocket (:8081)  │
 MBE     ──https:443────► │        ──host b2b.*     ─► Backend2Backend (:8075) │
                          │           │                                        │
                          │           └─ ECS task (singleton, Fargate/ARM64):  │
                          │              ui · backend · odoo · influxdb        │
                          │              backend ─► RDS Postgres (Odoo `openems`)│
                          │              backend ─► InfluxDB (in-task, EPHEMERAL)│
                          └────────────────────────────────────────────────────┘
 Public: UI, backend.* (edge wss), b2b.* (:8075 REST, Basic auth).
 Internal only: Odoo :8069, InfluxDB :8086, Backend2Backend WS :8079.
```

- The **ALB is the only public entry point.** The task SG accepts 8089/8082/8081/8075
  **from the ALB SG only**; Odoo, InfluxDB, and the B2B websocket (:8079) are not
  publicly reachable.
- **DNS:** `openems.eiot.energy` is delegated from GoDaddy (one NS record) to a
  Route 53 zone; ACM cert (SANs `openems.`, `backend.`, `b2b.`) auto-validates/renews.
- **Terraform:** `iac/alb.tf`, `iac/dns.tf`, `iac/outputs.tf` + edits to
  `ecs.tf`, `provider.tf`, `security-group.tf`, `variables.tf`, `terraform.tfvars`.
  TLS is gated by `enable_tls` (currently `true`).

### Validated 2026-08-14
- UI over HTTPS (200, valid cert, redirect).
- Local sim edge connected via **`ws://<alb>:8081`** (pre-TLS) → `online[1]` → InfluxDB writes.
- Local sim edge reconnected via **`wss://backend.openems.eiot.energy`** (TLS) → `online[1]`.
- Odoo serving (`/web/login` 200, DB list = `["openems"]`); backend→Odoo→RDS auth works.

---

## 2. How to configure a NEW edge

Two halves: register the device in the backend's registry (Odoo), then point the
edge at the backend.

### A. Register the device (backend side, in Odoo)
The device `name` is readonly in the Odoo form (derived from serial in the full
FENECON flow), so create via **Odoo RPC** (or raw SQL, which skips model hooks):

1. Create an `openems.device` record → the model auto-generates a **20-char
   apikey** (`device.py::_generate_api_key`).
2. Assign `openems.device_user_role` to uid 2 so it shows in the Odoo UI.
3. Set `name_number` to the edge's number (this becomes the InfluxDB tag; RPC
   create has historically returned `-1`, so set it explicitly).
4. **Cycle the backend** so it re-caches the registry — it only reads devices at
   startup, so a new edge is "Unable to find edge" until then:
   ```
   aws ecs update-service --cluster openems-deployment-cluster \
     --service openems-deployment-service --force-new-deployment --region us-east-1
   ```
   > TODO: find a runtime metadata-refresh trigger so onboarding doesn't need a redeploy.

### B. Point the edge at the backend (edge side)
On the Pi/edge, edit `config.d/Controller/Api/Backend/<uuid>.config`:
```
uri="wss://backend.openems.eiot.energy"
apikey="<the 20-char key from step 1>"
```
Restart `openems-edge`. **The `wss://backend.openems.eiot.energy` name is stable**
— PR-C fixed the old ephemeral-IP repoint pain, so this URI never changes again.

**Real Pi (SL-RP4) only — one-time CA trust import.** The edge uses a *custom*
Java truststore (`-Djavax.net.ssl.trustStore=/opt/openems-edge/truststore.p12`,
password `changeit`) that does NOT include the Amazon Root CA, so wss to our
ACM-fronted ALB fails with `PKIX path building failed: unable to find valid
certification path`. Import Amazon Root CA 1 (already on the Pi) once:
```
sudo cp /opt/openems-edge/truststore.p12 /opt/openems-edge/truststore.p12.bak.$(date +%s)
sudo /opt/openems-edge/jre/bin/keytool -importcert -noprompt \
  -keystore /opt/openems-edge/truststore.p12 -storetype PKCS12 -storepass changeit \
  -alias amazonrootca1 -file /etc/ssl/certs/Amazon_Root_CA_1.pem
sudo systemctl restart openems-edge
```
(The Pi also ships a client `keystore.p12` — it *can* present a client cert,
which is what future edge mTLS would use.)

### C. Verify
- Edge log: `ctrlBackend0[Connected]`, `Connected to OpenEMS Backend`.
- Backend log (CloudWatch `/ecs/openems-deployment-tds`): `online[1]`.
- InfluxDB receiving writes for that edge's number.

Existing registered devices: `edge0` (name_number 0), `awsedge1` (1), and
`slrp4-09` (9 — the real Pi). **API keys are secrets — never commit them.** Read
them from the Odoo registry when needed (see §2.A / the registry query in the
runbook), e.g. `SELECT name, name_number FROM openems_device`.

> ⚠️ PENDING (security): `slrp4-09`'s API key was briefly committed to this
> public repo and **must be rotated in Odoo** at the next stack start, then the
> Pi's `ctrlBackend0.config` updated with the new key.

---

## 3. Remaining roadmap

Target end-to-end flow:
**Meshems board → Pi (edge) → backend → MBE → generate bill.**

| # | Task | Status | Notes / what's needed |
|---|---|---|---|
| 1 | Configure a new edge | ✅ **Documented** (§2) | Procedure proven with the local sim edge. |
| 2 | Test with the real Pi | ⏳ When Guru is home | Repoint `slrp4-09` to `wss://backend.openems.eiot.energy` (was pinned to an ephemeral task IP). Now stable. |
| 3 | Register with **MBE** | ⏳ TBD | Guru to define MBE. Connects via Backend2Backend (`:8075` REST / `:8079` ws) — currently internal-only; may need ingress/wiring. |
| 4 | Meshems board → MQTT → Pi | 🟡 **Half done (2026-08-17)** | Board→MQTT→broker-on-Pi **works**; Mosquitto installed on `slrp4`. The **edge does not consume it yet** — needs a new component. See §6 and `meshems-openami-metering/docs/MQTT_SIM_LAB.md`. |
| 5 | SunSpec config + end-to-end | ⏳ After 4 | Board already emits SunSpec-shaped JSON (models 11 / 213), so this largely folds into the §6 component. Validate Meshems→Pi→backend→MBE→**bill**. |
| 6 | **InfluxDB persistence** | ❗ **Open gap** | Telemetry is in-task and **lost on every task replacement** (deploy/restart). See §5. |

---

## 4. Open blocker — Odoo browser access

Odoo is confirmed healthy but **not reachable from a browser**: the SSM
port-forward path fails because our SSO deploy role has `ecs:ExecuteCommand`
(ECS Exec works) but **not `ssm:StartSession`**. Because it's an AWS-managed SSO
reserved role, the fix is on the **Identity Center permission set**, not an
inline policy we can add ourselves.

**Fix (admin action):** add to the `eiot-openems-devops` permission set inline
policy, then re-provision:
```json
{ "Effect": "Allow", "Action": "ssm:StartSession",
  "Resource": [
    "arn:aws:ecs:us-east-1:383166698084:task/openems-deployment-cluster/*",
    "arn:aws:ssm:us-east-1:383166698084:document/AWS-StartPortForwardingSession" ] },
{ "Effect": "Allow", "Action": ["ssm:TerminateSession","ssm:ResumeSession"],
  "Resource": "arn:aws:ssm:us-east-1:383166698084:session/${aws:userid}-*" }
```
After it's live: `aws ssm start-session --target ecs:openems-deployment-cluster_<taskId>_<runtimeId>
--document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["8069"],"localPortNumber":["8069"]}'`
→ open `http://localhost:8069`.

---

## 5. Known gaps / future hardening

- **InfluxDB persistence (task #6, PR-B).** InfluxDB runs *inside* the task with
  ephemeral storage — a deploy/restart wipes all telemetry history. Simplest fix
  on Fargate: mount an **EFS volume** to the influxdb container at
  `/var/lib/influxdb` (survives task replacement, no EC2 needed). The larger PR-B
  question — move to a managed timeseries store (Timestream) vs. self-hosted on
  EC2 — is separate and can come later.
- **mTLS for edges (optional, PR-E).** Today edge↔backend is encrypted wss +
  apikey. Adding client-cert mTLS is defense-in-depth, not a gap. Two catches:
  (1) ALB mTLS is per-listener, so edges need a **dedicated listener** (not the
  shared 443); (2) the stock OpenEMS edge has no client-cert option, so each Pi
  likely needs a local TLS proxy (stunnel) — **verify before committing**. Use a
  self-managed CA + S3 trust store (avoid ACM Private CA, ~$400/mo).
- **Deploy-role ACM gaps.** The SSO deploy role lacks `acm:AddTagsToCertificate`
  (worked around with the `untagged` provider alias) and `acm:DeleteCertificate`.
  The latter means whenever the cert changes (e.g. adding a SAN), the old cert
  can't be auto-deleted — Terraform leaves a harmless orphaned cert and the
  apply errors at the very end (everything else applies). Fix: add
  `acm:DeleteCertificate` to the `eiot-openems-devops` permission set (bundle it
  with the `ssm:StartSession` change in §4), then a re-apply clears the orphan.
- **RDS re-hardening before prod.** `deletion_protection=false`,
  `skip_final_snapshot=true`, `backup_retention=1` were buildout settings — flip
  before the field registry (edges/apikeys live here) holds anything real.
- **B2B auth hardening (before real customer data).** `https://b2b.openems.eiot.energy`
  currently authenticates as the shared `admin` user over HTTP Basic, no IP
  allow-list (Vercel egress isn't static). Before real data: create a **dedicated
  least-privilege OpenEMS/Odoo user** for MBE (read-only, scoped to its edges),
  and consider an **ALB WAF rate-limit** on the `b2b` host against
  brute/credential-stuffing.
- **API keys are secrets.** A field-edge apikey was briefly committed here and is
  being rotated (see §2). Never put real apikeys/passwords in the repo — read
  them from Odoo/Secrets Manager at use time.
- **AWS account ID in a public repo** is a conscious decision (it's a low-
  sensitivity identifier, not a credential, and the Terraform backend block
  can't take a variable). To scrub it later: move the state-bucket name to
  partial backend config and placeholder the docs.
- **Cost control:** `./iac/stack-power.sh {start|stop|status}` (ECS desired-count
  + RDS start/stop). The stack is currently **OFF** (stopped 2026-08-16).
