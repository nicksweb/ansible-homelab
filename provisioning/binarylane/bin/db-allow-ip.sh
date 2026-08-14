#!/usr/bin/env bash
# Add IP(s) to an EXISTING --db-only server's allow-list — for MySQL (3306)
# always, and for phpMyAdmin (80/443) too if requested. provision-server.sh
# refuses to re-run against a server that already exists in local state (by
# design — it's a duplicate-creation safety check, not meant to be an
# incremental-update path), so widening access on a live db-only server goes
# through this script instead. Idempotent: re-running with the same IPs is a
# no-op; the existing (and any new) IPs are always re-passed in full to
# install-mysql-standalone.sh / install-phpmyadmin.sh, both of which are
# themselves idempotent per-IP.
#
# Usage: db-allow-ip.sh <name> <ip[,ip...]> [--phpmyadmin]
#   --phpmyadmin: also install (if not already present) and/or widen access
#     to phpMyAdmin on this server, restricted to the same final IP list.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: db-allow-ip.sh <name> <ip[,ip...]> [--phpmyadmin]}"
NEW_IPS_CSV="${2:?usage: db-allow-ip.sh <name> <ip[,ip...]> [--phpmyadmin]}"
WANT_PMA=false
[ "${3:-}" = "--phpmyadmin" ] && WANT_PMA=true

state_exists "$NAME" || die "No local state for '$NAME'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is marked DESTROYED in local state."
DB_ONLY="$(state_read_field "$NAME" '.mysql.db_only // false')"
[ "$DB_ONLY" = "true" ] || die "'$NAME' was not provisioned with --db-only — this script only manages access on standalone MySQL servers."

EXISTING_CSV="$(state_read_field "$NAME" '.mysql.allowed_from // empty')"
PMA_ENABLED="$(state_read_field "$NAME" '.mysql.phpmyadmin_enabled // false')"
PUBLIC_IP="$(state_read_field "$NAME" '.public_ipv4')"
FQDN="$(state_read_field "$NAME" '.fqdn')"

# Merge existing + new, dedup, preserve order.
MERGED_CSV="$(printf '%s,%s' "$EXISTING_CSV" "$NEW_IPS_CSV" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | awk 'NF && !seen[$0]++' | paste -sd, -)"

echo "============================================================"
echo "Widening access on: $NAME ($FQDN / $PUBLIC_IP)"
echo "============================================================"
echo "Currently allowed:  ${EXISTING_CSV:-<none>}"
echo "Adding:              $NEW_IPS_CSV"
echo "Final allow-list:    $MERGED_CSV"
echo "phpMyAdmin:           $( $WANT_PMA && echo "install/update, restricted to the final allow-list" || ( [ "$PMA_ENABLED" = "true" ] && echo "already enabled — its allow-list will be widened too" || echo "not requested, not touched" ) )"
echo "============================================================"

SSH_OPTS=(-i "$PROVISIONING_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MULTIPLEX_OPTS[@]}")

log "Re-running install-mysql-standalone.sh on $NAME with the full allow-list..."
scp "${SSH_OPTS[@]}" "$HERE/scripts/install-mysql-standalone.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/install-mysql-standalone.sh"
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/install-mysql-standalone.sh && /tmp/install-mysql-standalone.sh '$MERGED_CSV' && rm -f /tmp/install-mysql-standalone.sh" \
  || die "install-mysql-standalone.sh failed on $NAME"

if $WANT_PMA || [ "$PMA_ENABLED" = "true" ]; then
  log "Running install-phpmyadmin.sh on $NAME with the full allow-list..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-phpmyadmin.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/install-phpmyadmin.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/install-phpmyadmin.sh && /tmp/install-phpmyadmin.sh '$MERGED_CSV' && rm -f /tmp/install-phpmyadmin.sh" \
    || die "install-phpmyadmin.sh failed on $NAME"
  PMA_ENABLED=true
fi

NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq --arg allowed "$MERGED_CSV" --argjson pma "$PMA_ENABLED" --arg updated "$NOW" \
  '.mysql.allowed_from = $allowed | .mysql.phpmyadmin_enabled = $pma | .updated_at = $updated' \
  "$(state_file "$NAME")")"

RECORD="$(record_file "$NAME")"
if [ -f "$RECORD" ]; then
  {
    echo
    echo "------------------------------------------------------------"
    echo "Access widened: $(date -Iseconds)"
    echo "  Allow-list now: $MERGED_CSV"
    echo "  phpMyAdmin: $( $PMA_ENABLED && echo "enabled — http://${FQDN}/phpmyadmin (or http://${PUBLIC_IP}/phpmyadmin), login as 'root' with the password in /etc/mysql-provisioning-credentials.env on the server" || echo "not enabled" )"
  } >> "$RECORD"
  chmod 600 "$RECORD"
fi

log "Done. Allow-list for $NAME is now: $MERGED_CSV"
$PMA_ENABLED && log "phpMyAdmin: http://${PUBLIC_IP}/phpmyadmin (log in as 'root', password from /etc/mysql-provisioning-credentials.env on the server — TLS pending until ${FQDN} finishes DNS propagation)"
