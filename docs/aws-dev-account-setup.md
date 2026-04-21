# AWS Dev Account Setup Guidelines

**Audience:** IT/Cloud admin (Aidan)
**Purpose:** Provision and scope a dedicated AWS account for OpenEMS + MBE dev work, including safe access for Claude Code agent sessions
**Related:** [aws-production-architecture.md](./aws-production-architecture.md)

---

## 1. Why a separate account

Running dev in the same AWS account as production creates unacceptable blast radius when running infrastructure changes through automated agents (Claude Code) or during rapid iteration. A separate account gives us:

- **Hard isolation** — IAM scoped to the account boundary. Mistakes in dev cannot affect prod.
- **Independent billing** — clear view of dev costs, easy to cap with budgets
- **Safer agent operations** — we can grant broad IAM permissions within dev without risk to prod
- **Realistic promotion model** — forces us to design deployments that move between accounts, matching industry practice

**Non-goal:** complete parity with prod. Dev is intentionally smaller/cheaper.

---

## 2. Account structure

### Recommended: AWS Organizations with OUs

```
Root Organization
├── Management Account         (billing, Organizations, SSO only — no workloads)
├── Security OU
│   └── Log Archive Account    (centralized CloudTrail, optional)
├── Workloads OU
│   ├── energy-iot-dev         (this account — new)
│   ├── energy-iot-stage       (future)
│   └── energy-iot-prod        (existing account 470298448112 — migrate later)
```

**Minimum viable for today:** create the dev account under the existing organization (or create an organization if there isn't one). We do not need stage or the Security OU on day one.

### Account naming

- **Account alias:** `axm-ai-eiot-dev`
- ~~**Email:**~~ not needed
- **Account tag:** `Environment=dev`, `Owner=engineering`

---

## 3. Services to enable on account creation

These should be on from day one. Most are free or low-cost.

| Service | Purpose | Notes |
|---------|---------|-------|
| CloudTrail | Audit log of all API calls | Required. Free for management events. Enable in all regions. |
| AWS Config | Resource inventory + compliance | Optional but recommended |
| ~~GuardDuty~~ | Threat detection service | not needed for dev scope ~~Free 30-day trial, then ~$5/mo for a dev account~~ |
| IAM Identity Center (SSO) | Human login | Replaces individual IAM users for people |
| AWS Budgets | Cost caps | Set a budget alert at $100/mo, hard alert at $500/mo |
| Cost Explorer | Cost analysis | Free to enable |
| VPC Flow Logs | Network audit | Enable at VPC level when we create VPCs |

**Things to NOT enable in dev:**
- AWS Shield Advanced (prod only)
- Multi-region replication of anything
- Reserved Instances / Savings Plans (dev workloads are bursty)

---

## 4. Region restriction

Lock the dev account to **us-east-1** only. We have no business operating in other regions for dev, and restricting regions:
- Prevents accidental multi-region sprawl
- Stops attackers (or confused agents) from hiding resources in obscure regions
- Simplifies cost analysis

Enforce via an SCP at the OU level (see Section 7).

---

## 5. What the dev account will contain

Based on the [architecture doc](./aws-production-architecture.md), the dev account needs to host:

### Phase 1 — initial dev deploy (this week)
- **VPC** `10.100.0.0/16` with public subnet
- **EC2** — single `t3.large` running OpenEMS stack via `setup.sh`
- **Security groups** — scoped to engineer IPs
- **IAM** — instance profile for SSM, dev agent user

### Phase 2 — MBE added
- **ECS Fargate cluster** — MBE task definition
- **ALB** — HTTPS termination for MBE
- **ACM** — TLS certificate (DNS-validated)
- **Route53** — hosted zone for `dev.energy-iot.com` (or chosen domain)
- **Secrets Manager** — OpenEMS credentials, Supabase service role key
- **CloudWatch Logs** — MBE + ECS task logs

### Phase 3 — production edges (OpenVPN)
- **EC2** — OpenVPN server (separate instance, public subnet)
- **VPC routing** — return route for VPN subnet `10.8.0.0/24`
- **EIP** — stable public IP for OpenVPN endpoint

### Later (as we grow)
- **RDS Postgres** — Odoo DB
- **EFS** — InfluxDB persistence
- **ECR** — container images (dev)
- **S3** — backups, artifacts
- **Systems Manager Parameter Store** — non-sensitive config

---

## 6. IAM strategy

### Human access: IAM Identity Center (SSO)

- All engineers (Alejandro, Aidan, future hires) access dev via SSO — no long-lived IAM users
- Groups:
  - `engineering-dev-admin` — PowerUserAccess + IAM management
  - `engineering-dev-readonly` — ReadOnlyAccess (for observers)
- MFA required

### Programmatic access: scoped IAM users

We will have a small number of long-lived IAM users for specific automation:

| IAM user | Purpose | Permissions |
|----------|---------|-------------|
| ~~`terraform-ci` ~~| ~~GitHub Actions deploy pipeline~~ | PowerUserAccess + IAM for resources under `openems-dev-*` prefix |
| axm-bello | GitHub Actions deploy pipeline (pending migration) | |
| `axm-ai-eiot-dev` | Claude Code agent sessions | See Section 8 |

### Service roles

- **EC2 instance profile** — SSM Session Manager access only (no S3, no EC2 API)
- **ECS task execution role** — ECR pull, Secrets Manager read, CloudWatch logs write
- **ECS task role** — application-specific (e.g., read Secrets Manager for OpenEMS creds)
- **Terraform state role** — S3 + DynamoDB for state backend (assumed from CI)

---

## 7. Service Control Policies (guardrails)

Apply at the OU level (or the dev account) to prevent common mistakes.

### SCP 1: Region lock

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyAllOutsideUsEast1",
    "Effect": "Deny",
    "NotAction": [
      "iam:*", "organizations:*", "route53:*",
      "cloudfront:*", "s3:ListAllMyBuckets",
      "support:*", "sts:*", "budgets:*",
      "ce:*", "cur:*"
    ],
    "Resource": "*",
    "Condition": {
      "StringNotEquals": {
        "aws:RequestedRegion": ["us-east-1"]
      }
    }
  }]
}
```

### SCP 2: Deny expensive instance types

Prevents runaway cost if an agent or engineer accidentally spins up huge instances.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyLargeInstanceTypes",
    "Effect": "Deny",
    "Action": [
      "ec2:RunInstances",
      "ec2:StartInstances"
    ],
    "Resource": "arn:aws:ec2:*:*:instance/*",
    "Condition": {
      "ForAnyValue:StringLike": {
        "ec2:InstanceType": [
          "*.metal",
          "p*", "g*", "x*",
          "*.24xlarge", "*.16xlarge", "*.12xlarge", "*.8xlarge"
        ]
      }
    }
  }]
}
```

