#!/usr/bin/env bash
# Usage: destroy-container.sh <hostname> [--yes]
#
# Destroys a Proxmox LXC container previously created by this toolkit, and
# (once wired in) its internal DNS record and dedicated Cloudflare Tunnel.
# Requires typing the FQDN back to confirm unless --yes is passed. The
# human-readable provisioning record is kept as a historical audit trail
# (marked DESTROYED), never deleted.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/udm.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/cloudflare.sh"
require_jq

NAME="${1:?usage: destroy-container.sh <hostname> [--yes]}"
ASSUME_YES=false
[ "${2:-}" = "--yes" ] && ASSUME_YES=true

state_exists "$NAME" || die "No local state for '$NAME' — refusing to guess. Nothing to destroy."
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is already marked DESTROYED in local state."

FQDN="$(state_read_field "$NAME" '.fqdn')"
VMID="$(state_read_field "$NAME" '.vmid')"
NODE="$(state_read_field "$NAME" '.node')"
CONTAINER_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
DNS_CONFIGURED="$(state_read_field "$NAME" '.internal_dns.configured // false')"
UDM_OBJECT_ID="$(state_read_field "$NAME" '.internal_dns.udm_object_id // empty')"
CONTAINER_MAC="$(state_read_field "$NAME" '.mac_address // empty')"
TUNNEL_ENABLED="$(state_read_field "$NAME" '.cloudflare.tunnel_enabled // false')"
TUNNEL_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_id // empty')"
PUBLIC_HOSTNAME="$(state_read_field "$NAME" '.cloudflare.public_hostname // empty')"
LOCAL_OVERRIDE_ID="$(state_read_field "$NAME" '.cloudflare.local_dns_override_id // empty')"
ADDITIONAL_HOSTNAMES_JSON="$(state_read_field "$NAME" '.cloudflare.additional_hostnames // []')"
ADDITIONAL_COUNT="$(echo "$ADDITIONAL_HOSTNAMES_JSON" | jq 'length')"

load_proxmox_creds

# Positively identify the container before touching it.
CONFIG="$(pve_api GET "/nodes/$NODE/lxc/$VMID/config")" || die "Could not fetch container $VMID on $NODE to verify identity before deletion"
ACTUAL_HOSTNAME="$(echo "$CONFIG" | jq -r '.data.hostname')"
if [ "$ACTUAL_HOSTNAME" != "$NAME" ]; then
  die "SAFETY ABORT: Container $VMID on $NODE has hostname '$ACTUAL_HOSTNAME', expected '$NAME'. Refusing to delete — this does not match what local state recorded."
fi

echo "============================================================"
echo "The following will be PERMANENTLY deleted:"
echo "============================================================"
echo
echo "Proxmox LXC Container:"
echo "  Hostname: $NAME"
echo "  FQDN:     $FQDN"
echo "  VMID:     $VMID"
echo "  Node:     $NODE"
echo "  IP:       ${CONTAINER_IP:-unknown}"
echo
if [ "$DNS_CONFIGURED" = "true" ]; then
  echo "Internal DNS + DHCP reservation: $FQDN -> $CONTAINER_IP (UDM object $UDM_OBJECT_ID, will be deleted via API)"
else
  echo "Internal DNS: Not configured — nothing to remove"
fi
echo
if [ "$TUNNEL_ENABLED" = "true" ]; then
  echo "Cloudflare Tunnel: $TUNNEL_ID (will be deleted via API)"
  if [ -n "$LOCAL_OVERRIDE_ID" ]; then
    echo "Local DNS override: $PUBLIC_HOSTNAME -> $FQDN (UDM static-dns object $LOCAL_OVERRIDE_ID, will be deleted via API)"
  fi
  if [ "$ADDITIONAL_COUNT" -gt 0 ]; then
    echo "Additional vhosts (added via add-vhost.sh), each with its own CNAME + local DNS override, will also be deleted:"
    echo "$ADDITIONAL_HOSTNAMES_JSON" | jq -r '.[] | "  - \(.hostname)"'
  fi
else
  echo "Cloudflare Tunnel: Not configured"
fi
echo
echo "The provisioning record at $(record_file "$NAME") will be KEPT and marked DESTROYED (audit trail)."
echo "============================================================"

if ! $ASSUME_YES; then
  read -r -p "Type the FQDN ($FQDN) to confirm deletion: " TYPED
  [ "$TYPED" = "$FQDN" ] || { log "Confirmation did not match — aborted."; exit 1; }
fi

log "Stopping container $VMID on $NODE..."
pve_api POST "/nodes/$NODE/lxc/$VMID/status/stop" >/dev/null || warn "Stop request failed or container already stopped — continuing to delete"
sleep 3

log "Deleting container $VMID..."
pve_api DELETE "/nodes/$NODE/lxc/$VMID" >/dev/null || die "Container deletion failed — aborting before touching DNS/Cloudflare. Investigate manually."
log "Container deleted."

