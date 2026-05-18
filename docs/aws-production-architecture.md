# AWS Production Architecture Plan

**Status:** Draft — iterating with team
**Last updated:** 2026-04-15
**Authors:** Alejandro Malbet, Claude (architect)

---

## 1. Overview

This document describes the production deployment architecture for the OpenEMS + MBE (Metering & Billing Engine) platform on AWS, with secure connectivity for field-deployed Raspberry Pi edge devices via OpenVPN.

### Goals

1. Deploy the OpenEMS Backend stack to AWS with proper network isolation
2. Deploy MBE to the same VPC for private backend-to-billing communication
3. Connect physical Raspberry Pi edge devices at microgrid sites via OpenVPN
4. Maintain simulation edges on AWS for testing/demo purposes
5. Build on the existing Terraform IaC in `iac/`

### Non-goals (for this phase)

- Multi-region or HA deployment (single-region MVP)
- Auto-scaling for any service
- Automated edge provisioning (manual setup per Pi)
- Migrating Supabase from cloud-hosted to self-hosted

---

## 2. Current State

### What exists today

| Component | Current state | Location |
|-----------|--------------|----------|
| OpenEMS Backend + UI + Odoo | Docker Compose on local machine | `docker-compose.yml`, `setup.sh` |
| Simulation edges | Docker containers (up to 9) | Same Docker network as backend |
| MBE | Next.js on Vercel + cloud Supabase | `energy-iot/metering-billing-engine` |
| Terraform IaC | VPC, ECS Fargate, RDS, security groups | `iac/` directory |
| CI/CD | GitHub Actions → ECR → ECS | `.github/workflows/` |

### Existing Terraform infrastructure (`iac/`)

The repo already has Terraform that provisions:

- **VPC:** `10.0.0.0/16` with 2 public subnets (`10.0.0.0/24`, `10.0.1.0/24`) and 2 private subnets (`10.0.2.0/24`, `10.0.3.0/24`) in us-east-1
- **ECS Fargate cluster:** Single task definition with UI, backend, edge, and Odoo containers (4096 CPU, 12GB RAM)
- **RDS PostgreSQL:** `db.t3.micro` in private subnet for Odoo
- **Security groups:** All ports open to `0.0.0.0/0` (needs hardening)
- **ECR:** Container registry for all images
- **GitHub Actions:** Build → Trivy scan → push to ECR → deploy to ECS

### Key gaps in existing infra

1. **Security groups are wide open** — every port allows `0.0.0.0/0`. Production needs least-privilege rules.
2. **No VPN** — no mechanism for field edges to connect securely.
3. **No TLS on internal traffic** — B2B REST endpoint is plaintext HTTP.
4. **No MBE** — billing engine not in the VPC.
5. **No InfluxDB** — existing ECS task definition doesn't include InfluxDB (needed for time-series meter data).
6. **Hardcoded credentials** — RDS password in `terraform.tfvars`, Odoo password in task definition.
7. **ECS Fargate may not support OpenVPN server** — Fargate lacks `NET_ADMIN` capability. May need EC2 launch type or a separate EC2 instance for VPN.

---

## 3. Target Architecture