Allowed: anything up to `*.4xlarge`, no metal, no GPU, no high-memory. For dev, even `t3.xlarge` is generous.

### SCP 3: Require tags

Running an EC2 instance and creating an RDS DB requires `Environment=aidev` tag. This lets us use tag-based IAM conditions reliably.
#### AB - corrected to actually require an `Environment=aidev` tag/key pair and revised the description - WIP, still revising
Null{} block inverts the condition of the enclosed statement
```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "RequireEnvironmentTag",
			"Effect": "Allow",
			"Action": [
				"ec2:RunInstances",
				"rds:CreateDBInstance"
			],
			"Resource": "*",
			"Condition": {
				"StringEquals": {"aws:ResourceTag/Environment": "aidev"}
			}
		}
	]
}
```

### SCP 4: Protect CloudTrail

Prevent users with this policy from disabling audit logging.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ProtectCloudTrail",
    "Effect": "Deny",
    "Action": [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors"
    ],
    "Resource": "*"
  }]
}
```

---

## 8. Claude Code agent access

A dedicated IAM user for agent sessions, scoped to the specific resources and operations needed.

### Why a separate IAM user (not SSO)

- **Auditable** — every API call logged under one identity, easy to review in CloudTrail
- **Revocable** — rotate or disable without affecting humans
- **Bounded** — IAM policy is the ceiling; agent can never exceed it

### Permissions for `axm-ai-eiot-dev`

**Managed policies:**
- `AmazonEC2FullAccess`
- `AmazonSSMFullAccess`

**Inline policy** (covers IAM for EC2 instance profiles, S3 Terraform state, DynamoDB lock):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IAMForDevInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:ListRoles",
        "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:PassRole", "iam:ListInstanceProfilesForRole"
      ],
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:role/openems-dev-*",
        "arn:aws:iam::<ACCOUNT_ID>:instance-profile/openems-dev-*"
      ]
    },
    {
      "Sid": "S3TerraformState",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketVersioning"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>"
    },
    {
      "Sid": "S3TerraformStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>/iac/dev/*"
    },
    {
      "Sid": "DynamoDBStateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/<LOCK_TABLE>"
    }
  ]
}
```

### Why this is safe in a dedicated dev account

