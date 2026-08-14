#!/usr/bin/env bash
# Usage: server-status.sh <name>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: server-status.sh <name>}"
state_exists "$NAME" || die "No local state for '$NAME'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"

FQDN="$(state_read_field "$NAME" '.fqdn')"
SERVER_ID="$(state_read_field "$NAME" '.binarylane_server_id')"
PLAN="$(state_read_field "$NAME" '.plan')"
REGION="$(state_read_field "$NAME" '.region')"
LOCAL_STATUS="$(state_read_field "$NAME" '.status')"
LOCAL_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
TUNNEL_ENABLED="$(state_read_field "$NAME" '.cloudflare.tunnel_enabled // false')"
TUNNEL_HOSTNAME="$(state_read_field "$NAME" '.cloudflare.tunnel_hostname // empty')"
TUNNEL_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_id // empty')"

echo "============================================================"
echo "Status: $NAME ($FQDN)"
echo "============================================================"
echo "Local state status:   $LOCAL_STATUS"

if [ "$LOCAL_STATUS" = "DESTROYED" ]; then
  echo "(Server was destroyed — showing historical state only.)"
  echo "Provisioning record:  $(record_file "$NAME")"
  exit 0
fi

load_binarylane_key
BL="$(bl_api GET "/servers/$SERVER_ID")" 2>/dev/null || true
if [ -n "$BL" ]; then
  BL_STATUS="$(echo "$BL" | jq -r '.server.status // "unknown"')"
  BL_IP="$(echo "$BL" | jq -r '.server.networks.v4[]? | select(.type=="public") | .ip_address' | head -1)"
  echo "BinaryLane status:    $BL_STATUS"
  echo "BinaryLane IPv4:       ${BL_IP:-none}"
else
  echo "BinaryLane status:    could not fetch (check API access)"
  BL_IP="$LOCAL_IP"
fi

echo -n "DNS resolution ($FQDN):  "
RESOLVED="$(dig +short "$FQDN" @1.1.1.1 2>/dev/null | tail -1)"
if [ -n "$RESOLVED" ]; then
  echo "$RESOLVED $( [ "$RESOLVED" = "$BL_IP" ] && echo '(matches)' || echo '(MISMATCH)' )"
else
  echo "no answer"
fi

if [ -n "${BL_IP:-}" ]; then
  echo -n "SSH reachability:      "
  if timeout 8 ssh -i "$PROVISIONING_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${SSH_MULTIPLEX_OPTS[@]}" "$ADMIN_USER@$BL_IP" 'echo ok' >/dev/null 2>&1; then
    echo "OK ($ADMIN_USER@$BL_IP)"
  else
    echo "FAILED"
  fi

  echo -n "Apache (direct IP):    "
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$BL_IP/" || true)"
  echo "HTTP $CODE"
fi

if [ "$TUNNEL_ENABLED" = "true" ]; then
  echo -n "Cloudflare Tunnel:     "
  load_cloudflare_creds
  TSTATUS="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" 2>/dev/null | jq -r '.result.status // "unknown"')"
  echo "$TUNNEL_HOSTNAME via tunnel $TUNNEL_ID — status: $TSTATUS"
  if [ -n "${BL_IP:-}" ]; then
    echo -n "cloudflared on server: "
    timeout 8 ssh -i "$PROVISIONING_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${SSH_MULTIPLEX_OPTS[@]}" "$ADMIN_USER@$BL_IP" 'systemctl is-active cloudflared' 2>/dev/null || echo "unreachable"
  fi
else
  echo "Cloudflare Tunnel:     Disabled"
fi

echo "Provisioning record:  $(record_file "$NAME")"
echo "============================================================"
