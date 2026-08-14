#!/usr/bin/env bash
# Add (or update) a website on a server this toolkit provisioned, adapted so
# each provisioned server routes through its own dedicated Cloudflare Tunnel
# (if it has one) rather than a shared one.
#
# Usage:
#   add-site.sh <server-name> <subdomain> <domain> [php-version|php|none] [--proxy on|off]
#
# Examples:
#   add-site.sh sacloudserver01 shop example.com 8.3
#   add-site.sh sacloudserver01 @ example.com php        # apex domain, highest installed PHP
#   add-site.sh sacloudserver02 status example.com none  # static site
#
# Routing is automatic based on how the server was provisioned:
#   - If it has a dedicated Cloudflare Tunnel (--cloudflare-tunnel at
#     provision time): adds an ingress rule to that tunnel + a proxied CNAME.
#   - Otherwise: creates a direct A record to the server's public IP
#     (proxied by default for a normal website — override with --proxy off).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

SERVER_NAME="${1:?usage: add-site.sh <server-name> <subdomain> <domain> [php-version|php|none] [--proxy on|off]}"
SUBDOMAIN="${2:?}"
DOMAIN="${3:?}"
PHP_ARG="${4:-php}"
PROXY="on"
if [ "${5:-}" = "--proxy" ]; then PROXY="${6:?--proxy requires on|off}"; fi
case "$PROXY" in on|off) ;; *) die "--proxy must be 'on' or 'off'" ;; esac

state_exists "$SERVER_NAME" || die "No local state for server '$SERVER_NAME'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
STATUS="$(state_read_field "$SERVER_NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "Server '$SERVER_NAME' is marked DESTROYED in local state."

PUBLIC_IP="$(state_read_field "$SERVER_NAME" '.public_ipv4')"
TUNNEL_ENABLED="$(state_read_field "$SERVER_NAME" '.cloudflare.tunnel_enabled // false')"
TUNNEL_ID="$(state_read_field "$SERVER_NAME" '.cloudflare.tunnel_id // empty')"

if [ "$SUBDOMAIN" = "@" ]; then FQDN="$DOMAIN"; else FQDN="${SUBDOMAIN}.${DOMAIN}"; fi

case "$PHP_ARG" in
  none) PHP_CHOICE="none" ;;
  php) PHP_CHOICE="highest" ;;
  *) PHP_CHOICE="$PHP_ARG" ;;
esac

load_cloudflare_creds

# --- Validate the domain against the *live* Cloudflare zone list for this account ---
log "Validating '$DOMAIN' against live Cloudflare zones..."
ZONE_ID="$(resolve_zone_id_for_domain "$DOMAIN")" || exit 1

echo "============================================================"
echo "Add site: $FQDN"
echo "============================================================"
echo "Server:        $SERVER_NAME ($PUBLIC_IP)"
echo "PHP:           $PHP_ARG"
echo "Routing:       $( [ "$TUNNEL_ENABLED" = "true" ] && echo "via this server's dedicated tunnel ($TUNNEL_ID)" || echo "direct A record -> $PUBLIC_IP (proxy: $PROXY)" )"
echo "Cloudflare Zone: $DOMAIN ($ZONE_ID)"
echo "============================================================"

log "Configuring webroot + Apache vhost on $SERVER_NAME..."
SSH_OPTS=(-i "$PROVISIONING_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MULTIPLEX_OPTS[@]}")
scp "${SSH_OPTS[@]}" "$HERE/scripts/add-site-remote.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/add-site-remote.sh"
REMOTE_OUT="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" \
  "chmod +x /tmp/add-site-remote.sh && /tmp/add-site-remote.sh '$FQDN' '$PHP_CHOICE' '$TUNNEL_ENABLED' && rm -f /tmp/add-site-remote.sh")" \
  || die "Remote site setup failed"
echo "$REMOTE_OUT"
PHP_VERSION_USED="$(echo "$REMOTE_OUT" | grep '^PHP_VERSION_USED=' | cut -d= -f2)"

# --- DNS ---
if [ "$TUNNEL_ENABLED" = "true" ]; then
  [ -n "$TUNNEL_ID" ] || die "Server state says tunnel_enabled but no tunnel_id recorded — inspect state/${SERVER_NAME}.json"
  log "Creating/updating proxied CNAME $FQDN -> ${TUNNEL_ID}.cfargotunnel.com"
  EXISTING="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${FQDN}")" || die "Cloudflare DNS lookup failed"
  RECORD_ID="$(echo "$EXISTING" | jq -r '.result[0].id // empty')"
  PAYLOAD="$(jq -n --arg fqdn "$FQDN" --arg target "${TUNNEL_ID}.cfargotunnel.com" '{type:"CNAME", name:$fqdn, content:$target, proxied:true, ttl:1}')"
else
  log "Creating/updating A record $FQDN -> $PUBLIC_IP (proxy: $PROXY)"
  PROXIED_BOOL="false"; [ "$PROXY" = "on" ] && PROXIED_BOOL="true"
  EXISTING="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=A&name=${FQDN}")" || die "Cloudflare DNS lookup failed"
  RECORD_ID="$(echo "$EXISTING" | jq -r '.result[0].id // empty')"
  PAYLOAD="$(jq -n --arg fqdn "$FQDN" --arg ip "$PUBLIC_IP" --argjson proxied "$PROXIED_BOOL" '{type:"A", name:$fqdn, content:$ip, proxied:$proxied, ttl:1}')"
fi
if [ -n "$RECORD_ID" ]; then
  cf_api PUT "/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "$PAYLOAD" >/dev/null || die "Failed to update DNS record"
else
  RESULT="$(cf_api POST "/zones/${ZONE_ID}/dns_records" "$PAYLOAD")" || die "Failed to create DNS record"
  RECORD_ID="$(echo "$RESULT" | jq -r '.result.id')"
fi
log "DNS record id: $RECORD_ID"

# --- Verify ---
log "Verifying HTTP..."
sleep 3
if [ "$TUNNEL_ENABLED" = "true" ]; then
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${FQDN}/" || true)"
else
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${FQDN}" "http://${PUBLIC_IP}/" || true)"
fi
log "HTTP check: $HTTP_CODE"

# --- Append to the provisioning record (non-secret) ---
RECORD="$(record_file "$SERVER_NAME")"
if [ -f "$RECORD" ]; then
  {
    echo
    echo "------------------------------------------------------------"
    echo "Site added: $FQDN"
    echo "  PHP: ${PHP_VERSION_USED:-none}   Routing: $( [ "$TUNNEL_ENABLED" = "true" ] && echo tunnel || echo "direct (proxy: $PROXY)" )   DNS record: $RECORD_ID   Added: $(date -Iseconds)"
  } >> "$RECORD"
  chmod 600 "$RECORD"
fi

cat <<SUMMARY

============================================================
Site ready: $FQDN
============================================================
Server:        $SERVER_NAME
PHP:           ${PHP_VERSION_USED:-none}
Routing:       $( [ "$TUNNEL_ENABLED" = "true" ] && echo "Cloudflare Tunnel ($TUNNEL_ID)" || echo "Direct A record" )
DNS Record ID: $RECORD_ID
HTTP Check:    $HTTP_CODE
============================================================
SUMMARY
