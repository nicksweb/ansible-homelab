#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER via ssh+sudo, orchestrated by bin/provision-server.sh
# for --db-only servers. Installs the same MySQL 8.x package install-lamp.sh
# uses, but standalone (no Apache/PHP) and bound for external reachability —
# restricted at the firewall (ufw) to only the specified client IP(s), never
# the whole internet. Idempotent — safe to re-run.
#
# Usage: install-mysql-standalone.sh <allowed_ips_csv> [db_name] [db_user]
#   allowed_ips_csv: comma-separated IPv4 addresses/CIDRs permitted to reach
#     port 3306 via ufw — typically the app server's own public IP.
# Root + app-user passwords are generated on first run and stored at
# /etc/mysql-provisioning-credentials.env (mode 600, root-only) on this
# server — never written to the control host's disk by this script. The orchestrator
# displays them once via a separate `cat` over SSH after this script exits.
set -euo pipefail

ALLOWED_IPS_CSV="${1:?usage: install-mysql-standalone.sh <allowed_ips_csv> [db_name] [db_user]}"
DB_NAME="${2:-appdb}"
DB_USER="${3:-appuser}"

log() { echo "[mysql-standalone] $*"; }

export DEBIAN_FRONTEND=noninteractive

log "apt update"
sudo apt-get update -qq

log "installing MySQL server (matches the reference server's MySQL 8.x, not MariaDB)"
if ! command -v mysql >/dev/null 2>&1; then
  sudo apt-get install -y -qq mysql-server >/dev/null
fi

log "binding mysqld to all interfaces — external reachability is actually gated by the ufw rules below, not by this alone"
MYSQL_CNF=/etc/mysql/mysql.conf.d/mysqld.cnf
if [ -f "$MYSQL_CNF" ] && ! grep -q '^bind-address\s*=\s*0\.0\.0\.0' "$MYSQL_CNF"; then
  sudo sed -i 's/^bind-address.*/bind-address\t\t= 0.0.0.0/' "$MYSQL_CNF" || \
    echo 'bind-address = 0.0.0.0' | sudo tee -a "$MYSQL_CNF" >/dev/null
fi
sudo systemctl enable --now mysql >/dev/null
sudo systemctl restart mysql

CRED_FILE=/etc/mysql-provisioning-credentials.env
if [ -f "$CRED_FILE" ]; then
  log "Existing credential file found — reusing (idempotent re-run)"
  # File is mode 600 root:root — read it via sudo rather than sourcing
  # directly, which fails for the unprivileged SSH user with "Permission
  # denied" (only caught by actually re-running this script against a live
  # server, since the first-ever run always takes the fresh-install branch
  # below and never needs to read it back).
  MYSQL_ROOT_PASSWORD="$(sudo sed -n 's/^MYSQL_ROOT_PASSWORD=//p' "$CRED_FILE")"
  MYSQL_APP_PASSWORD="$(sudo sed -n 's/^MYSQL_APP_PASSWORD=//p' "$CRED_FILE")"
  DB_NAME="$(sudo sed -n 's/^DB_NAME=//p' "$CRED_FILE")"
  DB_USER="$(sudo sed -n 's/^DB_USER=//p' "$CRED_FILE")"
  ROOT_CMD=(sudo env "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" mysql -uroot)
else
  log "Generating new root + app credentials (first run)"
  MYSQL_ROOT_PASSWORD="$(openssl rand -base64 24)"
  MYSQL_APP_PASSWORD="$(openssl rand -base64 24)"
  # Fresh install still has root@localhost on auth_socket, so a plain
  # `sudo mysql` works passwordless here — the only point in this script
  # that relies on that; everything after uses the password just set.
  sudo mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';
SQL
  sudo tee "$CRED_FILE" >/dev/null <<EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_APP_PASSWORD=${MYSQL_APP_PASSWORD}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
EOF
  sudo chmod 600 "$CRED_FILE"
  sudo chown root:root "$CRED_FILE"
  ROOT_CMD=(sudo env "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" mysql -uroot)
fi

log "Creating database '${DB_NAME}' if needed"
"${ROOT_CMD[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

log "Creating app user '${DB_USER}', scoped to the allowed client IP(s): ${ALLOWED_IPS_CSV}"
IFS=',' read -ra IP_ARR <<< "$ALLOWED_IPS_CSV"
for ip in "${IP_ARR[@]}"; do
  ip="$(echo "$ip" | xargs)"
  [ -n "$ip" ] || continue
  "${ROOT_CMD[@]}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${ip}' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_APP_PASSWORD}'; GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${ip}';"
  log "Allowing MySQL (3306/tcp) from ${ip} via ufw"
  sudo ufw allow from "$ip" to any port 3306 proto tcp comment 'db-only: app server access' >/dev/null
done
"${ROOT_CMD[@]}" -e "FLUSH PRIVILEGES;"

unset MYSQL_ROOT_PASSWORD MYSQL_APP_PASSWORD

log "mysql-standalone install complete"
echo "DB_NAME=${DB_NAME}"
echo "DB_USER=${DB_USER}"
echo "MYSQL_VERSION=$(mysql --version)"