```
                          Internet
                             |
                    ┌────────┴────────┐
                    │   Route 53      │
                    │  (DNS records)  │
                    └───┬─────────┬───┘
                        |         |
                   ┌────┴───┐ ┌──┴──────┐
                   │ALB/MBE │ │OpenVPN  │
                   │(HTTPS) │ │UDP:1194 │
                   └────┬───┘ └────┬────┘
                        |          |
   ┌────────────────────┼──────────┼──────────────────────┐
   │                AWS VPC  10.0.0.0/16                  │
   │                                                       │
   │  ┌──────────── Public Subnets ──────────────────┐    │
   │  │  ALB (HTTPS termination)                     │    │
   │  │  NAT Gateway (outbound for private subnet)   │    │
   │  │  OpenVPN Server (EC2, UDP:1194)               │    │
   │  └──────────────────────────────────────────────┘    │
   │                                                       │
   │  ┌──────────── Private Subnets ─────────────────┐    │
   │  │                                               │    │
   │  │  ┌─────────────────────────────────────────┐  │    │
   │  │  │  ECS Fargate: OpenEMS Backend Stack     │  │    │
   │  │  │  ┌──────────┐ ┌─────────┐ ┌──────────┐ │  │    │
   │  │  │  │ Backend  │ │  Odoo   │ │InfluxDB  │ │  │    │
   │  │  │  │ :8082    │ │ :8069   │ │ :8086    │ │  │    │
   │  │  │  └──────────┘ └─────────┘ └──────────┘ │  │    │
   │  │  │  ┌──────────┐ ┌──────────┐             │  │    │
   │  │  │  │ Sim Edge │ │ Sim Edge │  (testing)  │  │    │
   │  │  │  │    0     │ │    1     │             │  │    │
   │  │  │  └──────────┘ └──────────┘             │  │    │
   │  │  └─────────────────────────────────────────┘  │    │
   │  │                                               │    │
   │  │  ┌─────────────────────────────────────────┐  │    │
   │  │  │  ECS Fargate: MBE                       │  │    │
   │  │  │  ┌───────────┐                          │  │    │
   │  │  │  │  Next.js  │──── private ────▶ Backend│  │    │
   │  │  │  │  :3000    │     (HTTP:8082)          │  │    │
   │  │  │  └───────────┘                          │  │    │
   │  │  └─────────────────────────────────────────┘  │    │
   │  │                                               │    │
   │  │  ┌─────────────┐                              │    │
   │  │  │  RDS Postgres│ (Odoo DB, private)          │    │
   │  │  └─────────────┘                              │    │
   │  └───────────────────────────────────────────────┘    │
   └───────────────────────────────────────────────────────┘
                        |
                   OpenVPN tunnel
                   (UDP:1194)
                        |
        ┌───────────────┼───────────────┐
        |               |               |
   ┌────┴─────┐   ┌────┴─────┐   ┌────┴─────┐
   │ Kisakye  │   │ Site 2   │   │ Site N   │
   │          │   │          │   │          │
   │ ┌──────┐ │   │ ┌──────┐ │   │ ┌──────┐ │
   │ │Raspi │ │   │ │Raspi │ │   │ │Raspi │ │
   │ │Edge  │ │   │ │Edge  │ │   │ │Edge  │ │
   │ │OpenVPN│ │   │ │OpenVPN│ │   │ │OpenVPN│ │
   │ └──┬───┘ │   │ └──┬───┘ │   │ └──┬───┘ │
   │    |     │   │    |     │   │    |     │
   │ ┌──┴───┐ │   │ ┌──┴───┐ │   │ ┌──┴───┐ │
   │ │Meters│ │   │ │Meters│ │   │ │Meters│ │
   │ │Modbus│ │   │ │Modbus│ │   │ │Modbus│ │
   │ └──────┘ │   │ └──────┘ │   │ └──────┘ │
   └──────────┘   └──────────┘   └──────────┘
```

---

## 4. Component Details

### 4.1 OpenVPN Server

**Why OpenVPN over WireGuard:** Team preference for OpenVPN. OpenVPN has broader compatibility with embedded devices, mature tooling for certificate management, and well-documented Raspberry Pi client support.

**Deployment option: EC2 instance (not Fargate)**

ECS Fargate does not support the `NET_ADMIN` Linux capability required to create TUN/TAP devices. The OpenVPN server must run on an EC2 instance.

| Setting | Value |
|---------|-------|
| Instance type | `t3.micro` (VPN traffic is lightweight) |
| Subnet | Public (needs a public IP for edge devices to reach it) |
| Port | UDP 1194 |
| VPN subnet | `10.8.0.0/24` |
| Protocol | UDP (faster, handles packet loss better than TCP for VPN) |
| Auth | Certificate-based (PKI with Easy-RSA) |

**VPN network design:**

```
VPN Subnet: 10.8.0.0/24
  10.8.0.1    — OpenVPN server
  10.8.0.2    — Kisakye Raspberry Pi (edge0)
  10.8.0.3    — Site 2 Raspberry Pi (edge1)
  ...
  10.8.0.N    — Site N-1 Raspberry Pi
```

**Routing:** The OpenVPN server pushes a route for `10.0.0.0/16` (VPC CIDR) to clients, so edge devices can reach the backend in the private subnet. The VPC route table needs a return route for `10.8.0.0/24` pointing to the OpenVPN EC2 instance.

