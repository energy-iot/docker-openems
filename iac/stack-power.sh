#!/usr/bin/env bash
# Turn the OpenEMS AWS stack on/off to control cost during buildout.
#
#   stop  → ECS desired-count 0 (Fargate billing → $0) + stop the RDS instance
#   start → start RDS, wait for it, then ECS desired-count 1
#   status→ show ECS + RDS state
#
# COST WHEN STOPPED: ~$2-3/mo (RDS still bills for its 20 GB of allocated
# storage even while stopped; Secrets Manager ~$0.40). For TRUE $0, tear the
# whole stack down with `terraform destroy` and `terraform apply` to rebuild
# (~10 min) — fine while there is no real data yet.
#
# NOTE: a stopped RDS instance auto-starts after 7 days (an AWS limit).
#
# Usage:
#   aws sso login --profile eiot-openems-devops-383166698084
#   export AWS_PROFILE=eiot-openems-devops-383166698084
#   ./iac/stack-power.sh {stop|start|status}
set -euo pipefail

CLUSTER="openems-deployment-cluster"
SERVICE="openems-deployment-service"
DB="odoodb"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT="383166698084" # eiot — this stack's account

# Default to the eiot deploy profile if the caller didn't set one, so running
# the script without exporting AWS_PROFILE doesn't silently hit the wrong
# account (which shows up as a confusing "DBInstance not found").
export AWS_PROFILE="${AWS_PROFILE:-eiot-openems-devops-383166698084}"

acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "No valid AWS session. Run: aws sso login --profile $AWS_PROFILE" >&2; exit 1; }
if [ "$acct" != "$ACCOUNT" ]; then
  echo "Wrong AWS account: got $acct, expected $ACCOUNT (eiot). Check AWS_PROFILE." >&2; exit 1
fi

ecs_scale() { aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count "$1" --region "$REGION" --query 'service.desiredCount' --output text; }

case "${1:-status}" in
  stop)
    echo "[power] scaling ECS service to 0..."
    ecs_scale 0 >/dev/null && echo "  ECS desired-count = 0"
    echo "[power] stopping RDS $DB..."
    aws rds stop-db-instance --db-instance-identifier "$DB" --region "$REGION" \
      --query 'DBInstance.DBInstanceStatus' --output text 2>&1 || true
    echo "[power] stopped. (RDS still bills ~\$2-3/mo for storage; 'terraform destroy' for true \$0.)"
    ;;
  start)
    echo "[power] starting RDS $DB (takes a few minutes)..."
    aws rds start-db-instance --db-instance-identifier "$DB" --region "$REGION" >/dev/null 2>&1 || true
    aws rds wait db-instance-available --db-instance-identifier "$DB" --region "$REGION"
    echo "  RDS available"
    echo "[power] scaling ECS service to 1..."
    ecs_scale 1 >/dev/null && echo "  ECS desired-count = 1"
    echo "[power] started."
    ;;
  status)
    echo "ECS:  $(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
      --query 'services[0].{desired:desiredCount,running:runningCount}' --output text 2>/dev/null || echo 'n/a')"
    echo "RDS:  $(aws rds describe-db-instances --db-instance-identifier "$DB" --region "$REGION" \
      --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo 'n/a')"
    ;;
  *)
    echo "usage: $0 {stop|start|status}" >&2; exit 1 ;;
esac
