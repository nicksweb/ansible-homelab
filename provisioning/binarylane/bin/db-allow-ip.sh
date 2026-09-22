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
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
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

log "Re-applying mysql_standalone (via Ansible) on $NAME with the full allow-list..."
MYSQL_VARS="$(jq -n --arg ips "$MERGED_CSV" '{mysql_standalone_allowed_ips:$ips}')"
ansible_run_playbook "playbooks/provisioning/mysql_standalone.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$MYSQL_VARS" \
  || die "mysql_standalone Ansible role failed on $NAME"
unset MYSQL_VARS

if $WANT_PMA || [ "$PMA_ENABLED" = "true" ]; then
  log "Applying phpmyadmin (via Ansible) on $NAME with the full allow-list..."
  PMA_VARS="$(jq -n --arg ips "$MERGED_CSV" '{phpmyadmin_allowed_ips:$ips}')"
  ansible_run_playbook "playbooks/provisioning/phpmyadmin.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$PMA_VARS" \
    || die "phpmyadmin Ansible role failed on $NAME"
  unset PMA_VARS
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
