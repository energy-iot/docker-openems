#!/usr/bin/env bash
# Bootstrap the Terraform remote-state S3 bucket for the OpenEMS stack.
#
# WHY THIS EXISTS
# The Terraform S3 backend (iac/backend.tf) stores state in an S3 bucket that
# must already EXIST before `terraform init` runs — Terraform cannot create its
# own state backend (chicken-and-egg). So this bucket is created out-of-band,
# once per AWS account, by this script.
#
# The bucket name is account-scoped (…-<account-id>) because S3 bucket names are
# globally unique across all of AWS; the plain "eiot-openems-tf-state-file" was
# already taken by another account. Keep the "eiot-openems-" prefix — the deploy
# role's S3 permissions are scoped to arn:aws:s3:::eiot-openems-*.
#
# It applies the hardening a state bucket must have:
#   - versioning        → every state write is recoverable (undo a bad apply)
#   - default encryption→ state can contain secrets; encrypt at rest
#   - block public access
#   - TLS-only policy   → reject any non-HTTPS request
#
# Idempotent: safe to re-run; it re-asserts every setting.
#
# USAGE
#   aws sso login --profile eiot-openems-devops-383166698084
#   export AWS_PROFILE=eiot-openems-devops-383166698084
#   ./iac/bootstrap-state-bucket.sh
#
# Override defaults if needed:
#   BUCKET=other-name REGION=us-east-1 ./iac/bootstrap-state-bucket.sh
#
# The BUCKET default MUST match iac/backend.tf.
set -euo pipefail

BUCKET="${BUCKET:-eiot-openems-tfstate-383166698084}"
REGION="${REGION:-us-east-1}"

echo "[bootstrap] target bucket: $BUCKET   region: $REGION"

# --- auth check -------------------------------------------------------------
who=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || {
  echo "[bootstrap] ERROR: no valid AWS session. Run: aws sso login --profile <profile>" >&2
  exit 1
}
echo "[bootstrap] authenticated as: $who"

# --- create bucket (idempotent) --------------------------------------------
# us-east-1 must NOT send a LocationConstraint; every other region must.
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "[bootstrap] bucket already exists (owned by this account) — re-asserting settings"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "[bootstrap] bucket created"
fi

# --- block all public access ------------------------------------------------
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "[bootstrap] public access blocked"

# --- versioning (state history + recovery) ---------------------------------
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
echo "[bootstrap] versioning enabled"

# --- default encryption -----------------------------------------------------
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
echo "[bootstrap] default encryption (AES256) enabled"

# --- TLS-only bucket policy -------------------------------------------------
read -r -d '' POLICY <<EOF || true
{ "Version": "2012-10-17", "Statement": [ {
  "Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
  "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } } } ] }
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"
echo "[bootstrap] TLS-only bucket policy applied"

echo "[bootstrap] done — backend.tf must reference bucket=\"$BUCKET\""
