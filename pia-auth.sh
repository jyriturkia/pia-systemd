#!/usr/bin/env bash
# PIA Authentication
# Authenticates with PIA and writes token to /run/pia/token
# Runs as singleton (shared by all instances) and refreshed by timer.
set -euo pipefail

source /etc/pia/pia.conf

STATE_DIR=/run/pia
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

echo "Authenticating with PIA..."
token_response=$(curl -s --location --request POST \
  'https://www.privateinternetaccess.com/api/client/v2/token' \
  --form "username=${PIA_USER}" \
  --form "password=${PIA_PASS}")

PIA_TOKEN=$(echo "$token_response" | jq -r '.token')
if [[ -z $PIA_TOKEN || $PIA_TOKEN == "null" ]]; then
  echo "ERROR: Authentication failed" >&2
  exit 1
fi

echo "$PIA_TOKEN" > "${STATE_DIR}/token"
chmod 600 "${STATE_DIR}/token"
echo "Token written to ${STATE_DIR}/token"
