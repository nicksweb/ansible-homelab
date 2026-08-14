#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER (copied over and executed via ssh+sudo by
# scripts/install-cloudflare-tunnel.sh). Installs cloudflared and configures
# it as a dedicated, locally-managed tunnel connector — mirrors the exact
# working pattern already proven elsewhere in this toolkit:
# systemd unit runs `cloudflared tunnel run --token-file /etc/cloudflared/token`
# plus `--config /etc/cloudflared/config.yml` via an override, token file mode 600.
#
# Usage: install-cloudflared-remote.sh <tunnel_id> <hostname>
# The connector token is read from stdin — never passed as an argument or
# written to shell history, and never touches the control host's disk (piped straight
# through the SSH channel by the caller).
set -euo pipefail

TUNNEL_ID="${1:?usage: install-cloudflared-remote.sh <tunnel_id> <hostname>  (token via stdin)}"
HOSTNAME_FQDN="${2:?usage: install-cloudflared-remote.sh <tunnel_id> <hostname>  (token via stdin)}"

log() { echo "[cloudflared-remote] $*"; }

TOKEN="$(cat -)"
[ -n "$TOKEN" ] || { echo "No token received on stdin" >&2; exit 1; }

if ! command -v cloudflared >/dev/null 2>&1; then
  log "Installing cloudflared from pkg.cloudflare.com"
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq cloudflared >/dev/null
fi

log "Writing connector token to /etc/cloudflared/token (mode 600, root-only)"
sudo mkdir -p /etc/cloudflared
printf '%s' "$TOKEN" | sudo tee /etc/cloudflared/token >/dev/null
sudo chmod 600 /etc/cloudflared/token
sudo chown root:root /etc/cloudflared/token
unset TOKEN

log "Writing ingress config for $HOSTNAME_FQDN -> http://localhost:80"
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: ${TUNNEL_ID}
ingress:
  - hostname: ${HOSTNAME_FQDN}
    service: http://localhost:80
  - service: http_status:404
EOF

log "Installing systemd service (token-file + config, matching the same pattern)"
sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<'EOF'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared
sleep 2
STATUS="$(systemctl is-active cloudflared)"
log "cloudflared status: $STATUS"
[ "$STATUS" = "active" ] || { echo "cloudflared failed to start" >&2; exit 1; }
