#!/usr/bin/env bash
# Runs on the control host. Creates (or reuses) a dedicated, locally-managed Cloudflare
# Tunnel for one container, installs cloudflared on that container with only
# its own connector token, and points the public hostname at it via a
# proxied CNAME. Same pattern as the BinaryLane workflow's
# install-cloudflare-tunnel.sh, using the shared common/cloudflare.sh helpers.
#
# Usage: install-cloudflare-tunnel.sh <name> <public_hostname> <container_ip> <ssh_user> <ssh_key>
# Idempotent: re-running for the same <name> reuses the existing tunnel.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/cloudflare.sh"
require_jq

NAME="${1:?usage: install-cloudflare-tunnel.sh <name> <public_hostname> <container_ip> <ssh_user> <ssh_key>}"
PUBLIC_HOSTNAME="${2:?}"
CONTAINER_IP="${3:?}"
SSH_USER="${4:?}"
SSH_KEY="${5:?}"

load_cloudflare_token
CF_ACCOUNT_ID="$(sed -n 's/^CLOUDFLARE_ACCOUNT_ID=//p' "$API_AUTH_FILE" 2>/dev/null | head -n1)"
[ -n "$CF_ACCOUNT_ID" ] || die "Could not parse CLOUDFLARE_ACCOUNT_ID from $API_AUTH_FILE (non-secret — from the Cloudflare dashboard or GET /accounts)"

HOSTNAME_ZONE_ID="$(resolve_zone_id_for_hostname "$PUBLIC_HOSTNAME")"
TUNNEL_NAME="${NAME}-tunnel"
ssh_opts "$SSH_KEY"

log "Looking for existing tunnel named '$TUNNEL_NAME'..."
TUNNEL_ID="$(create_or_reuse_tunnel "$TUNNEL_NAME")"
log "Tunnel: $TUNNEL_ID"

log "Fetching connector token for tunnel $TUNNEL_ID"
CONNECTOR_TOKEN="$(fetch_tunnel_token "$TUNNEL_ID")"

log "Installing cloudflared on $CONTAINER_IP for hostname $PUBLIC_HOSTNAME (token piped over SSH, never written to disk or logged)"
scp "${SSH_OPTS[@]}" "$PROVISIONING_ROOT/common/install-cloudflared-remote.sh" "$SSH_USER@$CONTAINER_IP:/tmp/install-cloudflared-remote.sh"
printf '%s' "$CONNECTOR_TOKEN" | ssh "${SSH_OPTS[@]}" "$SSH_USER@$CONTAINER_IP" \
  "chmod +x /tmp/install-cloudflared-remote.sh && sudo /tmp/install-cloudflared-remote.sh '$TUNNEL_ID' '$PUBLIC_HOSTNAME' && rm -f /tmp/install-cloudflared-remote.sh"
unset CONNECTOR_TOKEN
log "cloudflared installed and running."

log "Creating/updating proxied CNAME $PUBLIC_HOSTNAME -> ${TUNNEL_ID}.cfargotunnel.com (zone $HOSTNAME_ZONE_ID)"
RECORD_ID="$(create_or_update_cname "$PUBLIC_HOSTNAME" "$HOSTNAME_ZONE_ID" "${TUNNEL_ID}.cfargotunnel.com")"
log "CNAME record id: $RECORD_ID"

log "Checking tunnel health..."
HEALTHY=false
for i in $(seq 1 12); do
  # `|| echo error` matters here: under `set -e`, a plain assignment from a
  # failing command substitution (unlike a `local`-prefixed one) aborts the
  # whole script immediately — confirmed via direct testing. Without this,
  # one transient Cloudflare API hiccup during polling would silently kill
  # the entire provisioning run instead of just retrying like this loop
  # is supposed to.
  STATUS="$(tunnel_health "$TUNNEL_ID" || echo "error")"
  [ "$STATUS" = "healthy" ] && { HEALTHY=true; break; }
  sleep 5
done
$HEALTHY && log "Tunnel healthy." || warn "Tunnel not confirmed healthy within 60s (status: ${STATUS:-unknown})"

echo "CLOUDFLARE_TUNNEL_ID=$TUNNEL_ID"
echo "CLOUDFLARE_TUNNEL_RECORD_ID=$RECORD_ID"
echo "CLOUDFLARE_TUNNEL_ZONE_ID=$HOSTNAME_ZONE_ID"
echo "CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID"
