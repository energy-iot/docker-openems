# Dev Environment (AWS)

Single-EC2 deployment of the OpenEMS stack for development. Isolated from the production `iac/` configuration (separate VPC, separate Terraform state key).

## What it provisions

- VPC `10.100.0.0/16` with a single public subnet
- EC2 `t3.large` (Ubuntu 22.04), runs full `docker-compose` stack via `setup.sh`
- Security group scoped to `allowed_ips` (no `0.0.0.0/0`)
- IAM role for SSM Session Manager (no SSH key required)

Ports exposed to `allowed_ips`:
- `4200` — OpenEMS UI (nginx)
- `8082` — OpenEMS UI ↔ Backend WebSocket (browser connects here from the UI)
- `8075` — OpenEMS Backend B2B REST (JSON-RPC, used by MBE / Lambda proxy)
- `10016` — Odoo
- `8086` — InfluxDB HTTP (debugging)

## Prerequisites

- AWS credentials for account `470298448112` with permissions: `AmazonEC2FullAccess`, `IAMFullAccess`, `AmazonSSMFullAccess`
- Terraform >= 1.3
- `aws-cli` v2 (for SSM Session Manager)
- [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) installed locally

## First-time setup

```bash
cd iac/dev

# Backend config (S3 bucket + DynamoDB table names from your cloud admin)
cp backend.tfvars.example backend.tfvars
# Edit backend.tfvars — fill in bucket and dynamodb_table

# Variables (IPs, instance type, etc.)
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — add your IPs to allowed_ips

terraform init -backend-config=backend.tfvars
terraform plan
terraform apply
```

After `apply`, outputs include the public IP and connection URLs. The stack takes **~10 minutes** to bootstrap on first boot (Docker image builds).

## Watching the bootstrap

```bash
# Copy from terraform output
$(terraform output -raw bootstrap_log_tail)
```

Bootstrap is complete when you see `All checks passed!` in the log.

## Adding / removing IPs

Edit `terraform.tfvars`, add or remove entries in `allowed_ips`, then:

```bash
terraform apply
```

Only the security group rules change — no instance disruption.

## Accessing the instance

```bash
# Interactive shell (SSM, no SSH)
$(terraform output -raw ssm_connect_command)
```

## Destroying

```bash
terraform destroy
```

Tears down everything except the shared Terraform state (which lives in the `openems-deployment-tf-state-file` S3 bucket).

## Troubleshooting

**Bootstrap stuck / failed?**
```bash
aws ssm start-session --target <instance-id>
sudo tail -100 /var/log/openems-bootstrap.log
cd /opt/docker-openems && sudo docker compose ps
```

**Need to re-bootstrap?**
The `user_data` script only runs on first boot. To re-run, destroy and recreate:
```bash
terraform destroy -target=aws_instance.openems
terraform apply
```

**Stack consuming too much RAM?**
Bump `instance_type` to `t3.xlarge` in `terraform.tfvars`, then `terraform apply` — this will replace the instance.
