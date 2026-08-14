#!/usr/bin/env bash
# Deploy the Docker Compose MariaDB + phpMyAdmin + Traefik stack (fronted by
# a native nginx doing TLS termination) onto an already-provisioned
# container. See scripts/install-mariadb-stack.sh for the architecture and
# the DOCKER-USER firewall rationale.
#
# Usage: deploy-mariadb-stack.sh <hostname> [--dry-run] [--yes]
#   <hostname>  an existing container's short name (e.g. db01) — must
#               already exist in local state, with --enable-tls already run
#               (this stack needs the internal FQDN's cert to already exist)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: deploy-mariadb-stack.sh <hostname> [--dry-run] [--yes]}"
shift
DRY_RUN=false ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

state_exists "$NAME" || die "No local state for '$NAME' — run provision-container.sh first."
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is marked DESTROYED."

FQDN="$(state_read_field "$NAME" '.fqdn')"
CONTAINER_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
[ -n "$CONTAINER_IP" ] || die "No IP recorded for '$NAME' in local state."
TLS_ENABLED="$(state_read_field "$NAME" '.tls_enabled // false')"
[ "$TLS_ENABLED" = "true" ] || die "'$NAME' has no TLS certificate on record. This stack needs one — re-provision (or add one) with --enable-tls first."

cat <<PLAN

============================================================
Deploy MariaDB + phpMyAdmin + Traefik Stack
============================================================
Container:      $NAME ($FQDN, $CONTAINER_IP)
Access:         https://$FQDN/  (phpMyAdmin, via nginx -> Traefik)
MariaDB:        ${CONTAINER_IP}:3306, restricted to 172.16.0.0/16 via DOCKER-USER firewall rule
Location:       ~/docker/mariadb-stack/ on the container
Credentials:    generated on the container, shown once at the end — not stored on the control host
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

log "Installing Docker (skips cleanly if already installed)..."
scp "${SSH_OPTS[@]}" "$HERE/scripts/install-docker.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-docker.sh"
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
  "chmod +x /tmp/install-docker.sh && /tmp/install-docker.sh && rm -f /tmp/install-docker.sh" \
  || die "Docker installation failed"

log "Deploying the stack..."
scp "${SSH_OPTS[@]}" "$HERE/scripts/install-mariadb-stack.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-mariadb-stack.sh"
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
  "chmod +x /tmp/install-mariadb-stack.sh && /tmp/install-mariadb-stack.sh '$FQDN' && rm -f /tmp/install-mariadb-stack.sh" \
  || die "Stack deployment failed"

log "Verifying HTTPS access to phpMyAdmin..."
HTTP_OK=false
for i in $(seq 1 12); do
  CODE="$(curl -s --resolve "$FQDN:443:$CONTAINER_IP" -o /dev/null -w '%{http_code}' "https://$FQDN/" || echo 000)"
  [ "$CODE" = "200" ] && { HTTP_OK=true; break; }
  sleep 5
done
$HTTP_OK && log "phpMyAdmin reachable over HTTPS (verified with a real request, not assumed)." \
         || warn "Could not confirm HTTPS access yet (last HTTP code: $CODE) — check 'docker compose logs' on the container."

log "Verifying the firewall rule is actually in place..."
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
  "sudo iptables -L DOCKER-USER -n --line-numbers | grep -E '3306|DOCKER-USER'" || warn "Could not confirm the DOCKER-USER firewall rule — check manually."

log "Retrieving generated credentials (shown once below, never written to the control host's disk)..."
CREDS="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" 'grep -E "^MYSQL_" ~/docker/mariadb-stack/.env')"

# Non-secret record only — matches the no-secrets rule used for every other
# provisioning record in this toolkit.
NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq --arg updated "$NOW" '.updated_at = $updated | .services = ((.services // []) | map(select(. != "mariadb-stack")) + ["mariadb-stack"])' "$(state_file "$NAME")")"

RECORD="$(record_file "$NAME")"
{
  echo
  echo "------------------------------------------------------------"
  echo "Service Deployed: mariadb-stack ($NOW)"
  echo "------------------------------------------------------------"
  echo "phpMyAdmin:"; echo "https://$FQDN/"
  echo "MariaDB:"; echo "$CONTAINER_IP:3306 (restricted to 172.16.0.0/16 via DOCKER-USER firewall rule)"
  echo "Stack location:"; echo "~/docker/mariadb-stack/ on the container"
  echo "Credentials:"; echo "Not recorded here — see .env on the container (mode 600) or the one-time terminal output when this was deployed"
} >> "$RECORD"
chmod 600 "$RECORD"

cat <<SUMMARY

============================================================
MariaDB Stack Deployed
============================================================
phpMyAdmin:   https://$FQDN/
MariaDB:      $CONTAINER_IP:3306 (only reachable from 172.16.0.0/16)

Credentials (shown once — also saved in ~/docker/mariadb-stack/.env on the
container itself, mode 600, readable only by localadmin):
$CREDS

Provisioning record: $RECORD
============================================================
SUMMARY