if [ "$TUNNEL_ENABLED" = "true" ] && [ -n "$TUNNEL_ID" ]; then
  load_cloudflare_token
  CF_ACCOUNT_ID="$(state_read_field "$NAME" '.cloudflare.account_id // empty')"
  TUNNEL_RECORD_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_dns_record_id // empty')"
  TUNNEL_ZONE_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_zone_id // empty')"
  if [ -n "$TUNNEL_RECORD_ID" ] && [ -n "$TUNNEL_ZONE_ID" ]; then
    log "Deleting Cloudflare Tunnel CNAME record $TUNNEL_RECORD_ID..."
    curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/${TUNNEL_ZONE_ID}/dns_records/${TUNNEL_RECORD_ID}" \
      || warn "Failed to delete tunnel CNAME — remove manually."
  fi
  if [ -n "$CF_ACCOUNT_ID" ]; then
    log "Deleting dedicated Cloudflare Tunnel $TUNNEL_ID..."
    TUNNEL_DELETED=false
    for i in $(seq 1 6); do
      CODE="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}")"
      if [ "$CODE" -lt 300 ]; then
        TUNNEL_DELETED=true
        break
      fi
      log "Tunnel still shows active connections (attempt $i/6) — waiting 20s..."
      sleep 20
    done
    $TUNNEL_DELETED || warn "Could not delete tunnel $TUNNEL_ID after 6 attempts (last HTTP $CODE) — remove manually in the Cloudflare dashboard."
  fi
  if [ -n "$LOCAL_OVERRIDE_ID" ]; then
    load_udm_creds
    log "Deleting local DNS override (object $LOCAL_OVERRIDE_ID)..."
    delete_local_dns_override "$LOCAL_OVERRIDE_ID" || warn "Failed to delete local DNS override $LOCAL_OVERRIDE_ID — remove manually from the UDM Pro."
  fi
  if [ "$ADDITIONAL_COUNT" -gt 0 ]; then
    load_udm_creds
    log "Deleting $ADDITIONAL_COUNT additional vhost(s) added via add-vhost.sh..."
    for i in $(seq 0 $((ADDITIONAL_COUNT - 1))); do
      AH_HOST="$(echo "$ADDITIONAL_HOSTNAMES_JSON" | jq -r ".[$i].hostname")"
      AH_RECORD_ID="$(echo "$ADDITIONAL_HOSTNAMES_JSON" | jq -r ".[$i].tunnel_dns_record_id // empty")"
      AH_ZONE_ID="$(echo "$ADDITIONAL_HOSTNAMES_JSON" | jq -r ".[$i].tunnel_zone_id // empty")"
      AH_OVERRIDE_ID="$(echo "$ADDITIONAL_HOSTNAMES_JSON" | jq -r ".[$i].local_dns_override_id // empty")"
      log "  - $AH_HOST"
      if [ -n "$AH_RECORD_ID" ] && [ -n "$AH_ZONE_ID" ]; then
        curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
          "https://api.cloudflare.com/client/v4/zones/${AH_ZONE_ID}/dns_records/${AH_RECORD_ID}" \
          || warn "Failed to delete CNAME for $AH_HOST — remove manually."
      fi
      if [ -n "$AH_OVERRIDE_ID" ]; then
        delete_local_dns_override "$AH_OVERRIDE_ID" || warn "Failed to delete local DNS override for $AH_HOST — remove manually from the UDM Pro."
      fi
    done
  fi
fi

if [ "$DNS_CONFIGURED" = "true" ]; then
  if [ -n "$UDM_OBJECT_ID" ] && [ -n "$CONTAINER_MAC" ]; then
    load_udm_creds
    log "Deleting UDM DHCP reservation + DNS record (object $UDM_OBJECT_ID, mac $CONTAINER_MAC)..."
    delete_dhcp_reservation "$UDM_OBJECT_ID" "$CONTAINER_MAC" || warn "Failed to delete UDM reservation $UDM_OBJECT_ID — remove manually."
  else
    warn "Internal DNS was marked configured but no UDM object id or mac address was recorded — remove the reservation manually from the UDM Pro."
  fi
fi

NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq --arg destroyed "$NOW" '.status = "DESTROYED" | .destroyed_at = $destroyed' "$(state_file "$NAME")")"

RECORD="$(record_file "$NAME")"
{
  echo
  echo "============================================================"
  echo "DESTROYED"
  echo "============================================================"
  echo "Status:"; echo "DESTROYED"
  echo "Destroyed:"; echo "$NOW"
  echo "Proxmox Container:"; echo "Deleted"
  echo "Internal DNS:"; echo "$( [ "$DNS_CONFIGURED" = "true" ] && echo 'Deleted' || echo 'Not Configured' )"
  echo "Cloudflare Tunnel:"; echo "$( [ "$TUNNEL_ENABLED" = "true" ] && echo Deleted || echo 'Not Configured' )"
  echo "Local DNS Override:"; echo "$( [ -n "$LOCAL_OVERRIDE_ID" ] && echo Deleted || echo 'Not Configured' )"
  echo "Additional Vhosts:"; echo "$( [ "$ADDITIONAL_COUNT" -gt 0 ] && echo "Deleted ($ADDITIONAL_COUNT)" || echo 'None' )"
} >> "$RECORD"
chmod 600 "$RECORD"

[ -n "${CONTAINER_IP:-}" ] && ssh_close_multiplexed "$ADMIN_USER" "$CONTAINER_IP"

log "Destroy complete for $FQDN. Record kept at $RECORD."
