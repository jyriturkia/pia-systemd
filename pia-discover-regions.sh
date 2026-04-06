#!/usr/bin/env bash
# Discover PIA WireGuard regions and measure latency.
# Run manually to find region IDs for /etc/pia/<instance>.conf
#
# Usage:
#   ./pia-discover-regions.sh               # all regions, 100ms timeout
#   ./pia-discover-regions.sh -p            # only port-forwarding regions
#   ./pia-discover-regions.sh -l 200        # 200ms timeout
#   ./pia-discover-regions.sh -p -l 200     # combined
set -euo pipefail

MAX_LATENCY_MS=100
PIA_PF=false

while getopts ":pl:" opt; do
  case $opt in
    p) PIA_PF=true ;;
    l) MAX_LATENCY_MS=$OPTARG ;;
    *) echo "Usage: $0 [-p] [-l <ms>]" >&2; exit 1 ;;
  esac
done

MAX_LATENCY=$(echo "scale=3; ${MAX_LATENCY_MS} / 1000" | bc)

SERVERLIST_URL='https://serverlist.piaservers.net/vpninfo/servers/v6'

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

echo "Testing latency (timeout: ${MAX_LATENCY_MS}ms)..."
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
  echo "Try a higher timeout with -l (e.g. -l 200)." >&2
  exit 1
fi

printf "  %-8s  %-25s  %s\n" "LATENCY" "REGION_ID" "NAME"
printf "  %-8s  %-25s  %s\n" "-------" "---------" "----"

sort -n "$tmpfile" | while IFS= read -r line; do
  time=$(echo "$line" | awk '{print $1}')
  id=$(echo "$line" | awk '{print $2}')
  name=$(echo "$line" | cut -d' ' -f3-)
  printf "  %-8s  %-25s  %s\n" "${time}s" "$id" "$name"
done

echo
echo "Set PREFERRED_REGION=<region_id> in /etc/pia/<instance>.conf"
