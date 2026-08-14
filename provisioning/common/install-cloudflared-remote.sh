#!/usr/bin/env bash
# Runs ON THE REMOTE HOST (VM or LXC container — this only needs sudo, apt,
# and systemd, so it's identical either way), copied over and executed via
# ssh by a backend's install-cloudflare-tunnel.sh. Installs cloudflared and
# configures it as a dedicated, locally-managed tunnel connector — mirrors
# the standard cloudflared systemd pattern: the unit runs
# `cloudflared tunnel run --token-file /etc/cloudflared/token` plus
# `--config /etc/cloudflared/config.yml`, token file mode 600.
#
# Usage: install-cloudflared-remote.sh <tunnel_id> <hostname>
# The connector token is read from stdin — never passed as an argument or
# written to shell history, and never touches the orchestrating host's disk
# (piped straight through the SSH channel by the caller).
set -euo pipefail

TUNNEL_ID="${1:?usage: install-cloudflared-remote.sh <tunnel_id> <hostname>  (token via stdin)}"
HOSTNAME_FQDN="${2:?usage: install-cloudflared-remote.sh <tunnel_id> <hostname>  (token via stdin)}"

log() { echo "[cloudflared-remote] $*"; }

TOKEN="$(cat -)"
[ -n "$TOKEN" ] || { echo "No token received on stdin" >&2; exit 1; }

if ! command -v cloudflared >/dev/null 2>&1; then
  # Direct .deb download rather than pkg.cloudflare.com's apt repo: that repo
  # is keyed by Ubuntu codename and lags behind new releases (confirmed via
  # testing — Ubuntu 26.04 "resolute" has no Release file there yet). The
  # GitHub release .deb isn't tied to a codename at all, so it isn't affected
  # by this class of lag.
  log "Installing cloudflared from GitHub releases (codename-independent)"
  ARCH="$(dpkg --print-architecture)"
  TMP_DEB="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$TMP_DEB" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
  sudo dpkg -i "$TMP_DEB" || sudo apt-get install -y -qq -f
  rm -f "$TMP_DEB"
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
TimeoutStartSec=60
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

# cloudflared's own startup (QUIC handshake + edge registration + Cloudflare
# connectivity prechecks) can genuinely take longer than a couple of
# seconds, especially on a freshly booted container — confirmed directly:
# a single `sleep 2` here caught a container's cloudflared mid-startup,
# reported it as failed, and killed the whole provisioning run, even though
# systemd's own Restart=on-failure quietly brought it up successfully a few
# seconds later (systemctl status showed it "active (running)" and fully
# connected less than a minute after the reported failure). Poll instead of
# a single fixed-delay check.
STATUS="unknown"
for i in $(seq 1 15); do
  STATUS="$(systemctl is-active cloudflared || true)"
  [ "$STATUS" = "active" ] && break
  sleep 2
done
log "cloudflared status: $STATUS"
[ "$STATUS" = "active" ] || { echo "cloudflared did not reach active status within 30s — check 'systemctl status cloudflared' and 'journalctl -u cloudflared' on the container" >&2; exit 1; }