**Certificate management:**

```
PKI Structure (Easy-RSA):
  ca.crt / ca.key           — Certificate Authority
  server.crt / server.key   — OpenVPN server
  edge0.crt / edge0.key     — Kisakye Pi
  edge1.crt / edge1.key     — Site 2 Pi
  ...
```

Each edge site gets a unique client certificate. Revocation is handled via CRL (Certificate Revocation List) if a device is compromised or decommissioned.

### 4.2 OpenEMS Backend Stack (ECS Fargate)

Continues on ECS Fargate as in the existing Terraform. Changes from current state:

| Change | Current | Target |
|--------|---------|--------|
| InfluxDB | Missing | Add as sidecar container (or separate ECS service with EFS for persistence) |
| Security groups | All ports open to `0.0.0.0/0` | Restrict: 8082 from VPC CIDR + VPN CIDR only |
| Backend websocket (8081) | Not configured | Allow from VPN CIDR (`10.8.0.0/24`) only |
| Credentials | Hardcoded in tfvars | AWS Secrets Manager |
| UI access | Port 8089 open to internet | Behind ALB with HTTPS |

**InfluxDB persistence consideration:** ECS Fargate doesn't support persistent local storage. Options:
1. **EFS mount** — attach an EFS volume to the InfluxDB container (simplest)
2. **Separate EC2** — run InfluxDB on the same EC2 as OpenVPN (avoids EFS costs)
3. **Amazon Timestream** — managed time-series DB (evaluate cost vs. self-hosted InfluxDB)

**Recommendation:** EFS mount for InfluxDB data. It's the simplest path that keeps everything on Fargate.

### 4.3 MBE (ECS Fargate)

Move from Vercel to ECS Fargate in the same VPC.

| Component | Details |
|-----------|---------|
| Image | Existing `Dockerfile` (multi-stage, `node:20-alpine`, `output: "standalone"`) |
| CPU/Memory | 512 CPU / 1024 MB |
| Supabase | Continues using cloud-hosted Supabase (`yncbwozwkjzyalxlguya.supabase.co`) over internet |
| OpenEMS B2B | Private IP within VPC — no public internet hop |
| ALB | HTTPS listener with ACM certificate |
| Env vars | `NEXT_PUBLIC_*` baked at build time; `OPENEMS_B2B_*` from Secrets Manager at runtime |

**Why not keep Vercel?** Vercel is serverless — it cannot join a VPC or VPN. MBE needs to reach the OpenEMS B2B endpoint on a private IP. Moving to ECS puts MBE in the same network.

### 4.4 Raspberry Pi Edge Devices

Each microgrid site has a Raspberry Pi running:
1. **OpenEMS Edge** — Java application collecting meter data via Modbus/SunSpec
2. **OpenVPN client** — connects to the AWS OpenVPN server

**Pi software stack:**

```
Raspberry Pi OS (Debian-based)
├── OpenJDK 17
├── OpenEMS Edge (openems.jar)
│   ├── Modbus bridge to physical meters
│   ├── RRD4j for local time-series storage
│   └── Backend controller (websocket to AWS backend via VPN)
└── OpenVPN client
    ├── client.conf
    ├── edge0.crt / edge0.key
    └── ca.crt
```

**Edge → Backend connection flow:**

```
Pi (10.8.0.2) ──OpenVPN tunnel──▶ VPN Server (10.8.0.1)
                                        │
                                   VPC routing
                                        │
                                        ▼
                              Backend (private subnet)
                              websocket :8081
```

The edge's `Controller.Api.Backend` config points to the backend's **private IP** (or internal DNS) within the VPC. The VPN tunnel makes this reachable from the Pi.

### 4.5 Simulation Edges (Testing)

Simulation edges remain as Docker containers in the ECS task definition. They:
- Run in the same task/network as the backend (no VPN needed)
- Generate synthetic meter data for testing the MBE billing flow
- Are distinguishable from production edges by naming convention (`sim-edge0` vs `edge0`)

---

## 5. Security Model

### Network segmentation