The EC2/SSM managed policies are broad, but in an isolated dev account:
- They cannot touch prod (account boundary)
- Runaway cost is capped by SCPs (no large instance types, region-locked to us-east-1)
- Every action is logged in CloudTrail
- Worst case = rebuild the dev account in an hour

### What to give the agent

- Access key ID + secret
- Store in `~/.aws/credentials` under profile `claude-code-dev`
- Rotate every 90 days
- Delete immediately if agent behavior goes sideways

### What NOT to give the agent

- Root account credentials
- SSO access
- Permission to modify billing, Organizations, SCPs
- Any cross-account role

---

## 9. Shared resources (Terraform state, ECR)

The existing prod account has:
- S3 bucket `openems-deployment-tf-state-file` (Terraform state)
- DynamoDB table `terraform-state-lock-openems-deployment` (state locking)
- ECR repos under account 470298448112

**Options for dev:**

**Option A: Recreate in dev account (recommended)**
- New state bucket: `energy-iot-dev-tf-state`
- New lock table: `energy-iot-dev-tf-lock`
- New ECR repos in dev account
- Pros: complete isolation, no cross-account complexity
- Cons: duplicated resources, images must be rebuilt per account

**Option B: Share from prod account**
- Dev account assumes a cross-account role into prod to read/write state
- Pros: single source of truth for images and state
- Cons: cross-account IAM complexity, dev can affect shared resources

**Recommendation: Option A for MVP.** We can introduce cross-account sharing later when promotion from dev → prod becomes a real workflow. For now, each account is self-contained.

---

## 10. Cost expectations

Rough monthly cost for the dev account at Phase 2 (OpenEMS + MBE, no edges yet):

| Resource | Cost |
|----------|------|
| EC2 t3.large (24x7) | ~$60 |
| ECS Fargate (MBE, 0.5 vCPU / 1 GB) | ~$20 |
| ALB | ~$20 |
| NAT Gateway | ~$35 |
| EBS gp3 (40 GB x 1 instance) | ~$4 |
| Route53 hosted zone | ~$0.50 |
| CloudWatch Logs (minimal) | ~$5 |
| Data transfer | ~$5 |
| **Total** | **~$150/mo** |

Add OpenVPN EC2 + RDS + EFS later for ~$50 more.

**Budget alert thresholds:**
- $100 warning (email to engineers)
- $300 critical (email + SNS + shut down non-essential)
- $500 hard stop (manual intervention required)

**Cost optimization for dev:**
- Stop the EC2 instance when not in use (saves ~$2/day, ~$60/mo if only used during work hours)
- Use a Lambda + EventBridge schedule to auto-stop at 10pm / start at 8am weekdays

---

## 11. Checklist for account provisioning

- [ ] Create `energy-iot-dev` AWS account under existing Organization
- [ ] Configure account alias and billing email
- [ ] Enable CloudTrail (all regions, 90-day retention)
- [ ] Enable Cost Explorer
- [ ] Create Budget alert at $100/mo (email notification)
- [ ] Apply SCPs: region lock, instance type limits, tag requirements, CloudTrail protection
- [ ] Set up IAM Identity Center, add `engineering-dev-admin` group
- [ ] Invite engineers (Alejandro, Aidan) to the group
- [ ] Create S3 bucket for Terraform state (`energy-iot-dev-tf-state`)
- [ ] Create DynamoDB table for state locking (`energy-iot-dev-tf-lock`)
- [ ] Create IAM user `claude-code-dev` with policies from Section 8
- [ ] Create access key for `claude-code-dev`, hand off to Alejandro via secure channel (1Password, Bitwarden, etc.)
- [ ] Enable GuardDuty (optional but recommended)
- [ ] Document account ID, aliases, and key ARNs in the team wiki / 1Password vault

---

## 12. What comes next

Once the account is provisioned:

1. **Alejandro** updates `iac/dev/backend.tf` with the new state bucket name
2. **Alejandro** runs `terraform init` + `terraform apply` in the dev account
3. **Validate** OpenEMS stack reachable from engineer IPs
4. **Iterate** — add MBE, then OpenVPN, per the architecture doc phases

---

## Open questions for Aidan

1. **Existing AWS Organization?** If not, do we create one (converts the existing prod account into a management account) or leave prod standalone and create dev as a separate, unaffiliated account?
2. **SSO provider?** Do we use AWS IAM Identity Center natively, or integrate with an external IdP (Okta, Google Workspace, etc.)?
3. **Domain?** Does `energy-iot.com` exist in Route53 already, or do we need to register a new one / transfer?
4. **Budget ownership?** Who owns the dev account billing? Same card as prod or separate?
5. **On-call / escalation?** If dev resources start costing unexpectedly, who gets paged?
