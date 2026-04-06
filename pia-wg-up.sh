#!/usr/bin/env bash
# PIA WireGuard connection setup
# Usage: pia-wg-up.sh <instance>
# Resolves region, generates ephemeral keys, registers with PIA API, brings up WireGuard
set -euo pipefail

INSTANCE=${1:-pia}

source /etc/pia/pia.conf
source "/etc/pia/${INSTANCE}.conf"

PIA_TOKEN=$(cat /run/pia/token)
CA_CERT=/etc/pia/ca.rsa.4096.crt
SERVERLIST_URL='https://serverlist.piaservers.net/vpninfo/servers/v6'
STATE_DIR="/run/pia/${INSTANCE}"
WG_CONF="/etc/wireguard/${INSTANCE}.conf"

if [[ ! -f $CA_CERT ]]; then
  echo "ERROR: CA certificate not found at ${CA_CERT}" >&2
  echo "Copy ca.rsa.4096.crt to /etc/pia/" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# --- Resolve region ---
all_region_data=$(curl -s "$SERVERLIST_URL" | head -1)
if [[ ${#all_region_data} -lt 1000 ]]; then
  echo "ERROR: Failed to fetch server list" >&2
  exit 1
fi

if [[ -n ${PREFERRED_REGION:-} ]]; then
  echo "Using configured region: ${PREFERRED_REGION}"
  selected_region=$PREFERRED_REGION
else
  echo "Auto-selecting region by lowest latency..."
  MAX_LATENCY=${MAX_LATENCY:-0.05}

  if [[ ${PIA_PF:-false} == "true" ]]; then
    meta_servers=$(echo "$all_region_data" | jq -r \
      '.regions[] | select(.port_forward==true) | .servers.meta[0].ip + " " + .id')
  else
    meta_servers=$(echo "$all_region_data" | jq -r \
      '.regions[] | .servers.meta[0].ip + " " + .id')
  fi

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

  while IFS= read -r line; do
    ip=$(echo "$line" | awk '{print $1}')
    id=$(echo "$line" | awk '{print $2}')
    time=$(LC_NUMERIC=C curl -o /dev/null -s \
      --connect-timeout "$MAX_LATENCY" \
      --write-out "%{time_connect}" \
      "http://${ip}:443" 2>/dev/null) || continue
    echo "${time} ${id}" >> "$tmpfile"
  done <<< "$meta_servers"

  if [[ ! -s "$tmpfile" ]]; then
    echo "ERROR: No region responded within ${MAX_LATENCY}s" >&2
    exit 1
  fi

  best=$(sort -n "$tmpfile" | head -1)
  selected_region=$(echo "$best" | awk '{print $2}')
  echo "Selected: ${selected_region} ($(echo "$best" | awk '{print $1}')s)"
fi

region_data=$(echo "$all_region_data" | jq --arg id "$selected_region" -r \
  '.regions[] | select(.id==$id)')
if [[ -z $region_data ]]; then
  echo "ERROR: Region '${selected_region}' not found" >&2
  exit 1
fi

WG_SERVER_IP=$(echo "$region_data" | jq -r '.servers.wg[0].ip')
WG_HOSTNAME=$(echo "$region_data" | jq -r '.servers.wg[0].cn')

echo "Server: ${WG_SERVER_IP} (${WG_HOSTNAME})"

# Write connection state for portforward to use
cat > "${STATE_DIR}/connection.env" <<EOF
WG_SERVER_IP=${WG_SERVER_IP}
WG_HOSTNAME=${WG_HOSTNAME}
EOF
chmod 600 "${STATE_DIR}/connection.env"

# Clean up stale interface if it exists (e.g. after unclean shutdown)
if ip link show "$INSTANCE" &>/dev/null; then
  echo "Cleaning up stale ${INSTANCE} interface..."
  wg-quick down "$INSTANCE" 2>/dev/null || true
fi

# Generate ephemeral WireGuard keys
privkey=$(wg genkey)
pubkey=$(echo "$privkey" | wg pubkey)

# Register key with PIA API
echo "Registering WireGuard key with PIA on ${WG_SERVER_IP}..."
wg_response=$(curl -s -G \
  --connect-to "${WG_HOSTNAME}::${WG_SERVER_IP}:" \
  --cacert "$CA_CERT" \
  --data-urlencode "pt=${PIA_TOKEN}" \
  --data-urlencode "pubkey=${pubkey}" \
  "https://${WG_HOSTNAME}:1337/addKey")

if [[ $(echo "$wg_response" | jq -r '.status') != "OK" ]]; then
  echo "ERROR: PIA API error: $(echo "$wg_response" | jq -r '.message // .status')" >&2
  exit 1
fi

# Parse response
peer_ip=$(echo "$wg_response" | jq -r '.peer_ip')
server_key=$(echo "$wg_response" | jq -r '.server_key')
server_port=$(echo "$wg_response" | jq -r '.server_port')

dns_line=""
if [[ ${PIA_DNS:-true} == "true" ]]; then
  dns_server=$(echo "$wg_response" | jq -r '.dns_servers[0]')
  dns_line="DNS = ${dns_server}"
fi

# Write WireGuard config
mkdir -p /etc/wireguard
cat > "$WG_CONF" <<EOF
[Interface]
Address = ${peer_ip}
PrivateKey = ${privkey}
${dns_line}

[Peer]
PublicKey = ${server_key}
AllowedIPs = ${ALLOWED_IPS:-0.0.0.0/0}
Endpoint = ${WG_SERVER_IP}:${server_port}
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONF"

# Bring up interface
echo "Bringing up ${INSTANCE}..."
wg-quick up "$INSTANCE"
echo "VPN connected via ${INSTANCE}"

# Start port forwarding if enabled
if [[ ${PIA_PF:-false} == "true" ]]; then
  echo "PIA_PF=true, starting port forwarding..."
  systemctl start "pia-portforward@${INSTANCE}"
fi
