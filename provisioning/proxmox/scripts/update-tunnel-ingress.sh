#!/usr/bin/env bash
# Runs ON THE REMOTE CONTAINER via ssh+sudo, orchestrated by bin/add-vhost.sh
# for a container that already has cloudflared installed and running (from
# an earlier provision-container.sh --public-hostname run). Rewrites
# /etc/cloudflared/config.yml from a full, caller-supplied list of hostnames
# and reloads the service — deliberately NOT incremental/sed-based editing
# of the existing file, since the caller (add-vhost.sh) already knows the
# complete desired hostname list from local state and a "compute full
# desired state, write it" rewrite can't drift out of sync the way patching
# an existing file could. All hostnames route to the same local Apache
# (http://localhost:80) — Apache's own per-hostname vhosts (see
# install-test-vhost.sh) are what actually differentiate the content served
# per hostname, not cloudflared.
#
# Usage: update-tunnel-ingress.sh <tunnel_id> <hostname> [hostname ...]
set -euo pipefail

TUNNEL_ID="${1:?usage: update-tunnel-ingress.sh <tunnel_id> <hostname> [hostname ...]}"
shift
HOSTNAMES=("$@")
[ "${#HOSTNAMES[@]}" -ge 1 ] || { echo "at least one hostname is required" >&2; exit 1; }

log() { echo "[tunnel-ingress] $*"; }

log "Writing ingress config for: ${HOSTNAMES[*]} -> http://localhost:80"
{
  echo "tunnel: ${TUNNEL_ID}"
  echo "ingress:"
  for h in "${HOSTNAMES[@]}"; do
    echo "  - hostname: ${h}"
    echo "    service: http://localhost:80"
  done
  echo "  - service: http_status:404"
} | sudo tee /etc/cloudflared/config.yml >/dev/null

sudo cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
sudo systemctl reload cloudflared 2>/dev/null || sudo systemctl restart cloudflared
sleep 2
STATUS="$(systemctl is-active cloudflared || true)"
log "cloudflared status: $STATUS"
[ "$STATUS" = "active" ] || { echo "cloudflared failed to come back up after config update" >&2; exit 1; }
