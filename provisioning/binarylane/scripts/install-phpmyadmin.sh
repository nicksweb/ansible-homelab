#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER via ssh+sudo, orchestrated by bin/db-allow-ip.sh
# (or bin/provision-server.sh, if ever wired in there directly) for
# --db-only servers where phpMyAdmin access was explicitly requested — NOT
# part of --db-only by default, a bare db-only server stays MySQL-only with
# no web server at all. Installs Apache + phpMyAdmin (Ubuntu's own package,
# dbconfig-common disabled — phpMyAdmin here is just the admin UI for the
# MySQL this box already runs; it never gets its own database). Idempotent —
# safe to re-run, e.g. to expand the allowed IP list later.
#
# Usage: install-phpmyadmin.sh <allowed_ips_csv>
#   allowed_ips_csv: comma-separated IPv4 addresses/CIDRs allowed through
#     ufw on 80/tcp and 443/tcp. install-mysql-standalone.sh already scopes
#     port 3306 the same way — this locks the *web* ports down just as
#     tightly, since a from-anywhere-reachable DB admin GUI would defeat
#     that. Whichever ufw rule harden-ssh.sh left behind for 80/443
#     ("Anywhere", since it doesn't know at provisioning time whether a web
#     GUI will ever be added to a db-only server) is removed and replaced
#     with IP-scoped rules.
set -euo pipefail

ALLOWED_IPS_CSV="${1:?usage: install-phpmyadmin.sh <allowed_ips_csv>}"

log() { echo "[phpmyadmin] $*"; }

export DEBIAN_FRONTEND=noninteractive

if ! command -v apache2 >/dev/null 2>&1; then
  log "installing Apache"
  sudo apt-get update -qq
  sudo apt-get install -y -qq apache2 >/dev/null
  sudo a2dissite 000-default -q 2>/dev/null || true
fi

if [ ! -d /usr/share/phpmyadmin ]; then
  log "installing phpMyAdmin (dbconfig-common disabled — it only talks to the MySQL already on this box, never gets its own database)"
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | sudo debconf-set-selections
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | sudo debconf-set-selections
  sudo apt-get install -y -qq phpmyadmin libapache2-mod-php php-mbstring php-zip php-curl >/dev/null
fi
sudo a2enmod -q php8.3 >/dev/null 2>&1 || sudo a2enmod -q php >/dev/null 2>&1 || true

# Full known-good config rather than patching whatever the package's
# postinst generated — connects via the local Unix socket (not TCP), which
# makes MySQL see the login as coming from 'localhost', matching the
# 'root'@'localhost' grant install-mysql-standalone.sh already put a real
# password on. No extra MySQL grant needed just for the admin GUI to work —
# log into phpMyAdmin as 'root' with the password from
# /etc/mysql-provisioning-credentials.env.
if [ ! -f /etc/phpmyadmin/config.inc.php ] || ! grep -q "blowfish_secret" /etc/phpmyadmin/config.inc.php 2>/dev/null; then
  log "Writing /etc/phpmyadmin/config.inc.php"
  BLOWFISH_SECRET="$(openssl rand -hex 16)"
  sudo tee /etc/phpmyadmin/config.inc.php >/dev/null <<EOF
<?php
\$cfg['blowfish_secret'] = '${BLOWFISH_SECRET}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['socket'] = '/var/run/mysqld/mysqld.sock';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
EOF
fi

if [ -f /etc/phpmyadmin/apache.conf ]; then
  sudo ln -sf /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
  sudo a2enconf -q phpmyadmin >/dev/null || true
fi

log "Locking ufw 80/443 down to only the allowed IP(s): $ALLOWED_IPS_CSV (removing the from-anywhere rule initial hardening left, since a db-only server wasn't expected to run a web GUI at provisioning time)"
sudo ufw delete allow 80/tcp >/dev/null 2>&1 || true
sudo ufw delete allow 443/tcp >/dev/null 2>&1 || true
sudo ufw delete allow "80/tcp (v6)" >/dev/null 2>&1 || true
sudo ufw delete allow "443/tcp (v6)" >/dev/null 2>&1 || true

IFS=',' read -ra IP_ARR <<< "$ALLOWED_IPS_CSV"
for ip in "${IP_ARR[@]}"; do
  ip="$(echo "$ip" | xargs)"
  [ -n "$ip" ] || continue
  sudo ufw allow from "$ip" to any port 80 proto tcp comment 'phpmyadmin admin access' >/dev/null
  sudo ufw allow from "$ip" to any port 443 proto tcp comment 'phpmyadmin admin access' >/dev/null
done

sudo apache2ctl configtest
sudo systemctl enable --now apache2 >/dev/null
sudo systemctl reload apache2

log "phpMyAdmin install complete — restricted to: $ALLOWED_IPS_CSV"
echo "PHPMYADMIN_PATH=/phpmyadmin"