| Source | Destination | Port | Protocol | Allow? |
|--------|------------|------|----------|--------|
| Internet | ALB (MBE) | 443 | HTTPS | Yes |
| Internet | OpenVPN EC2 | 1194 | UDP | Yes |
| ALB | MBE (ECS) | 3000 | HTTP | Yes (target group) |
| MBE (ECS) | Backend (ECS) | 8082 | HTTP | Yes (same VPC, private) |
| VPN clients (`10.8.0.0/24`) | Backend (ECS) | 8081 | WebSocket | Yes |
| Backend (ECS) | RDS Postgres | 5432 | TCP | Yes (SG reference) |
| Backend (ECS) | InfluxDB (EFS) | 8086 | HTTP | Yes (same task or SG) |
| Everything else | * | * | * | **Deny** |

### Credential management

| Secret | Storage | Access |
|--------|---------|--------|
| OpenEMS B2B credentials | AWS Secrets Manager | MBE ECS task execution role |
| RDS password | AWS Secrets Manager | Backend ECS task execution role |
| Supabase service role key | AWS Secrets Manager | MBE ECS task execution role |
| OpenVPN CA key | Offline / HSM | Manual cert generation only |
| OpenVPN client certs | Generated per site, distributed manually | One per Raspberry Pi |
| ECR registry URL | AWS Secrets Manager (existing) | GitHub Actions |

### TLS

| Path | TLS? | Method |
|------|------|--------|
| Browser → MBE | Yes | ALB with ACM certificate |
| MBE → Supabase | Yes | Supabase enforces TLS |
| MBE → OpenEMS B2B | No (private network) | Consider adding Caddy for defense-in-depth |
| Edge Pi → Backend | Yes | OpenVPN encrypts the tunnel (AES-256-GCM) |
| Backend → RDS | Yes | RDS enforces TLS by default |

> **Dev env exception:** `iac/dev/` currently exposes UI (4200), Odoo (10016), B2B REST (8075), and the UI↔Backend WebSocket (8082) over **plain HTTP** to IP-allowlisted developers. This was an explicit scope decision in PR #71 (MVP dev env). The Lambda Function URL (MBE→OpenEMS proxy) is HTTPS via AWS-managed TLS. See Open Question 9 below.

---

## 6. Data Flow

### Meter reading flow (production)

```
1. Physical meter (Modbus) ──▶ Raspberry Pi (OpenEMS Edge)
2. Edge stores locally (RRD4j) and forwards to Backend (websocket over OpenVPN)
3. Backend stores in InfluxDB (time-series) and registers in Odoo (device registry)
4. MBE queries Backend B2B REST API for energy data (private network)
5. MBE calculates billing based on rate schedules (Supabase)
6. Entrepreneur views/exports bills in MBE UI (browser → ALB → MBE)
```

### Billing generation flow

```
MBE (ECS) ──HTTP:8082──▶ Backend B2B REST
                         │
                         ├── queryHistoricTimeseriesEnergy (per edge, per meter)
                         ├── getEdgesStatus (online/offline)
                         └── getEdgeConfig (meter discovery)
                         │
                         ▼
                    InfluxDB (time-series data)
```

---

## 7. Environments

Three environments, each isolated in its own AWS account (or at minimum, separate VPCs within the same account).

| Environment | Purpose | Edge devices | Data |
|-------------|---------|-------------|------|
| **Dev** | Feature development, integration testing | Simulation edges only (Docker) | Synthetic/test data |
| **Stage** | Pre-production validation, UAT | 1 real Pi (lab/test site) + simulation edges | Mix of real and synthetic |
| **Prod** | Live microgrid operations | Real Raspberry Pis at field sites | Real meter data |

### Environment isolation

```
AWS Account (or separate VPCs)
├── dev      (10.0.0.0/16)   — developers deploy freely, tear down at will
├── stage    (10.1.0.0/16)   — mirrors prod config, deploy requires PR merge to main
└── prod     (10.2.0.0/16)   — deploy requires release tag, manual approval gate
```

### What differs per environment

