#!/usr/bin/env bash
# PIA Port Forwarding
# Usage: pia-portforward.sh <instance>
# Gets a forwarded port and refreshes the binding every 15 minutes
set -euo pipefail

INSTANCE=${1:-pia}

source "/run/pia/${INSTANCE}/connection.env"

PIA_TOKEN=$(cat /run/pia/token)
CA_CERT=/etc/pia/ca.rsa.4096.crt
STATE_DIR="/run/pia/${INSTANCE}"

if [[ ! -f $CA_CERT ]]; then
  echo "ERROR: CA certificate not found at ${CA_CERT}" >&2
  echo "Copy ca.rsa.4096.crt to /etc/pia/" >&2
  exit 1
fi

cleanup() { rm -f "${STATE_DIR}/port"; }
trap cleanup EXIT

# --- Get signature ---
echo "Requesting port forwarding signature..."
payload_and_signature=$(curl -s -m 5 \
  --connect-to "${WG_HOSTNAME}::${WG_SERVER_IP}:" \
  --cacert "$CA_CERT" \
  -G --data-urlencode "token=${PIA_TOKEN}" \
  "https://${WG_HOSTNAME}:19999/getSignature")

if [[ $(echo "$payload_and_signature" | jq -r '.status') != "OK" ]]; then
  echo "ERROR: Failed to get port forwarding signature" >&2
  exit 1
fi

signature=$(echo "$payload_and_signature" | jq -r '.signature')
payload=$(echo "$payload_and_signature" | jq -r '.payload')
port=$(echo "$payload" | base64 -d | jq -r '.port')
expires_at=$(echo "$payload" | base64 -d | jq -r '.expires_at')

echo "Port: ${port} (expires: ${expires_at})"
echo "$port" > "${STATE_DIR}/port"

# --- Bind loop ---
while true; do
  bind_response=$(curl -Gs -m 5 \
    --connect-to "${WG_HOSTNAME}::${WG_SERVER_IP}:" \
    --cacert "$CA_CERT" \
    --data-urlencode "payload=${payload}" \
    --data-urlencode "signature=${signature}" \
    "https://${WG_HOSTNAME}:19999/bindPort")

  if [[ $(echo "$bind_response" | jq -r '.status') != "OK" ]]; then
    echo "ERROR: Port bind failed" >&2
    exit 1
  fi

  echo "Port ${port} bound ($(date '+%Y-%m-%d %H:%M:%S'))"
  sleep 900
done
