#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER via ssh+sudo, orchestrated by bin/provision-server.sh.
# Stage 1 of 2 (see also harden-fail2ban.sh): sshd config + ufw only. Split
# into its own stage, verified externally by the orchestrator before
# harden-fail2ban.sh ever runs, so if a firewall change locks SSH out, it's
# caught immediately after this one change rather than after several
# entangled ones. Idempotent — safe to re-run.
#
# Usage: harden-ssh.sh [management_ip]
#   management_ip: optional — an address (typically the control host's own, resolved from
#   manage.example.com by the caller) that gets an explicit ufw allow rule
#   for port 22, in addition to the general OpenSSH allow-from-anywhere rule.
set -euo pipefail

MANAGEMENT_IP="${1:-}"

log() { echo "[harden-ssh] $*"; }

# --- SSH hardening -----------------------------------------------------
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-provisioning-hardening.conf
if [ ! -f "$SSHD_DROPIN" ]; then
  log "Writing $SSHD_DROPIN"
  sudo tee "$SSHD_DROPIN" >/dev/null <<'EOF'
# Managed by server-provisioning toolkit. Key-only auth, no root login.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
EOF
  sudo sshd -t
  sudo systemctl reload ssh
else
  log "$SSHD_DROPIN already present, leaving as-is"
fi

# --- Firewall (idempotent re-assert; cloud-init already enabled ufw) ---
if [ -n "$MANAGEMENT_IP" ]; then
  log "Explicitly allowing SSH from management IP $MANAGEMENT_IP"
  sudo ufw allow from "$MANAGEMENT_IP" to any port 22 proto tcp comment 'provisioning management IP' >/dev/null
fi
sudo ufw allow OpenSSH >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null
log "ufw status: $(sudo ufw status | head -1)"
sudo ufw status numbered

log "SSH + firewall stage complete"
