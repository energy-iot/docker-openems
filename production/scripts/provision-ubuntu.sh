#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root on a fresh Ubuntu 24.04 server." >&2
  exit 1
fi

DEPLOY_USER="${DEPLOY_USER:-openems}"
SWAP_FILE=/swapfile-openems

apt-get update
apt-get install -y ca-certificates curl jq ufw unattended-upgrades
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/openems

if [[ ! -e "$SWAP_FILE" ]]; then
  fallocate -l 2G "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
fi
if ! swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE"; then
  swapon "$SWAP_FILE"
fi
grep -Fq "$SWAP_FILE none swap sw 0 0" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' > /etc/sysctl.d/99-openems.conf
sysctl --system

ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
if [[ -n "${SSH_ALLOW_FROM:-}" ]]; then
  ufw allow from "$SSH_ALLOW_FROM" to any port 22 proto tcp
else
  echo "WARNING: SSH_ALLOW_FROM was not set; port 22 remains governed by the Hetzner firewall."
  ufw allow 22/tcp
fi
ufw --force enable

systemctl enable --now docker unattended-upgrades
echo "Provisioning complete. Copy production/ to /opt/openems and create /opt/openems/.env."
