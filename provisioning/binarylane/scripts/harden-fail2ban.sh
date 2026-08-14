#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER via ssh+sudo, orchestrated by bin/provision-server.sh.
# Stage 2 of 2 (see harden-ssh.sh) — fail2ban only, run and externally
# verified as its own separate step. Pins banaction to the long-stable
# iptables-multiport rather than whatever Ubuntu 24.04 ships as the fail2ban
# default, since a fresh ufw-enabled 24.04 box + fail2ban's newer nftables
# action is a plausible source of exactly the kind of self-lockout this
# staging is designed to catch early. Idempotent — safe to re-run.
#
# Usage: harden-fail2ban.sh [management_ip]
set -euo pipefail

MANAGEMENT_IP="${1:-}"

log() { echo "[harden-fail2ban] $*"; }

JAIL_LOCAL=/etc/fail2ban/jail.local
IGNOREIP="127.0.0.1/8 ::1"
[ -n "$MANAGEMENT_IP" ] && IGNOREIP="$IGNOREIP $MANAGEMENT_IP"

log "Writing $JAIL_LOCAL (banaction=iptables-multiport, ignoreip includes management IP)"
sudo tee "$JAIL_LOCAL" >/dev/null <<EOF
[DEFAULT]
banaction = iptables-multiport
ignoreip = ${IGNOREIP}

[sshd]
enabled = true
EOF

sudo systemctl enable --now fail2ban >/dev/null
sudo systemctl restart fail2ban
sleep 2
STATUS="$(systemctl is-active fail2ban)"
log "fail2ban: $STATUS"
[ "$STATUS" = "active" ] || { echo "fail2ban failed to start" >&2; exit 1; }

sudo systemctl enable --now unattended-upgrades >/dev/null
log "unattended-upgrades: $(systemctl is-active unattended-upgrades)"

log "fail2ban stage complete"
