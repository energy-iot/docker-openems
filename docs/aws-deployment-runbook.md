# AWS Deployment Runbook — OpenEMS on the eiot account

Operational guide for the OpenEMS stack deployed to AWS. Companion to
`docs/aws-arch-v2-plan.md` (the *why*); this is the *how*.

- **Account:** `383166698084` (eiot) · **Region:** `us-east-1`
- **Deploy identity (SSO):** `eiot-openems-devops-383166698084`
- **Work branch:** `feature/aws-setup` (base `local-deployment`)

> ⚠️ Everything here targets a real AWS account. Confirm before running
> anything mutating. All AWS commands assume:
> ```
> aws sso login --profile eiot-openems-devops-383166698084
> export AWS_PROFILE=eiot-openems-devops-383166698084 AWS_DEFAULT_REGION=us-east-1
> ```

---

## 1. What's deployed

One ECS Fargate task (**ARM64/Graviton**) with four containers sharing one
network namespace (they talk over `localhost`):

| Container | Purpose | Ports |
|---|---|---|
| `openems-ui` | nginx serving the Angular dashboard | 8089 |
| `openems-backend` | the hub | 8081 edge-ws, 8082 ui-ws, 8075 B2B REST, 8079 B2B ws |
| `odoo` | metadata/registry app + XML-RPC | 8069 |
| `influxdb` | telemetry store (in-task, **ephemeral** — see §7) | 8086 (localhost only) |

Plus: **RDS Postgres** (`odoodb` instance; the app DB is `openems`) — private,
reachable only from the task SG · **Secrets Manager** (`openems-deployment-app-credentials`)
· **ECR** (`openems-ui`, `openems-backend`, `odoo`) · CloudWatch Logs
(`/ecs/openems-deployment-tds`) · VPC/subnets/SGs. **No NAT gateway** (removed —
RDS needs no egress). Edges are **external** (field Pis / laptop sims), not in AWS.

Data split: **RDS/Odoo** = identity (edge registry + apikeys, users);
**InfluxDB** = telemetry.

---

## 2. Prerequisites (one-time, local)

- `aws` CLI v2 + the **Session Manager plugin** (`brew install --cask session-manager-plugin`) — needed for ECS Exec.
- **Terraform 1.14.1** via tfenv: `brew install tfenv && tfenv install 1.14.1 && tfenv use 1.14.1`.
- Docker Desktop (for building images).
- The `eiot-openems-devops-383166698084` SSO profile configured.

---

## 3. First-time bootstrap (already done for this account)

1. **State bucket** — Terraform can't create its own backend. Run once:
   ```
   ./iac/bootstrap-state-bucket.sh    # creates eiot-openems-tfstate-383166698084 (versioned, encrypted, TLS-only)
   ```
2. **Provision the infra:**
   ```
   cd iac && terraform init && terraform plan   # review
   terraform apply
   ```
3. **Create ECR repos + push images** — see §4.
4. **Initialize the Odoo DB** — see §5. (Required before the backend is fully functional.)

---

## 4. Build & push images

The task is **ARM64**, so images must be arm64. On Apple Silicon they build
native; on x86 use `docker buildx --platform linux/arm64`.

```
docker compose -f docker-compose.yml build openems-ui openems-backend odoo16
aws ecr get-login-password | docker login --username AWS --password-stdin 383166698084.dkr.ecr.us-east-1.amazonaws.com
./push-to-ecr.sh
```

**Gotchas:**
- **Arch must match the task.** arm64 images on an X86_64 task → `exec format error`. (We set the task to ARM64 to match Apple-Silicon builds.)
- **Docker Desktop's egress proxy drops large layers** — big pushes (odoo ~1.7 GB) may fail with "use of closed network connection." Retry (per-layer resume) on a stable/fast connection. **The right long-term fix is CI** (GitHub runners have clean egress + are x86 — would need `--platform arm64` or ARM runners, and an OIDC deploy role: admin must create the OIDC provider; we can create the role).
- **zsh mangles `$IMG:latest`** (the `:l` modifier). Always `${IMG}:latest` with braces.

---

## 5. Initialize the Odoo DB (one-time per fresh RDS)

RDS is **private**, so DB work happens **inside a container via ECS Exec**
(the container is the bastion). Helper to get a task + exec:

```
T=$(aws ecs list-tasks --cluster openems-deployment-cluster --desired-status RUNNING --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster openems-deployment-cluster --task $T \
  --container openems-deployment-container-odoo --interactive --command "/bin/sh"
```
> ECS Exec sessions are non-TTY here and **truncate stdout to ~the first line** —
> for multi-line results, write to a file or verify separately. For SQL with
> quotes, **base64-encode** it to dodge the shell-quoting layers.

Three steps, in order:

**a. Create + install the app DB** (from inside the odoo container):
```
odoo -d openems -i openems --stop-after-init --db_host=$HOST --db_user=$USER --db_password=$PASSWORD
```

