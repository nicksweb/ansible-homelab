#!/usr/bin/env bash
# Runs ON THE REMOTE HOST via ssh+sudo. Installs Tailscale via the official
# installer and joins the tailnet using a pre-authorized, tagged authkey.
#
# Usage: install-tailscale.sh <hostname>   (authkey via stdin)
# The authkey is read from stdin — never passed as an argument (would leak
# via `ps`) or written to shell history, same discipline as this toolkit's
# other secret-handling scripts (see install-beszel-agent.sh upstream in
# the Proxmox toolkit). It's written briefly to a mode-600 root-only file
# so `tailscale up --authkey=file:...` can read it without it ever
# appearing in `ps aux` output, then shredded immediately after use.
set -euo pipefail

TS_HOSTNAME="${1:?usage: install-tailscale.sh <hostname>  (authkey via stdin)}"

log() { echo "[tailscale] $*"; }

AUTHKEY="$(cat -)"
[ -n "$AUTHKEY" ] || { echo "No authkey received on stdin" >&2; exit 1; }

log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sudo sh

KEYFILE="$(sudo mktemp /root/.tailscale-authkey.XXXXXX)"
sudo chmod 600 "$KEYFILE"
printf '%s' "$AUTHKEY" | sudo tee "$KEYFILE" >/dev/null
unset AUTHKEY

log "Joining tailnet as '$TS_HOSTNAME'..."
sudo tailscale up --authkey="file:$KEYFILE" --hostname="$TS_HOSTNAME" --ssh --accept-dns=false
sudo shred -u "$KEYFILE" 2>/dev/null || sudo rm -f "$KEYFILE"

log "Verifying tailnet connectivity..."
CONNECTED=false
for i in $(seq 1 10); do
  if sudo tailscale status --json 2>/dev/null | grep -q '"Online": *true' || sudo tailscale ip -4 >/dev/null 2>&1; then
    CONNECTED=true; break
  fi
  sleep 2
done
if $CONNECTED; then
  TS_IP="$(sudo tailscale ip -4 2>/dev/null || echo unknown)"
  log "Confirmed: Tailscale up, IP $TS_IP"
else
  echo "Tailscale did not confirm connectivity within 20s — check 'tailscale status' on the server." >&2
  exit 1
fi
