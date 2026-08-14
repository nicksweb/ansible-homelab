#!/usr/bin/env bash
# Usage: destroy-server.sh <name> [--yes]
#
# Destroys a BinaryLane server previously created by this toolkit, its
# Cloudflare A record, and (if applicable) its Cloudflare Tunnel ingress rule
# and CNAME. Requires typing the FQDN back to confirm unless --yes is passed.
# The human-readable provisioning record is kept as a historical audit trail
# (marked DESTROYED), never deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: destroy-server.sh <name> [--yes]}"
ASSUME_YES=false
[ "${2:-}" = "--yes" ] && ASSUME_YES=true

state_exists "$NAME" || die "No local state for '$NAME' — refusing to guess. Nothing to destroy."
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is already marked DESTROYED in local state."

FQDN="$(state_read_field "$NAME" '.fqdn')"
SERVER_ID="$(state_read_field "$NAME" '.binarylane_server_id')"
A_RECORD_ID="$(state_read_field "$NAME" '.cloudflare.dns_record_id // empty')"
ZONE_ID="$(state_read_field "$NAME" '.cloudflare.zone_id // empty')"
TUNNEL_ENABLED="$(state_read_field "$NAME" '.cloudflare.tunnel_enabled // false')"
TUNNEL_HOSTNAME="$(state_read_field "$NAME" '.cloudflare.tunnel_hostname // empty')"
TUNNEL_RECORD_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_dns_record_id // empty')"
TUNNEL_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_id // empty')"
TUNNEL_ZONE_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_zone_id // empty')"
# Older records (before tunnel_zone_id was tracked separately) assumed the
# tunnel hostname shared the server's own zone — fall back to that for them.
[ -z "$TUNNEL_ZONE_ID" ] && TUNNEL_ZONE_ID="$ZONE_ID"

load_binarylane_key
load_cloudflare_creds

# Positively identify the BinaryLane resource before touching it.
BL="$(bl_api GET "/servers/$SERVER_ID")" || die "Could not fetch BinaryLane server $SERVER_ID to verify identity before deletion"
BL_NAME="$(echo "$BL" | jq -r '.server.name')"
if [ "$BL_NAME" != "$FQDN" ]; then
  die "SAFETY ABORT: BinaryLane server $SERVER_ID has name '$BL_NAME', expected '$FQDN'. Refusing to delete — this does not match what local state recorded."
fi

echo "============================================================"
echo "The following will be PERMANENTLY deleted:"
echo "============================================================"
echo
echo "BinaryLane Server:"
echo "  Name: $FQDN"
echo "  ID:   $SERVER_ID"
echo
echo "Cloudflare DNS (A record):"
echo "  Name: $FQDN"
echo "  ID:   ${A_RECORD_ID:-none recorded}"
echo
if [ "$TUNNEL_ENABLED" = "true" ]; then
  echo "Cloudflare Tunnel (dedicated to this server):"
  echo "  Hostname:        $TUNNEL_HOSTNAME"
  echo "  Tunnel ID:       ${TUNNEL_ID:-none recorded}"
  echo "  CNAME record id: ${TUNNEL_RECORD_ID:-none recorded}"
  echo "  The tunnel itself will be deleted via the Cloudflare API (it belongs only to this server)"
else
  echo "Cloudflare Tunnel: Not Configured"
fi
echo
echo "The provisioning record at $(record_file "$NAME") will be KEPT and marked DESTROYED (audit trail)."
echo "============================================================"

if ! $ASSUME_YES; then
  read -r -p "Type the FQDN ($FQDN) to confirm deletion: " TYPED
  [ "$TYPED" = "$FQDN" ] || { log "Confirmation did not match — aborted."; exit 1; }
fi

log "Deleting BinaryLane server $SERVER_ID..."
bl_api DELETE "/servers/$SERVER_ID" >/dev/null || die "BinaryLane deletion failed — aborting before touching DNS. Investigate manually."
log "BinaryLane server deleted."
DESTROYED_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
[ -n "$DESTROYED_IP" ] && ssh_close_multiplexed "$ADMIN_USER" "$DESTROYED_IP"

if [ -n "$A_RECORD_ID" ]; then
  log "Deleting Cloudflare A record $A_RECORD_ID..."
  cf_api DELETE "/zones/${ZONE_ID}/dns_records/${A_RECORD_ID}" >/dev/null || warn "Failed to delete Cloudflare A record $A_RECORD_ID — remove manually."
fi

if [ "$TUNNEL_ENABLED" = "true" ]; then
  if [ -n "$TUNNEL_RECORD_ID" ]; then
    log "Deleting Cloudflare Tunnel CNAME record $TUNNEL_RECORD_ID..."
    cf_api DELETE "/zones/${TUNNEL_ZONE_ID}/dns_records/${TUNNEL_RECORD_ID}" >/dev/null || warn "Failed to delete tunnel CNAME $TUNNEL_RECORD_ID — remove manually."
  fi
  if [ -n "$TUNNEL_ID" ]; then
    log "Deleting dedicated Cloudflare Tunnel $TUNNEL_ID (the remote server it ran on is already gone)..."
    # Cloudflare rejects deletion with "active connections" for a short window
    # after the connector VM disappears (error 1022) — it hasn't noticed the
    # connection dropped yet. Retry with backoff rather than leaving it orphaned.
    TUNNEL_DELETED=false
    for i in $(seq 1 6); do
      TMP_ERR="$(mktemp)"
      if cf_api DELETE "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" >"$TMP_ERR" 2>&1; then
        TUNNEL_DELETED=true
        rm -f "$TMP_ERR"
        break
      fi
      if grep -qi "active connections" "$TMP_ERR"; then
        rm -f "$TMP_ERR"
        log "Tunnel still shows active connections (attempt $i/6) — waiting 20s before retry..."
        sleep 20
      else
        rm -f "$TMP_ERR"
        break
      fi
    done
    $TUNNEL_DELETED \
      && log "Tunnel $TUNNEL_ID deleted." \
      || warn "Failed to delete tunnel $TUNNEL_ID after retries — it may still show as inactive in the dashboard; remove manually."
  else
    warn "No tunnel ID recorded in state — nothing to delete via API. Check the Cloudflare dashboard for a leftover '${NAME}-tunnel'."
  fi
fi

NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq -n --arg destroyed "$NOW" '. ' <<< "$(cat "$(state_file "$NAME")")" | jq --arg destroyed "$NOW" '.status = "DESTROYED" | .destroyed_at = $destroyed')"

RECORD="$(record_file "$NAME")"
{
  echo
  echo "============================================================"
  echo "DESTROYED"
  echo "============================================================"
  echo "Provisioning Status:"; echo "DESTROYED"
  echo "Destroyed:"; echo "$NOW"
  echo "BinaryLane Server:"; echo "Deleted"
  echo "Cloudflare DNS Record:"; echo "Deleted"
  echo "Cloudflare Tunnel:"; echo "$( [ "$TUNNEL_ENABLED" = "true" ] && echo Deleted || echo 'Not Configured' )"
} >> "$RECORD"
chmod 600 "$RECORD"

log "Destroy complete for $FQDN. Record kept at $RECORD."
