#!/usr/bin/env bash
# Add a static website to a --role docker server: webroot + nginx server
# block in the `web` container (docker_web_static role, converged from the
# full site list in state), then a tunnel route + proxied CNAME for it.
# Only scaffolds a placeholder page — push real content with deploy-site.sh.
# Idempotent: re-running never touches an existing site's content.
#
# Usage:
#   add-static-site.sh <server-name> <subdomain> <domain>
#
# Examples:
#   add-static-site.sh web01 docs example.com
#   add-static-site.sh web01 @ example.com   # apex domain
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
# shellcheck disable=SC1091
source "$HERE/lib/docker.sh"
require_jq

SERVER_NAME="${1:?usage: add-static-site.sh <server-name> <subdomain> <domain>}"
SUBDOMAIN="${2:?}"
DOMAIN="${3:?}"
if [ "$SUBDOMAIN" = "@" ]; then FQDN="$DOMAIN"; else FQDN="${SUBDOMAIN}.${DOMAIN}"; fi

docker_require_server "$SERVER_NAME"
load_cloudflare_creds
log "Validating '$DOMAIN' against live Cloudflare zones..."
resolve_zone_id_for_domain "$DOMAIN" >/dev/null || exit 1

echo "============================================================"
echo "Add static site: $FQDN"
echo "Server: $SERVER_NAME ($PUBLIC_IP), tunnel $TUNNEL_ID"
echo "============================================================"

SITES="$(jq -c --arg s "$FQDN" '(.docker.sites // []) + [$s] | unique' "$(state_file "$SERVER_NAME")")"
log "Scaffolding webroot + nginx conf on $SERVER_NAME..."
ansible_run_playbook "playbooks/provisioning/docker_web_sites.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" \
  "$(jq -n --argjson sites "$SITES" '{docker_web_static_sites:$sites}')" \
  || die "docker_web_sites Ansible playbook failed"
docker_state_update "$SERVER_NAME" '.docker.sites = $sites' --argjson sites "$SITES"

docker_route_upsert "$SERVER_NAME" "$FQDN" "http://web:80"
HTTP_CODE="$(docker_https_check "$FQDN")"
log "HTTPS check: $HTTP_CODE"

RECORD="$(record_file "$SERVER_NAME")"
if [ -f "$RECORD" ]; then
  printf '\n------------------------------------------------------------\nStatic site added: %s\n  DNS record: %s   HTTPS check: %s   Added: %s\n' \
    "$FQDN" "$ROUTE_RECORD_ID" "$HTTP_CODE" "$(date -Iseconds)" >> "$RECORD"
fi

cat <<SUMMARY

============================================================
Site scaffolded: https://$FQDN/ ($HTTP_CODE)
============================================================
Next: push real content with
  $HERE/bin/deploy-site.sh $SERVER_NAME $FQDN <local-build-dir>
SUMMARY
