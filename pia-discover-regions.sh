#!/usr/bin/env bash
# Discover PIA WireGuard regions and measure latency.
# Run manually to find region IDs for /etc/pia/<instance>.conf
#
# Usage:
#   ./pia-discover-regions.sh              # all regions
#   PIA_PF=true ./pia-discover-regions.sh  # only port-forwarding regions
#   MAX_LATENCY=0.2 ./pia-discover-regions.sh  # 200ms timeout
set -euo pipefail

SERVERLIST_URL='https://serverlist.piaservers.net/vpninfo/servers/v6'
MAX_LATENCY=${MAX_LATENCY:-0.05}
PIA_PF=${PIA_PF:-false}

# Source config if it exists (for PIA_PF, MAX_LATENCY defaults)
[[ -f /etc/pia/pia.conf ]] && source /etc/pia/pia.conf

# Allow env overrides after sourcing config
MAX_LATENCY=${MAX_LATENCY:-0.05}
PIA_PF=${PIA_PF:-false}

echo "Fetching server list..."
all_region_data=$(curl -s "$SERVERLIST_URL" | head -1)

if [[ ${#all_region_data} -lt 1000 ]]; then
  echo "ERROR: Failed to fetch server list" >&2
  exit 1
fi

if [[ $PIA_PF == "true" ]]; then
  echo "Filtering for port-forwarding capable regions only"
  regions=$(echo "$all_region_data" | jq -r \
    '.regions[] | select(.port_forward==true) |
     .servers.meta[0].ip + " " + .id + " " + .name + " " + (.geo|tostring)')
else
  regions=$(echo "$all_region_data" | jq -r \
    '.regions[] |
     .servers.meta[0].ip + " " + .id + " " + .name + " " + (.geo|tostring)')
fi

echo "Testing latency (timeout: ${MAX_LATENCY}s)..."
echo

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

while IFS= read -r line; do
  ip=$(echo "$line" | awk '{print $1}')
  id=$(echo "$line" | awk '{print $2}')
  name=$(echo "$line" | cut -d' ' -f3- | sed 's/ false$//' | sed 's/ true$/ (geo)/')

  time=$(LC_NUMERIC=C curl -o /dev/null -s \
    --connect-timeout "$MAX_LATENCY" \
    --write-out "%{time_connect}" \
    "http://${ip}:443" 2>/dev/null) || continue

  echo "${time} ${id} ${name}" >> "$tmpfile"
done <<< "$regions"

if [[ ! -s "$tmpfile" ]]; then
  echo "No region responded within ${MAX_LATENCY}s." >&2
  echo "Try increasing MAX_LATENCY (e.g. MAX_LATENCY=0.2)." >&2
  exit 1
fi

sort -n "$tmpfile" | while IFS= read -r line; do
  time=$(echo "$line" | awk '{print $1}')
  id=$(echo "$line" | awk '{print $2}')
  name=$(echo "$line" | cut -d' ' -f3-)
  printf "  %-8s  %-25s  %s\n" "${time}s" "$id" "$name"
done

echo
echo "Set PREFERRED_REGION=<region_id> in /etc/pia/<instance>.conf"
