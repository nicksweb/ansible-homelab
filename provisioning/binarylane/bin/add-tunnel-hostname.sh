#!/usr/bin/env bash
# Route an extra public hostname through a --role docker server's tunnel to
# any service on its shared Docker networks (e.g. NPM's admin UI). The
# general form of add-static-site.sh. Idempotent by hostname: re-running
# with a different <service> repoints the existing route.
#
# Usage: add-tunnel-hostname.sh <server-name> <hostname> <service>
#
# Examples:
#   add-tunnel-hostname.sh web01 grafana.example.com http://grafana:3000
#   add-tunnel-hostname.sh web01 web01-nginx.example.com http://npm:80
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
# shellcheck disable=SC1091
source "$HERE/lib/docker.sh"
require_jq

SERVER_NAME="${1:?usage: add-tunnel-hostname.sh <server-name> <hostname> <service>}"
FQDN="${2:?}"
SERVICE="${3:?}"
[[ "$SERVICE" =~ ^(https?|tcp|ssh)://[A-Za-z0-9._-]+(:[0-9]+)?/?$ ]] || die "Service must look like http://container:port (got '$SERVICE')"

docker_require_server "$SERVER_NAME"
load_cloudflare_creds

echo "============================================================"
echo "Add tunnel route: $FQDN -> $SERVICE"
echo "Server: $SERVER_NAME ($PUBLIC_IP), tunnel $TUNNEL_ID"
echo "============================================================"

docker_route_upsert "$SERVER_NAME" "$FQDN" "$SERVICE"
HTTP_CODE="$(docker_https_check "$FQDN")"
log "HTTPS check: $HTTP_CODE"

RECORD="$(record_file "$SERVER_NAME")"
if [ -f "$RECORD" ]; then
  printf '\n------------------------------------------------------------\nTunnel route added: %s -> %s\n  DNS record: %s   HTTPS check: %s   Added: %s\n' \
    "$FQDN" "$SERVICE" "$ROUTE_RECORD_ID" "$HTTP_CODE" "$(date -Iseconds)" >> "$RECORD"
fi

log "Done: https://$FQDN/ -> $SERVICE ($HTTP_CODE)"
