#!/usr/bin/env bash
# Runs on the control host. Creates (or reuses) a dedicated, locally-managed
# Cloudflare Tunnel for one server/container, installs cloudflared on it via
# the cloudflared_connector Ansible role (its own connector token only,
# never the control host's broader API credential), and points the public
# hostname at it via a proxied CNAME.
#
# Shared by both toolkits (previously two separate, near-identical copies —
# provisioning/binarylane/scripts/install-cloudflare-tunnel.sh and
# provisioning/proxmox/scripts/install-cloudflare-tunnel.sh — collapsed into
# this one). Fully self-contained: sources its own logging/cloudflare/ansible
# helpers and computes its own credential file path, since it runs as a
# separate process (command substitution) and can't inherit the calling
# toolkit's shell functions or unexported variables.
#
# Usage: install-cloudflare-tunnel.sh <name> <public_hostname> <target_ip> <ssh_user> <ssh_key> [connector]
#   connector: "systemd" (default) — cloudflared as a host service routing to
#              localhost:80 (cloudflared_connector role); or "docker" —
#              cloudflared as a container routing to the `web` container
#              (docker_cloudflared role), for BinaryLane --role docker servers.
# Idempotent: re-running for the same <name> reuses the existing tunnel.
set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Invoked as a separate process (command substitution from the calling
# orchestrator), not sourced — none of the caller's shell functions
# (log/warn/die) or unexported variables cross that boundary, so this
# script must establish its own, exactly like every other standalone
# script under provisioning/ does via its toolkit's lib/common.sh.
# shellcheck disable=SC1091
source "$COMMON_DIR/logging.sh"
# shellcheck disable=SC1091
source "$COMMON_DIR/cloudflare.sh"
# shellcheck disable=SC1091
source "$COMMON_DIR/ansible.sh"

NAME="${1:?usage: install-cloudflare-tunnel.sh <name> <public_hostname> <target_ip> <ssh_user> <ssh_key>}"
PUBLIC_HOSTNAME="${2:?}"
TARGET_IP="${3:?}"
SSH_USER="${4:?}"
SSH_KEY="${5:?}"
CONNECTOR="${6:-systemd}"
case "$CONNECTOR" in systemd|docker) ;; *) die "connector must be 'systemd' or 'docker', got '$CONNECTOR'" ;; esac

# Self-contained credential loading — deliberately not relying on either
# toolkit's own differently-named loader (binarylane: load_cloudflare_creds;
# proxmox: load_cloudflare_token) OR on inheriting the caller's own
# unexported $API_AUTH_FILE (this script runs as a separate process via
# command substitution, so plain shell variables from the caller don't
# cross that boundary — only exported ones would, and this isn't). Computed
# the same way common/ansible.sh computes $ANSIBLE_REPO_ROOT: deterministic
# from this script's own location, not inherited.
: "${API_AUTH_FILE:="$ANSIBLE_REPO_ROOT/.api-auth.env"}"
[ -f "$API_AUTH_FILE" ] || die "Credential file not found: $API_AUTH_FILE"
CF_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$API_AUTH_FILE" | head -n1)"
[ -n "$CF_API_TOKEN" ] || die "Could not parse CLOUDFLARE_API_TOKEN from $API_AUTH_FILE"
CF_ACCOUNT_ID="$(sed -n 's/^CLOUDFLARE_ACCOUNT_ID=//p' "$API_AUTH_FILE" | head -n1)"
[ -n "$CF_ACCOUNT_ID" ] || die "Could not parse CLOUDFLARE_ACCOUNT_ID from $API_AUTH_FILE (non-secret — from the Cloudflare dashboard or GET /accounts)"
export CF_API_TOKEN CF_ACCOUNT_ID

HOSTNAME_ZONE_ID="$(resolve_zone_id_for_hostname "$PUBLIC_HOSTNAME")"
TUNNEL_NAME="${NAME}-tunnel"

log "Looking for existing tunnel named '$TUNNEL_NAME'..."
TUNNEL_ID="$(create_or_reuse_tunnel "$TUNNEL_NAME")"
log "Tunnel: $TUNNEL_ID"

log "Fetching connector token for tunnel $TUNNEL_ID"
CONNECTOR_TOKEN="$(fetch_tunnel_token "$TUNNEL_ID")"

log "Installing cloudflared on $TARGET_IP for hostname $PUBLIC_HOSTNAME via Ansible (token passed as a one-shot extra-vars file, never on disk beyond this run, never logged)"
if [ "$CONNECTOR" = "docker" ]; then
  CONNECTOR_PLAYBOOK="playbooks/provisioning/docker_cloudflared.yml"
  EXTRA_VARS="$(jq -n --arg tid "$TUNNEL_ID" --arg host "$PUBLIC_HOSTNAME" --arg token "$CONNECTOR_TOKEN" \
    '{docker_cloudflared_tunnel_id:$tid, docker_cloudflared_token:$token, docker_cloudflared_routes:[{hostname:$host, service:"http://web:80"}]}')"
else
  CONNECTOR_PLAYBOOK="playbooks/provisioning/cloudflared_connector.yml"
  EXTRA_VARS="$(jq -n --arg tid "$TUNNEL_ID" --arg host "$PUBLIC_HOSTNAME" --arg token "$CONNECTOR_TOKEN" \
    '{cloudflared_connector_tunnel_id:$tid, cloudflared_connector_hostname:$host, cloudflared_connector_token:$token}')"
fi
unset CONNECTOR_TOKEN
ansible_run_playbook "$CONNECTOR_PLAYBOOK" "$TARGET_IP" "$SSH_USER" "$SSH_KEY" "$EXTRA_VARS" \
  || die "$CONNECTOR_PLAYBOOK failed"
unset EXTRA_VARS
log "cloudflared installed and running."

log "Creating/updating proxied CNAME $PUBLIC_HOSTNAME -> ${TUNNEL_ID}.cfargotunnel.com (zone $HOSTNAME_ZONE_ID)"
RECORD_ID="$(create_or_update_cname "$PUBLIC_HOSTNAME" "$HOSTNAME_ZONE_ID" "${TUNNEL_ID}.cfargotunnel.com")"
log "CNAME record id: $RECORD_ID"

log "Checking tunnel health..."
HEALTHY=false
for i in $(seq 1 12); do
  # `|| echo error` matters here: under `set -e`, a plain assignment from a
  # failing command substitution aborts the whole script immediately.
  # Without this, one transient Cloudflare API hiccup during polling would
  # silently kill the entire provisioning run instead of just retrying.
  STATUS="$(tunnel_health "$TUNNEL_ID" || echo "error")"
  [ "$STATUS" = "healthy" ] && { HEALTHY=true; break; }
  sleep 5
done
$HEALTHY && log "Tunnel healthy." || warn "Tunnel not confirmed healthy within 60s (status: ${STATUS:-unknown})"

echo "CLOUDFLARE_TUNNEL_ID=$TUNNEL_ID"
echo "CLOUDFLARE_TUNNEL_RECORD_ID=$RECORD_ID"
echo "CLOUDFLARE_TUNNEL_ZONE_ID=$HOSTNAME_ZONE_ID"
echo "CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID"
