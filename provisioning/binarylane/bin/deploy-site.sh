#!/usr/bin/env bash
# Push a prebuilt local directory to a static site already scaffolded on a
# --role docker server (via bin/add-static-site.sh). Deliberately dumb: does
# not build anything itself — build your own site first (e.g.
# `cd ~/src/my-site && bundle exec jekyll build`), then point this
# at the output directory. Keeps this script reusable across differently
# built repos without per-site build config.
#
# Usage: deploy-site.sh <server-name> <fqdn> <local-build-dir>
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

SERVER_NAME="${1:?usage: deploy-site.sh <server-name> <fqdn> <local-build-dir>}"
FQDN="${2:?}"
LOCAL_DIR="${3:?}"

state_exists "$SERVER_NAME" || die "No local state for server '$SERVER_NAME'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
STATUS="$(state_read_field "$SERVER_NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "Server '$SERVER_NAME' is marked DESTROYED in local state."

KNOWN_SITE="$(jq -r --arg f "$FQDN" '.docker.sites // [] | index($f)' "$(state_file "$SERVER_NAME")")"
[ -n "$KNOWN_SITE" ] && [ "$KNOWN_SITE" != "null" ] || die "'$FQDN' is not a site on '$SERVER_NAME' yet. Scaffold it first: ./bin/add-static-site.sh $SERVER_NAME <subdomain> <domain>"

[ -d "$LOCAL_DIR" ] || die "Local build dir '$LOCAL_DIR' does not exist"
[ -n "$(ls -A "$LOCAL_DIR" 2>/dev/null)" ] || die "Local build dir '$LOCAL_DIR' is empty — refusing to sync (would wipe the live site via --delete)"

PUBLIC_IP="$(state_read_field "$SERVER_NAME" '.public_ipv4')"
REMOTE_DIR="~/docker/web/sites/${FQDN}/"

log "Deploying $LOCAL_DIR -> $SERVER_NAME:$REMOTE_DIR"
RSYNC_STATS="$(rsync -az --delete --stats \
  -e "ssh -i $PROVISIONING_SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes ${SSH_MULTIPLEX_OPTS[*]}" \
  "${LOCAL_DIR%/}/" "$ADMIN_USER@$PUBLIC_IP:$REMOTE_DIR")" || die "rsync failed"
BYTES_SENT="$(echo "$RSYNC_STATS" | sed -n 's/^Total bytes sent: //p')"
log "Deploy complete ($BYTES_SENT bytes sent)"

log "Verifying HTTPS..."
sleep 2
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${FQDN}/" || true)"
log "HTTPS check: $HTTP_CODE"

NOW="$(date -Iseconds)"
RECORD="$(record_file "$SERVER_NAME")"
if [ -f "$RECORD" ]; then
  {
    echo
    echo "------------------------------------------------------------"
    echo "Deployed: $FQDN"
    echo "  From: $LOCAL_DIR   Bytes sent: ${BYTES_SENT:-unknown}   HTTPS check: $HTTP_CODE   Deployed: $NOW"
  } >> "$RECORD"
  chmod 600 "$RECORD"
fi

cat <<SUMMARY

============================================================
Deployed: $FQDN
============================================================
Server:      $SERVER_NAME
Source:      $LOCAL_DIR
Bytes sent:  ${BYTES_SENT:-unknown}
HTTPS Check: $HTTP_CODE
============================================================
SUMMARY
