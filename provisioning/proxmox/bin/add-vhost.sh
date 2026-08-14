#!/usr/bin/env bash
# Add an additional public hostname (and its own vhost) to an EXISTING
# container previously created by provision-container.sh. That script only
# ever wires up ONE public hostname, at creation time; this is the
# "host + many virtual hosts under it" case — reuses the container's
# existing Cloudflare Tunnel (adding a route + CNAME rather than creating a
# second tunnel), expands its TLS cert with another SAN if it has one, adds
# a local DNS override so LAN clients resolve it directly too, and gives it
# its own Apache vhost (own docroot, own content).
#
# Usage: add-vhost.sh <container_hostname> <public_hostname> [--enable-tls] [--dry-run] [--yes]
#   <container_hostname>  the existing container's short name, e.g. host004
#   <public_hostname>     the new hostname to add, e.g. app-test21.example.net
#   --enable-tls           only relevant if the container has NO existing cert
#                           (tls_enabled=false in state): issues one covering
#                           both the internal FQDN and this new hostname. If
#                           the container already has a cert, it's expanded
#                           automatically — no flag needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/cloudflare.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/udm.sh"
require_jq

NAME="${1:?usage: add-vhost.sh <container_hostname> <public_hostname> [--enable-tls] [--dry-run] [--yes]}"
NEW_PUBLIC_HOSTNAME="${2:?usage: add-vhost.sh <container_hostname> <public_hostname> [--enable-tls] [--dry-run] [--yes]}"
shift 2
ENABLE_TLS=false DRY_RUN=false ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --enable-tls) ENABLE_TLS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

state_exists "$NAME" || die "No local state for '$NAME' — run provision-container.sh first."
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is marked DESTROYED — nothing to add a vhost to."

FQDN="$(state_read_field "$NAME" '.fqdn')"
CONTAINER_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
[ -n "$CONTAINER_IP" ] || die "No IP recorded for '$NAME' in local state — investigate before proceeding."
TLS_ENABLED="$(state_read_field "$NAME" '.tls_enabled // false')"
TUNNEL_ENABLED="$(state_read_field "$NAME" '.cloudflare.tunnel_enabled // false')"
TUNNEL_ID="$(state_read_field "$NAME" '.cloudflare.tunnel_id // empty')"
PRIMARY_PUBLIC="$(state_read_field "$NAME" '.cloudflare.public_hostname // empty')"