**b. Set the Odoo admin password to the Secrets Manager value.** The backend
authenticates to Odoo (uid 2) with the random `odoo_password`; Odoo's admin
still has its init default → writes fail `Access Denied [3]`. Fix (XML-RPC as
`admin`/`admin`, set to the secret):
```
TARGET=$(aws secretsmanager get-secret-value --secret-id openems-deployment-app-credentials --query SecretString --output text | python3 -c "import json,sys;print(json.load(sys.stdin)['odoo_password'])")
# then, inside the odoo container, authenticate admin/admin and write password=$TARGET to uid 2
```
After this: **Odoo login = `admin` / `<odoo_password>`** (not `Icui4cyou` — that's local-only).

**c. Drop the `odoodb` placeholder.** RDS auto-creates an empty DB named after
`initial_database_name` (`odoodb`); Odoo then sees two DBs and **500s on login**.
Drop it (or set Odoo `dbfilter=openems`):
```
psql -h $HOST -U $USER -d openems -c "DROP DATABASE IF EXISTS odoodb;"
```

**d. Cycle the backend** so it re-caches the registry (see §6's note).

---

## 6. Register an edge

**Formal way (UI):** Odoo (`http://<ip>:8069`, login from §5b) → **OpenEMS →
OpenEMS Edge → Devices → Create**. Note the device **Name is readonly** in the
form (derived from a serial/`stock.lot` in the full FENECON flow).

**Practical way (RPC) — recommended for one-off / automation:** create an
`openems.device` via Odoo RPC; the model **auto-generates a 20-char apikey**.
Set the `name` (must end in **globally-unique digits** → InfluxDB tag) and
**fix `name_number`** afterward (RPC create returns `-1`). Optionally add an
`openems.device_user_role` (uid 2, `admin`) for UI visibility.

**Point the edge at the backend** (on the Pi, over `ssh slrp4`):
```
BC=$(find /opt/openems-edge -path "*Controller/Api/Backend*" -name "*.config" | head -1)
sudo sed -i 's|^uri=.*|uri="ws://<current-ip>:8081"|' "$BC"
sudo sed -i 's|^apikey=.*|apikey="<generated-apikey>"|' "$BC"
sudo systemctl restart openems-edge
```

> **The backend caches the registry only at STARTUP.** A device added *after*
> the backend booted yields `Unable to find edge with id [...]`. Cycle the
> backend to re-cache: `aws ecs update-service --cluster openems-deployment-cluster
> --service openems-deployment-service --force-new-deployment`. (This also
> changes the public IP — see §7.) Onboarding shouldn't require this; finding a
> metadata-refresh trigger is a follow-up.

**Verify:** backend logs `Edge [<name>]: Update version …` and `online[N]`;
InfluxDB accepting writes (`POST /api/v2/write … 204`).

---

## 7. Operations

**Start / stop (cost control):**
```
./iac/stack-power.sh stop     # ECS -> 0 + RDS stop  (~$2-3/mo idle; script asserts the eiot account)
./iac/stack-power.sh start    # RDS start + ECS -> 1
./iac/stack-power.sh status
```
For true $0: `terraform destroy` (rebuild ~10 min; ECR images persist).

**Get the current public IP** (⚠️ **ephemeral — changes on every task
start/redeploy**; edges must be repointed each time until PR-C adds a stable
DNS name):
```
T=$(aws ecs list-tasks --cluster openems-deployment-cluster --desired-status RUNNING --query 'taskArns[0]' --output text)
ENI=$(aws ecs describe-tasks --cluster openems-deployment-cluster --tasks $T --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value|[0]" --output text)
aws ec2 describe-network-interfaces --network-interface-ids $ENI --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```

**Retrieve credentials:**
```
aws secretsmanager get-secret-value --secret-id openems-deployment-app-credentials --query SecretString --output text
```

**Logs:** `aws logs tail /ecs/openems-deployment-tds --since 10m --follow`
(backend + odoo + influxdb interleaved; Odoo's own tracebacks go to a file
*inside* the container — read via ECS Exec `tail /etc/odoo/odoo-server.log`).

**DB access:** ECS Exec into the odoo container (has `psql` + RDS creds in env).

---

## 8. Gotchas (learned the hard way)

- **Local vs AWS passwords differ.** Local/`setup.sh` = hardcoded `Icui4cyou`
  everywhere. AWS = random per-deploy Secrets Manager values. Nothing on AWS
  uses `Icui4cyou`.
- **IAM policies must be inline** (`aws_iam_role_policy`), never standalone
  managed (`aws_iam_policy`) — the deploy role lacks `iam:TagPolicy`, which
  Terraform's `default_tags` require on a managed policy.
- **`odoodb` placeholder** → Odoo 500s until dropped (§5c).
- **Odoo admin password mismatch** → `Access Denied [3]` on writes (§5b).
- **OpenEMS dashboard `crypto.randomUUID is not a function`** over plain HTTP —
  that UI needs a **secure context (HTTPS)**; it only works once behind the ALB
  + ACM cert (PR-C). Odoo (`:8069`) is unaffected.
- **Ephemeral task IP** + **backend caches registry at startup** — the two
  reasons edge onboarding currently needs a redeploy + repoint.

---

## 9. Known limitations / follow-ups

- **PR-C — ALB + ACM + Route 53** (`wss://edge.eiot.energy`): stable DNS (fixes
  the ephemeral-IP repoint dance), TLS (`wss://` for edges, HTTPS for the UI —
  fixes `crypto.randomUUID`), closes the direct ports. `eiot.energy` zone + ACM
  already exist in-account.
- **PR-B — durable InfluxDB.** In-task InfluxDB is **wiped on every task
  replacement**. Options: EFS-mounted in-task (simplest, persistent across
  restarts, but InfluxDB-on-NFS mmap/locking is officially discouraged — OK for
  light single-writer load) · EC2 + EBS (block storage, DB-safe, a box to
  manage) · Timestream for InfluxDB (managed, $$, 2.x migration).
- **Re-harden RDS** before real data: `deletion_protection=true`,
  `skip_final_snapshot=false`, longer backups (currently buildout settings).
- **CI build+push via GitHub OIDC** — replaces the manual local push (admin
  creates the OIDC provider; we create the role).
- **Backend registry re-cache trigger** — so onboarding an edge doesn't require
  cycling the task.
- **Odoo service account** — the backend authenticates as `admin` with a
  password; an **Odoo API key** (or a least-privilege service user) would
  decouple the RPC credential from the login password.