| Setting | Dev | Stage | Prod |
|---------|-----|-------|------|
| ECS instance size | Minimal (0.5 vCPU) | Same as prod | 4 vCPU, 12 GB |
| RDS instance | `db.t3.micro` | Same as prod | `db.t3.micro` (scale later) |
| OpenVPN server | Optional (sim edges only) | Yes (1 test Pi) | Yes (all field Pis) |
| OpenVPN PKI | Shared test CA | Separate CA | Separate CA (offline key) |
| Supabase | Local Docker or CLI | Cloud (separate project) | Cloud (production project) |
| Domain | `dev.energy-iot.com` | `stage.energy-iot.com` | `app.energy-iot.com` |
| ALB | Optional (use IP) | Yes | Yes (ACM cert) |
| Deploy trigger | Push to feature branch | Merge to `main` | Release tag + manual approval |
| Data retention | 7 days | 30 days | Indefinite |

### Promotion flow

```
Developer workstation
    │
    ▼ (push feature branch)
   Dev environment ── automated deploy via GitHub Actions
    │
    ▼ (merge PR to main)
  Stage environment ── automated deploy, manual QA sign-off
    │
    ▼ (create release tag + manual approval)
  Prod environment ── manual approval gate in GitHub Actions
```

### Terraform workspaces

Use Terraform workspaces (or separate tfvars files) to parameterize per environment:

```bash
terraform workspace select dev
terraform apply -var-file=environments/dev.tfvars

terraform workspace select prod
terraform apply -var-file=environments/prod.tfvars
```

All infrastructure code is shared; only variable values differ (CIDR ranges, instance sizes, domain names, secret ARNs).

---

## 8. Implementation Phases (per environment)

### Phase 1: Foundation (VPC + OpenVPN + Backend)

**Goal:** OpenEMS Backend running on AWS, reachable by a Raspberry Pi over OpenVPN.

1. Harden existing Terraform security groups (close `0.0.0.0/0` rules)
2. Add OpenVPN EC2 instance to Terraform (public subnet, UDP 1194)
3. Set up Easy-RSA PKI, generate server + first client cert
4. Add InfluxDB to ECS task definition (with EFS volume)
5. Move hardcoded credentials to Secrets Manager
6. Test: Pi at Kisakye connects via OpenVPN, edge appears online in backend
7. **Existing tickets:** docker-openems #67, #68, #69

### Phase 2: MBE Migration

**Goal:** MBE running on ECS in the same VPC, billing flow works end-to-end.

1. Add MBE ECS service + task definition to Terraform
2. Add ALB with HTTPS (ACM certificate)
3. Configure `OPENEMS_B2B_URL` to point to backend's private IP
4. Verify: billing generation pulls real meter data from backend
5. DNS cutover from Vercel to ALB
6. **Existing tickets:** metering-billing-engine #33, #34

### Phase 3: Hardening

**Goal:** Production-ready security and reliability.

1. Add TLS between MBE and Backend (Caddy reverse proxy) — defense in depth
2. Set up CloudWatch alarms (edge offline, backend errors, ECS task failures)
3. Configure OpenVPN CRL for certificate revocation
4. Backup strategy: RDS snapshots (automated), InfluxDB EFS backups, OpenVPN PKI backup
5. Document runbook for adding new edge sites (Pi provisioning)
6. **Existing tickets:** docker-openems #68

---

## 8. Open Questions

These need team input before finalizing:

1. **ECS vs EC2 for the backend stack?** Fargate is simpler but doesn't support `NET_ADMIN` (needed for OpenVPN server) and has no local persistent storage (InfluxDB needs EFS). Alternative: run everything on a single EC2 instance with Docker Compose (simpler, cheaper, but less "cloud-native"). The OpenVPN server must be EC2 regardless.

2. **InfluxDB persistence strategy?** EFS mount on Fargate works but adds cost and latency. Running InfluxDB on the OpenVPN EC2 instance would be simpler. Or evaluate Amazon Timestream as a managed alternative.

3. **Domain names?** Do we need custom domains (e.g., `app.energy-iot.com`, `vpn.energy-iot.com`) or are ALB/EC2 DNS names sufficient for MVP?

4. **Pi provisioning process?** Manual (SSH into each Pi, install OpenEMS + OpenVPN, copy certs) vs. semi-automated (SD card image with pre-configured software, site-specific config via USB drive or first-boot script)?

