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
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
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

log "Configuring webroot + Apache vhost on $SERVER_NAME (via Ansible)..."
VHOST_VARS="$(jq -n --arg host "$FQDN" --arg php "$PHP_CHOICE" \
  '{site_vhost_hostname:$host, site_vhost_style:"vhosts_d", site_vhost_php:$php,
    site_vhost_welcome_subtitle:"Provisioned via the server-provisioning toolkit on the control host."}')"
ansible_run_playbook "playbooks/provisioning/site_vhost.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$VHOST_VARS" \
  || die "Remote site setup failed"
unset VHOST_VARS
PHP_VERSION_USED="$PHP_ARG"

if [ "$TUNNEL_ENABLED" = "true" ]; then
  [ -n "$TUNNEL_ID" ] || die "Server state says tunnel_enabled but no tunnel_id recorded — inspect state/${SERVER_NAME}.json"
  log "Updating tunnel ingress on $SERVER_NAME to include $FQDN (via Ansible)..."
  PRIMARY_TUNNEL_HOSTNAME="$(state_read_field "$SERVER_NAME" '.cloudflare.tunnel_hostname // empty')"
  ALL_HOSTNAMES=()
  [ -n "$PRIMARY_TUNNEL_HOSTNAME" ] && ALL_HOSTNAMES+=("$PRIMARY_TUNNEL_HOSTNAME")
  while IFS= read -r h; do [ -n "$h" ] && ALL_HOSTNAMES+=("$h"); done \
    < <(state_read_field "$SERVER_NAME" '.cloudflare.additional_hostnames[]?.hostname // empty')
  ALL_HOSTNAMES+=("$FQDN")

  HOSTNAMES_JSON="$(printf '%s\n' "${ALL_HOSTNAMES[@]}" | sort -u | jq -R . | jq -s .)"
  TUNNEL_INGRESS_VARS="$(jq -n --arg tid "$TUNNEL_ID" --argjson hostnames "$HOSTNAMES_JSON" \
    '{tunnel_ingress_tunnel_id:$tid, tunnel_ingress_hostnames:$hostnames}')"
  ansible_run_playbook "playbooks/provisioning/tunnel_ingress.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$TUNNEL_INGRESS_VARS" \
    || die "Failed to update tunnel ingress on the server"
  unset TUNNEL_INGRESS_VARS
fi

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

# ---------------------------------------------------------------------------
# State — track this hostname so future add-site.sh / tunnel_ingress runs
# know the full set of hostnames already routed through this server's tunnel
# (mirrors the Proxmox toolkit's cloudflare.additional_hostnames schema).
# ---------------------------------------------------------------------------
NOW="$(date -Iseconds)"
CURRENT_STATE="$(cat "$(state_file "$SERVER_NAME")")"
if [ "$(state_read_field "$SERVER_NAME" '.cloudflare.tunnel_hostname // empty')" = "$FQDN" ]; then
  NEW_STATE="$(echo "$CURRENT_STATE" | jq --arg updated "$NOW" '.updated_at = $updated')"
else
  NEW_STATE="$(echo "$CURRENT_STATE" | jq \
    --arg h "$FQDN" --arg rid "$RECORD_ID" --arg php "$PHP_VERSION_USED" --arg updated "$NOW" \
    '.updated_at = $updated
     | .cloudflare.additional_hostnames = ((.cloudflare.additional_hostnames // [])
         | map(select(.hostname != $h))
         + [{hostname:$h, dns_record_id:$rid, php:$php}])')"
fi
state_write "$SERVER_NAME" "$NEW_STATE"

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
