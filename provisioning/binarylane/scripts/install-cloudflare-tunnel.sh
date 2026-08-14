#!/usr/bin/env bash
# Runs on the control host. Creates (or reuses) a dedicated, locally-managed Cloudflare
# Tunnel for one server, installs cloudflared on that remote server with only
# its own connector token (never the control host's broader API credential), and points
# the public hostname at it via a proxied CNAME.
#
# Usage: install-cloudflare-tunnel.sh <name> <cf_hostname> <remote_ip> <ssh_user> <ssh_key>
# Idempotent: re-running for the same <name> reuses the existing tunnel.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: install-cloudflare-tunnel.sh <name> <cf_hostname> <remote_ip> <ssh_user> <ssh_key>}"
CF_HOSTNAME="${2:?}"
REMOTE_IP="${3:?}"
SSH_USER="${4:?}"
SSH_KEY="${5:?}"

load_cloudflare_creds

# The tunnel hostname can be on a completely different domain than the
# server's own --domain — never assume they share a zone.
CF_HOSTNAME_ZONE_ID="$(resolve_zone_id_for_hostname "$CF_HOSTNAME")"

TUNNEL_NAME="${NAME}-tunnel"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MULTIPLEX_OPTS[@]}")

# --- Find or create the dedicated tunnel -----------------------------------
log "Looking for existing tunnel named '$TUNNEL_NAME'..."
EXISTING="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")" || die "Cloudflare tunnel lookup failed"
TUNNEL_ID="$(echo "$EXISTING" | jq -r '.result[0].id // empty')"

if [ -n "$TUNNEL_ID" ]; then
  log "Reusing existing tunnel $TUNNEL_ID"
else
  log "Creating new locally-managed tunnel '$TUNNEL_NAME'"
  TUNNEL_SECRET="$(openssl rand -base64 32)"
  CREATE_PAYLOAD="$(jq -n --arg name "$TUNNEL_NAME" --arg secret "$TUNNEL_SECRET" --arg src "local" \
    '{name:$name, tunnel_secret:$secret, config_src:$src}')"
  unset TUNNEL_SECRET
  RESULT="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$CREATE_PAYLOAD")" || die "Tunnel creation failed"
  TUNNEL_ID="$(echo "$RESULT" | jq -r '.result.id')"
  [ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != "null" ] || die "Could not determine new tunnel ID from API response"
  log "Created tunnel $TUNNEL_ID"
fi

# --- Fetch a connector token and install cloudflared on the remote server --
log "Fetching connector token for tunnel $TUNNEL_ID"
TOKEN_RESULT="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")" || die "Could not fetch tunnel token"
CONNECTOR_TOKEN="$(echo "$TOKEN_RESULT" | jq -r '.result')"
[ -n "$CONNECTOR_TOKEN" ] && [ "$CONNECTOR_TOKEN" != "null" ] || die "Tunnel token response was empty"

log "Installing cloudflared on $REMOTE_IP for hostname $CF_HOSTNAME (token piped over SSH, never written to the control host's disk or logged)"
scp "${SSH_OPTS[@]}" "$HERE/scripts/install-cloudflared-remote.sh" "$SSH_USER@$REMOTE_IP:/tmp/install-cloudflared-remote.sh"
printf '%s' "$CONNECTOR_TOKEN" | ssh "${SSH_OPTS[@]}" "$SSH_USER@$REMOTE_IP" \
  "chmod +x /tmp/install-cloudflared-remote.sh && /tmp/install-cloudflared-remote.sh '$TUNNEL_ID' '$CF_HOSTNAME' && rm -f /tmp/install-cloudflared-remote.sh"
unset CONNECTOR_TOKEN
log "cloudflared installed and running on the remote server."

# --- DNS: proxied CNAME to this tunnel --------------------------------------
log "Creating/updating proxied CNAME $CF_HOSTNAME -> ${TUNNEL_ID}.cfargotunnel.com (zone $CF_HOSTNAME_ZONE_ID)"
EXISTING_CNAME="$(cf_api GET "/zones/${CF_HOSTNAME_ZONE_ID}/dns_records?type=CNAME&name=${CF_HOSTNAME}")" || die "Cloudflare DNS lookup failed"
RECORD_ID="$(echo "$EXISTING_CNAME" | jq -r '.result[0].id // empty')"
DNS_PAYLOAD="$(jq -n --arg fqdn "$CF_HOSTNAME" --arg target "${TUNNEL_ID}.cfargotunnel.com" '{type:"CNAME", name:$fqdn, content:$target, proxied:true, ttl:1}')"
if [ -n "$RECORD_ID" ]; then
  cf_api PUT "/zones/${CF_HOSTNAME_ZONE_ID}/dns_records/${RECORD_ID}" "$DNS_PAYLOAD" >/dev/null || die "Failed to update CNAME"
else
  RESULT="$(cf_api POST "/zones/${CF_HOSTNAME_ZONE_ID}/dns_records" "$DNS_PAYLOAD")" || die "Failed to create CNAME"
  RECORD_ID="$(echo "$RESULT" | jq -r '.result.id')"
fi
log "CNAME record id: $RECORD_ID"

# --- Verify tunnel health ----------------------------------------------------
log "Checking tunnel health..."
HEALTHY=false
for i in $(seq 1 12); do
  STATUS="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" | jq -r '.result.status')"
  [ "$STATUS" = "healthy" ] && { HEALTHY=true; break; }
  sleep 5
done
$HEALTHY && log "Tunnel healthy." || warn "Tunnel not confirmed healthy within 60s (status: ${STATUS:-unknown}) — check 'journalctl -u cloudflared' on the remote server."

echo "CLOUDFLARE_TUNNEL_ID=$TUNNEL_ID"
echo "CLOUDFLARE_TUNNEL_RECORD_ID=$RECORD_ID"
echo "CLOUDFLARE_TUNNEL_ZONE_ID=$CF_HOSTNAME_ZONE_ID"