5. **Monitoring/alerting?** CloudWatch is the default. Do we need Grafana dashboards (existing InfluxDB integration) or is CloudWatch sufficient?

6. **Cost optimization?** Current Terraform uses `t3.micro` for RDS and Fargate for ECS. Should we consider Reserved Instances or Savings Plans if this runs long-term?

7. **OpenVPN server HA?** Single EC2 instance is a single point of failure. If it goes down, all field edges lose backend connectivity (they continue collecting locally via RRD4j). Is this acceptable for MVP, or do we need a standby?

8. **MBE on Vercel vs AWS?** Moving MBE to AWS adds infra complexity. Alternative: keep MBE on Vercel and expose the B2B endpoint through API Gateway with API key auth + TLS. Less secure (public endpoint) but simpler. Team preference?

9. **HTTPS for the dev environment?** The `iac/dev/` stack currently exposes UI, Odoo, B2B REST, and the UI↔Backend WebSocket over plain HTTP to IP-allowlisted developers. Dev-only creds flow in the clear (Basic auth, Odoo session cookies). This was deferred as a scope call in PR #71, but surfaced during the 2026-04-21 stack validation — worth a team discussion before it becomes normalized practice. Options:
   - **A. Accept HTTP for dev-only** — zero cost, relies on allowlist; bakes a bad norm as the env outlives the pilot
   - **B. Self-signed cert + nginx TLS** — ~30 min, zero cost, every visit triggers a browser warning
   - **C. Caddy sidecar + Let's Encrypt** — ~1 hr, needs a DNS name (e.g., `openems-dev.<our-domain>`), clean browser UX
   - **D. ALB + ACM cert** — ~2 hr, ~$16/mo for ALB + $12/yr for domain, matches prod pattern exactly, gives us health checks and logging for free
   
   **Decision factors:** will dev env carry any non-synthetic tenant data? Does it stay up between pilot sessions? Who owns the renewal + cert/DNS management? Option D is the "right" answer if dev env becomes persistent; Option A is defensible only if dev env is strictly ephemeral + IP-scoped.
   
   **Owner: TBD** — needs assignment before Phase 1 dev-env hardening.

---

## 9. Cost Estimate (Monthly, us-east-1)

| Resource | Spec | Est. cost |
|----------|------|-----------|
| ECS Fargate (backend) | 4 vCPU, 12 GB | ~$150 |
| ECS Fargate (MBE) | 0.5 vCPU, 1 GB | ~$20 |
| EC2 (OpenVPN) | t3.micro | ~$8 |
| RDS PostgreSQL | db.t3.micro, 200 GB | ~$25 |
| ALB | 1 ALB, minimal traffic | ~$20 |
| EFS (InfluxDB) | 50 GB estimate | ~$15 |
| NAT Gateway | 1 AZ | ~$35 |
| ECR | Image storage | ~$5 |
| Secrets Manager | 5 secrets | ~$2 |
| **Total** | | **~$280/mo** |

Note: NAT Gateway is the third-highest cost. If all services have public IPs (or use VPC endpoints), it can be eliminated.

---

## 10. Reference

### Existing infrastructure code

- `iac/vpc.tf` — VPC with 2 public + 2 private subnets
- `iac/ecs.tf` — ECS Fargate cluster, task definition, service
- `iac/security-group.tf` — Security groups (need hardening)
- `iac/postgres-rds.tf` — RDS PostgreSQL for Odoo
- `iac/terraform.tfvars` — Variable values (credentials need migration to Secrets Manager)
- `.github/workflows/deploy-pipeline.yml` — CI/CD pipeline

### MBE integration points

- `metering-billing-engine/src/lib/openems/client.ts` — B2B REST client (Basic auth, JSON-RPC)
- `metering-billing-engine/src/lib/openems/index.ts` — reads `OPENEMS_B2B_URL`, `OPENEMS_B2B_USERNAME`, `OPENEMS_B2B_PASSWORD` from env
- `metering-billing-engine/Dockerfile` — production image (standalone Next.js)

### Related tickets

- docker-openems: #67 (AWS EC2 + VPC), #68 (TLS proxy), #69 (VPN for edges)
- metering-billing-engine: #32 (Docker CORS/PostgREST fix), #33 (ECS Fargate), #34 (Secrets Manager)