# ---------------------------------------------------------------------------
# Collision check — same principle as provision-container.sh's upfront
# --public-hostname guard: refuse if this hostname is already claimed by a
# DIFFERENT, non-destroyed container (primary or additional), since
# proceeding would silently steal its CNAME/override. Re-running for the
# SAME container is fine — treated as an idempotent repair/refresh.
# ---------------------------------------------------------------------------
ALREADY_ON_THIS_CONTAINER=false
for f in "$STATE_DIR"/*.json; do
  [ -f "$f" ] || continue
  OTHER_NAME="$(jq -r '.name' "$f")"
  OTHER_STATUS="$(jq -r '.status' "$f")"
  [ "$OTHER_STATUS" = "DESTROYED" ] && continue
  OTHER_PRIMARY="$(jq -r '.cloudflare.public_hostname // empty' "$f")"
  OTHER_ADDITIONAL="$(jq -r '.cloudflare.additional_hostnames[]?.hostname // empty' "$f")"
  if [ "$OTHER_PRIMARY" = "$NEW_PUBLIC_HOSTNAME" ] || printf '%s\n' "$OTHER_ADDITIONAL" | grep -qx "$NEW_PUBLIC_HOSTNAME"; then
    if [ "$OTHER_NAME" = "$NAME" ]; then
      ALREADY_ON_THIS_CONTAINER=true
    else
      die "'$NEW_PUBLIC_HOSTNAME' is already in use by '$OTHER_NAME' (status: $OTHER_STATUS). Refusing to proceed — this would silently steal its Cloudflare CNAME and local DNS override."
    fi
  fi
done
$ALREADY_ON_THIS_CONTAINER && warn "'$NEW_PUBLIC_HOSTNAME' is already recorded for '$NAME' — re-running to confirm/repair rather than duplicate."

cat <<PLAN

============================================================
Add Vhost Plan
============================================================
Container:            $NAME ($FQDN, $CONTAINER_IP)
New public hostname:  $NEW_PUBLIC_HOSTNAME
Cloudflare Tunnel:     $( $TUNNEL_ENABLED && echo "reuse existing tunnel ($TUNNEL_ID) — add a route + CNAME" || echo "no tunnel yet — a NEW dedicated tunnel will be created" )
Local DNS override:   $NEW_PUBLIC_HOSTNAME -> $FQDN (no-hairpin on the LAN)
TLS:                  $( $TLS_ENABLED && echo "expand this container's existing certificate to also cover $NEW_PUBLIC_HOSTNAME" || { $ENABLE_TLS && echo "issue a NEW certificate covering $FQDN + $NEW_PUBLIC_HOSTNAME"; } || echo "skipped — container has no TLS and --enable-tls wasn't passed" )
Web vhost:             new Apache vhost with its own docroot/content
============================================================

PLAN

if $DRY_RUN; then
  log "Dry run — no changes made."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Proceed? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 1; }
fi

ssh_opts "$PROVISIONING_SSH_KEY"

# ---------------------------------------------------------------------------
# Tunnel: reuse (add a route to the existing one) or create fresh.
# ---------------------------------------------------------------------------
NEW_RECORD_ID="" NEW_ZONE_ID="" NEW_ACCOUNT_ID=""
if ! $TUNNEL_ENABLED; then
  log "No existing tunnel for $NAME — creating a new dedicated tunnel for $NEW_PUBLIC_HOSTNAME..."
  TUNNEL_OUT="$("$HERE/scripts/install-cloudflare-tunnel.sh" "$NAME" "$NEW_PUBLIC_HOSTNAME" "$CONTAINER_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY")" || die "Cloudflare Tunnel provisioning failed"
  TUNNEL_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ID=' | cut -d= -f2)"
  NEW_RECORD_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_RECORD_ID=' | cut -d= -f2)"
  NEW_ZONE_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ZONE_ID=' | cut -d= -f2)"
  NEW_ACCOUNT_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_ACCOUNT_ID=' | cut -d= -f2)"
  log "Tunnel ready: id=$TUNNEL_ID"
else
  log "Reusing existing tunnel $TUNNEL_ID — adding a CNAME for $NEW_PUBLIC_HOSTNAME..."
  load_cloudflare_token
  NEW_ZONE_ID="$(resolve_zone_id_for_hostname "$NEW_PUBLIC_HOSTNAME")"
  NEW_RECORD_ID="$(create_or_update_cname "$NEW_PUBLIC_HOSTNAME" "$NEW_ZONE_ID" "${TUNNEL_ID}.cfargotunnel.com")"
  NEW_ACCOUNT_ID="$(state_read_field "$NAME" '.cloudflare.account_id')"
  log "CNAME record id: $NEW_RECORD_ID"

  log "Updating tunnel ingress on $CONTAINER_IP to include $NEW_PUBLIC_HOSTNAME..."
  ALL_HOSTNAMES=()
  [ -n "$PRIMARY_PUBLIC" ] && ALL_HOSTNAMES+=("$PRIMARY_PUBLIC")
  while IFS= read -r h; do [ -n "$h" ] && ALL_HOSTNAMES+=("$h"); done \
    < <(state_read_field "$NAME" '.cloudflare.additional_hostnames[]?.hostname // empty')
  ALL_HOSTNAMES+=("$NEW_PUBLIC_HOSTNAME")

  REMOTE_HOSTNAME_ARGS=""
  for h in "${ALL_HOSTNAMES[@]}"; do
    REMOTE_HOSTNAME_ARGS="$REMOTE_HOSTNAME_ARGS '$h'"
  done
  scp "${SSH_OPTS[@]}" "$HERE/scripts/update-tunnel-ingress.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/update-tunnel-ingress.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
    "chmod +x /tmp/update-tunnel-ingress.sh && /tmp/update-tunnel-ingress.sh '$TUNNEL_ID'$REMOTE_HOSTNAME_ARGS && rm -f /tmp/update-tunnel-ingress.sh" \
    || die "Failed to update tunnel ingress on the container"
fi

# ---------------------------------------------------------------------------
# Local DNS override
# ---------------------------------------------------------------------------
log "Creating local DNS override so $NEW_PUBLIC_HOSTNAME resolves directly to $FQDN for LAN clients..."
load_udm_creds
NEW_OVERRIDE_ID="$(create_local_dns_override "$NEW_PUBLIC_HOSTNAME" "$FQDN")"
[ -n "$NEW_OVERRIDE_ID" ] && [ "$NEW_OVERRIDE_ID" != "null" ] || warn "Local DNS override creation did not return an id — check manually"
log "Local DNS override ready (id: $NEW_OVERRIDE_ID)"

# ---------------------------------------------------------------------------
# TLS — expand the existing cert if there is one, or issue a fresh one
# covering both names if --enable-tls was passed for a container that never
# had TLS before.
# ---------------------------------------------------------------------------
TLS_COVERED=false
if $TLS_ENABLED || $ENABLE_TLS; then
  load_cloudflare_token
  log "Ensuring the certificate for $FQDN covers $NEW_PUBLIC_HOSTNAME too..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-https-dns01.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-https-dns01.sh"
  if printf '%s' "$CF_API_TOKEN" | ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
      "chmod +x /tmp/install-https-dns01.sh && /tmp/install-https-dns01.sh '$FQDN' '$LETSENCRYPT_EMAIL' '$NEW_PUBLIC_HOSTNAME' && rm -f /tmp/install-https-dns01.sh" 2>&1; then
    TLS_COVERED=true
    log "Certificate now covers $NEW_PUBLIC_HOSTNAME."
  else
    warn "Certificate issuance/expansion failed — check the output above. The vhost will still be created but will be HTTP only until this is resolved."
  fi
else
  log "Container has no TLS and --enable-tls wasn't passed — vhost will be HTTP only."
fi

# ---------------------------------------------------------------------------
# Web vhost
# ---------------------------------------------------------------------------
log "Installing vhost for $NEW_PUBLIC_HOSTNAME..."
scp "${SSH_OPTS[@]}" "$HERE/scripts/install-test-vhost.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-test-vhost.sh"
WEB_OK=false
if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
    "chmod +x /tmp/install-test-vhost.sh && /tmp/install-test-vhost.sh '$FQDN' '$NEW_PUBLIC_HOSTNAME' && rm -f /tmp/install-test-vhost.sh"; then
  WEB_OK=true
  log "Vhost active."
else
  warn "Vhost install failed — check the output above."
fi

# ---------------------------------------------------------------------------
# State + provisioning record
# ---------------------------------------------------------------------------
NOW="$(date -Iseconds)"
CURRENT_STATE="$(cat "$(state_file "$NAME")")"
if [ "$PRIMARY_PUBLIC" = "$NEW_PUBLIC_HOSTNAME" ]; then
  log "'$NEW_PUBLIC_HOSTNAME' is this container's primary public hostname already — state unchanged."
  NEW_STATE="$(echo "$CURRENT_STATE" | jq --arg updated "$NOW" '.updated_at = $updated')"
else
  NEW_STATE="$(echo "$CURRENT_STATE" | jq \
    --arg h "$NEW_PUBLIC_HOSTNAME" --arg rid "$NEW_RECORD_ID" --arg oid "$NEW_OVERRIDE_ID" \
    --arg zid "$NEW_ZONE_ID" --argjson tls "$TLS_COVERED" --arg updated "$NOW" \
    --arg tunnel_id "$TUNNEL_ID" --arg account_id "$NEW_ACCOUNT_ID" \
    '.updated_at = $updated
     | .cloudflare.tunnel_enabled = true
     | .cloudflare.tunnel_id = (.cloudflare.tunnel_id // $tunnel_id)
     | .cloudflare.account_id = (.cloudflare.account_id // $account_id)
     | .cloudflare.additional_hostnames = ((.cloudflare.additional_hostnames // [])
         | map(select(.hostname != $h))
         + [{hostname:$h, tunnel_dns_record_id:$rid, tunnel_zone_id:$zid, local_dns_override_id:$oid, tls_covered:$tls}])')"
fi
state_write "$NAME" "$NEW_STATE"

RECORD="$(record_file "$NAME")"
{
  echo
  echo "------------------------------------------------------------"
  echo "Additional Vhost Added: $NOW"
  echo "------------------------------------------------------------"
  echo "Public Hostname:"; echo "$NEW_PUBLIC_HOSTNAME"
  echo "Cloudflare Tunnel:"; echo "$TUNNEL_ID (shared with this container's other public hostnames)"
  echo "Local DNS Override:"; echo "$NEW_PUBLIC_HOSTNAME -> $FQDN (UDM static-dns object $NEW_OVERRIDE_ID)"
  echo "HTTPS:"; echo "$( $TLS_COVERED && echo "Enabled — https://$NEW_PUBLIC_HOSTNAME/" || echo 'Not covered' )"
  echo "Web Vhost:"; echo "$( $WEB_OK && echo "Enabled — own docroot/content" || echo 'Failed — check logs' )"
} >> "$RECORD"
chmod 600 "$RECORD"

cat <<SUMMARY

============================================================
Vhost Added
============================================================
Container:            $NAME ($FQDN)
Public hostname:       $NEW_PUBLIC_HOSTNAME
Cloudflare Tunnel:     $TUNNEL_ID
Local DNS override:   $NEW_OVERRIDE_ID
HTTPS:                 $( $TLS_COVERED && echo "https://$NEW_PUBLIC_HOSTNAME/" || echo "Not configured" )
Provisioning record:  $RECORD
============================================================
SUMMARY
