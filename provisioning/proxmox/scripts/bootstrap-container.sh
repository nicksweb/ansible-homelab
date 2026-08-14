#!/usr/bin/env bash
# Runs ON THE REMOTE LXC CONTAINER via ssh (as root — the only account the
# stock Proxmox Ubuntu LXC template has), orchestrated by
# bin/provision-container.sh. Baseline OS setup + creates the admin user,
# since these templates ship with root only, unlike cloud-init VM images.
# Idempotent — safe to re-run.
#
# Usage: bootstrap-container.sh <fqdn> <timezone> <admin_user> <ssh_public_key>
set -euo pipefail

FQDN="${1:?usage: bootstrap-container.sh <fqdn> <timezone> <admin_user> <ssh_public_key>}"
TZ_NAME="${2:?usage: bootstrap-container.sh <fqdn> <timezone> <admin_user> <ssh_public_key>}"
ADMIN_USER="${3:?usage: bootstrap-container.sh <fqdn> <timezone> <admin_user> <ssh_public_key>}"
SSH_PUBLIC_KEY="${4:?usage: bootstrap-container.sh <fqdn> <timezone> <admin_user> <ssh_public_key>}"

log() { echo "[bootstrap] $*"; }

export DEBIAN_FRONTEND=noninteractive

log "creating admin user $ADMIN_USER (this template ships with root only)"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
  chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
  passwd -l "$ADMIN_USER" >/dev/null
fi
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
grep -qxF "$SSH_PUBLIC_KEY" "/home/$ADMIN_USER/.ssh/authorized_keys" 2>/dev/null || \
  echo "$SSH_PUBLIC_KEY" >> "/home/$ADMIN_USER/.ssh/authorized_keys"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"

log "apt update + upgrade"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

log "installing base packages"
sudo apt-get install -y -qq \
  curl wget git ca-certificates gnupg lsb-release \
  unattended-upgrades jq ufw \
  htop bwm-ng vnstat

log "timezone -> $TZ_NAME"
sudo timedatectl set-timezone "$TZ_NAME" 2>/dev/null || sudo ln -fs "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime

log "hostname -> $FQDN"
sudo hostnamectl set-hostname "$FQDN"
grep -q "$FQDN" /etc/hosts || echo "127.0.1.1 $FQDN ${FQDN%%.*}" | sudo tee -a /etc/hosts >/dev/null

log "unattended-upgrades"
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

log "basic firewall (SSH only for now — HTTP/HTTPS added when a site is configured)"
sudo ufw allow OpenSSH >/dev/null
sudo ufw --force enable >/dev/null

log "bootstrap complete"
echo "UBUNTU_VERSION=$(lsb_release -rs)"
