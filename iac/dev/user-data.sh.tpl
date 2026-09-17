#!/bin/bash
# OpenEMS dev stack bootstrap — runs on first boot as root via cloud-init.
# Logs land in /var/log/cloud-init-output.log (and /var/log/openems-bootstrap.log).

set -euo pipefail
exec > >(tee -a /var/log/openems-bootstrap.log) 2>&1

echo "[bootstrap] Starting at $(date)"

# ── Install prerequisites ────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git jq

# Docker (official repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Allow ubuntu user to run docker without sudo
usermod -aG docker ubuntu || true

# ── Clone docker-openems repo ────────────────────────────────────────
INSTALL_DIR=/opt/docker-openems
if [ ! -d "$INSTALL_DIR" ]; then
  git clone --branch "${git_branch}" https://github.com/energy-iot/docker-openems.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# ── Run setup.sh ─────────────────────────────────────────────────────
# setup.sh is idempotent; safe to re-run.
# Build happens here — first run takes ~10 min on t3.large.
chmod +x setup.sh
./setup.sh --edges "${edge_count}" || {
  echo "[bootstrap] setup.sh failed — check docker logs"
  exit 1
}

echo "[bootstrap] Completed at $(date)"
TOKEN=$(curl -sSf -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
PUB_IP=$(curl -sSf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "[bootstrap] UI:    http://$PUB_IP:4200"
echo "[bootstrap] B2B:   http://$PUB_IP:8075"
echo "[bootstrap] Odoo:  http://$PUB_IP:10016"
