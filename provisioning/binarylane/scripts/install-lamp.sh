#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER (copied over and executed via ssh+sudo by
# bin/provision-server.sh). Idempotent — safe to re-run. Installs the
# LAMP stack: Apache 2 + MySQL 8 + PHP 8.3 + Composer + Git. Does not copy
# any existing application data, vhosts, databases or secrets.
set -euo pipefail

log() { echo "[lamp] $*"; }

export DEBIAN_FRONTEND=noninteractive

log "apt update"
sudo apt-get update -qq

log "installing Apache"
sudo apt-get install -y -qq apache2 >/dev/null

log "enabling Apache modules used by the reference baseline"
sudo a2enmod -q rewrite headers ssl proxy proxy_fcgi env deflate expires >/dev/null || true
sudo mkdir -p /etc/apache2/vhosts.d
if ! grep -q 'IncludeOptional vhosts.d' /etc/apache2/apache2.conf; then
  echo 'IncludeOptional vhosts.d/*.conf' | sudo tee -a /etc/apache2/apache2.conf >/dev/null
fi
# Ubuntu's stock sites-enabled/000-default.conf loads before our appended
# vhosts.d include, so it wins as the default (no-ServerName) vhost unless
# disabled — matches the reference server's own convention of not using sites-enabled at all.
sudo a2dissite 000-default -q 2>/dev/null || true

SKIP_MYSQL="${2:-false}"
if [ "$SKIP_MYSQL" = "true" ]; then
  log "Skipping local MySQL install (--skip-mysql — this server expects to connect to a remote DB server)"
else
  log "installing MySQL server (matches the reference server's MySQL 8.x, not MariaDB)"
  if ! command -v mysql >/dev/null 2>&1; then
    sudo apt-get install -y -qq mysql-server >/dev/null
  fi
  # Bind to loopback only — never expose the database port publicly.
  MYSQL_CNF=/etc/mysql/mysql.conf.d/mysqld.cnf
  if [ -f "$MYSQL_CNF" ] && ! grep -q '^bind-address\s*=\s*127.0.0.1' "$MYSQL_CNF"; then
    sudo sed -i 's/^bind-address.*/bind-address\t\t= 127.0.0.1/' "$MYSQL_CNF" || \
      echo 'bind-address = 127.0.0.1' | sudo tee -a "$MYSQL_CNF" >/dev/null
    sudo systemctl restart mysql
  fi
fi

log "installing PHP 8.3 + extensions matching the reference module baseline"
sudo apt-get install -y -qq \
  php-cli php-fpm php-mysql php-curl php-mbstring php-xml \
  php-zip php-gd php-intl php-bcmath php-common >/dev/null

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
log "PHP version detected: $PHP_VER"
sudo a2enmod -q proxy_fcgi setenvif >/dev/null || true
sudo a2enconf -q "php${PHP_VER}-fpm" >/dev/null || true
sudo systemctl enable --now "php${PHP_VER}-fpm" >/dev/null

log "installing Composer"
if ! command -v composer >/dev/null 2>&1; then
  EXPECTED_SIG="$(curl -s https://composer.github.io/installer.sig)"
  curl -s https://getcomposer.org/installer -o /tmp/composer-setup.php
  ACTUAL_SIG="$(sha384sum /tmp/composer-setup.php | cut -d' ' -f1)"
  if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then
    echo "Composer installer signature mismatch, aborting" >&2
    rm -f /tmp/composer-setup.php
    exit 1
  fi
  sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
fi

log "installing certbot (not auto-issuing certs — see README)"
sudo apt-get install -y -qq certbot python3-certbot-apache >/dev/null

log "git identity check"
git --version >/dev/null

log "writing test vhost + welcome page"
TEST_ROOT="/var/www/html/provision-test"
WELCOME_FQDN="${1:-$(hostname -f)}"
sudo mkdir -p "$TEST_ROOT"
sudo tee "$TEST_ROOT/index.php" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${WELCOME_FQDN}</title>
<style>
  body { font-family: -apple-system, Helvetica, Arial, sans-serif; background: #0f172a; color: #e2e8f0;
         display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  .card { text-align: center; padding: 2.5rem 3rem; border-radius: 12px; background: #1e293b; }
  h1 { margin: 0 0 0.5rem; font-size: 1.8rem; }
  p { color: #94a3b8; margin: 0.25rem 0; }
  code { background: #0f172a; padding: 0.15rem 0.4rem; border-radius: 4px; }
</style>
</head>
<body>
  <div class="card">
    <h1>&#x2705; Welcome to ${WELCOME_FQDN}</h1>
    <p>Provisioned via the server-provisioning toolkit on the control host.</p>
    <p><?php echo "PHP " . PHP_VERSION . " &middot; " . php_uname("n"); ?></p>
  </div>
</body>
</html>
EOF
sudo chown -R www-data:www-data "$TEST_ROOT"

sudo tee /etc/apache2/vhosts.d/000-provision-test.conf >/dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName ${WELCOME_FQDN}
    DocumentRoot ${TEST_ROOT}
    ErrorLog \${APACHE_LOG_DIR}/provision-test.error.log
    CustomLog \${APACHE_LOG_DIR}/provision-test.access.log combined
    <Directory ${TEST_ROOT}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

sudo apache2ctl configtest
sudo systemctl enable --now apache2 >/dev/null
sudo systemctl reload apache2

log "LAMP install complete"
echo "PHP_VERSION=$PHP_VER"
echo "MYSQL_VERSION=$( [ "$SKIP_MYSQL" = "true" ] && echo "not installed (--skip-mysql)" || mysql --version )"
echo "COMPOSER_VERSION=$(composer --version 2>/dev/null | head -1)"
echo "APACHE_VERSION=$(apache2 -v | head -1)"
