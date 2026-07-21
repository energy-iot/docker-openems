#!/usr/bin/env bash
set -Eeuo pipefail

HCLOUD_CONTEXT="${HCLOUD_CONTEXT:-openems-pilot}"
SERVER_NAME="openems-pilot"
SERVER_TYPE="cx23"
# EU-only preference order: Nuremberg, Falkenstein, Helsinki.
SERVER_LOCATIONS=("nbg1" "fsn1" "hel1")
SERVER_LOCATION=""
SERVER_IMAGE="ubuntu-24.04"
SSH_KEY_NAME="openems-deploy"
FIREWALL_NAME="openems-pilot"
SSH_SOURCE_IP="41.210.141.155/32"
MAX_SERVER_MONTHLY_NET="6.49"
EXPECTED_IPV4_MONTHLY_NET="0.60"
MAX_TOTAL_MONTHLY_NET="7.09"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY_FILE="${SCRIPT_DIR}/../.secrets/openems-hetzner.pub"

for command in hcloud jq; do
  command -v "${command}" >/dev/null || {
    echo "ERROR: ${command} is required." >&2
    exit 1
  }
done

if hcloud --context "${HCLOUD_CONTEXT}" server describe "${SERVER_NAME}" >/dev/null 2>&1; then
  echo "ALREADY_EXISTS: ${SERVER_NAME}; no purchase made."
  hcloud --context "${HCLOUD_CONTEXT}" server describe "${SERVER_NAME}" -o json \
    | jq '{id, name, status, public_net}'
  exit 0
fi

server_type_json="$(hcloud --context "${HCLOUD_CONTEXT}" server-type describe "${SERVER_TYPE}" -o json)"
monthly_net=""
calculated_total=""
for candidate_location in "${SERVER_LOCATIONS[@]}"; do
  available="$(jq -r --arg location "${candidate_location}" \
    '.locations[] | select(.name == $location) | .available' <<<"${server_type_json}")"
  [[ "${available}" == "true" ]] || continue

  candidate_monthly_net="$(jq -er --arg location "${candidate_location}" \
    '.prices[] | select(.location == $location) | .price_monthly.net' <<<"${server_type_json}")"
  candidate_total="$(jq -nr --arg server "${candidate_monthly_net}" --arg ipv4 "${EXPECTED_IPV4_MONTHLY_NET}" \
    '($server | tonumber) + ($ipv4 | tonumber)')"

  if jq -en --arg server "${candidate_monthly_net}" --arg server_cap "${MAX_SERVER_MONTHLY_NET}" \
    --arg total "${candidate_total}" --arg total_cap "${MAX_TOTAL_MONTHLY_NET}" \
    '(($server | tonumber) <= ($server_cap | tonumber)) and (($total | tonumber) <= ($total_cap | tonumber))' >/dev/null; then
    SERVER_LOCATION="${candidate_location}"
    monthly_net="${candidate_monthly_net}"
    calculated_total="${candidate_total}"
    break
  fi
done

if [[ -z "${SERVER_LOCATION}" ]]; then
  echo "UNAVAILABLE: no price-compliant ${SERVER_TYPE} is currently available in EU locations ${SERVER_LOCATIONS[*]}; no purchase made."
  exit 0
fi

[[ -r "${PUBLIC_KEY_FILE}" ]] || {
  echo "ERROR: SSH public key not found at ${PUBLIC_KEY_FILE}." >&2
  exit 1
}

if ! hcloud --context "${HCLOUD_CONTEXT}" ssh-key describe "${SSH_KEY_NAME}" >/dev/null 2>&1; then
  hcloud --context "${HCLOUD_CONTEXT}" ssh-key create \
    --name "${SSH_KEY_NAME}" \
    --public-key-from-file "${PUBLIC_KEY_FILE}" >/dev/null
fi

if ! hcloud --context "${HCLOUD_CONTEXT}" firewall describe "${FIREWALL_NAME}" >/dev/null 2>&1; then
  hcloud --context "${HCLOUD_CONTEXT}" firewall create --name "${FIREWALL_NAME}" >/dev/null
  hcloud --context "${HCLOUD_CONTEXT}" firewall add-rule --direction in --protocol tcp --port 22 \
    --source-ips "${SSH_SOURCE_IP}" "${FIREWALL_NAME}" >/dev/null
  for protocol in tcp udp; do
    hcloud --context "${HCLOUD_CONTEXT}" firewall add-rule --direction in --protocol "${protocol}" --port 443 \
      --source-ips "0.0.0.0/0,::/0" "${FIREWALL_NAME}" >/dev/null
  done
  hcloud --context "${HCLOUD_CONTEXT}" firewall add-rule --direction in --protocol tcp --port 80 \
    --source-ips "0.0.0.0/0,::/0" "${FIREWALL_NAME}" >/dev/null
fi

echo "Purchasing one ${SERVER_TYPE} in ${SERVER_LOCATION} at ${monthly_net} net/month plus the expected ${EXPECTED_IPV4_MONTHLY_NET} IPv4 charge (cap ${MAX_TOTAL_MONTHLY_NET})."
created_json="$(hcloud --context "${HCLOUD_CONTEXT}" server create \
  --name "${SERVER_NAME}" \
  --type "${SERVER_TYPE}" \
  --image "${SERVER_IMAGE}" \
  --location "${SERVER_LOCATION}" \
  --ssh-key "${SSH_KEY_NAME}" \
  --firewall "${FIREWALL_NAME}" \
  --enable-backup=false \
  --enable-protection delete \
  --label app=openems \
  --label environment=pilot \
  -o json)"

echo "CREATED: ${SERVER_NAME}"
jq '{id, name, status, server_type: .server_type.name, datacenter: .datacenter.name, public_net}' <<<"${created_json}"
