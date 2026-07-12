#!/usr/bin/env bash
# Retag locally-built images and push them to ECR.
# ECR_URI can be overridden via the environment (CI passes the registry).
set -euo pipefail

ECR_URI="${ECR_URI:-470298448112.dkr.ecr.us-east-1.amazonaws.com}"

# Explicit list — do NOT derive this from docker-compose.yml: the compose
# file also references images we never push (influxdb, the local edge).
IMAGES=(
  "openems-ui:latest"
  "openems-backend:latest"
  "odoo:latest"
)

for IMAGE in "${IMAGES[@]}"; do
  echo "Pushing $IMAGE -> $ECR_URI/$IMAGE"
  docker tag "$IMAGE" "$ECR_URI/$IMAGE"
  docker push "$ECR_URI/$IMAGE"
done

echo "All images pushed to ECR."
