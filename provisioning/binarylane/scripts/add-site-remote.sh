#!/usr/bin/env bash
# Runs ON THE PROVISIONED SERVER (copied over and executed via ssh+sudo by
# bin/add-site.sh). Creates a webroot + Apache vhost for one site, and
# optionally an ingress rule in this server's own dedicated Cloudflare Tunnel
# config. Mirrors standard Apache vhost conventions used elsewhere in this
# toolkit.
#
# Usage: add-site-remote.sh <fqdn> <php_choice> <add_tunnel_ingress>
#   php_choice: a version like "8.3", "highest" (use the newest php-fpm
#               socket found), or "none" (static site, no PHP block)
#   add_tunnel_ingress: "true" to also add/refresh a local cloudflared
#               ingress rule for <fqdn> -> localhost:80 and restart
#               cloudflared; "false" to skip (direct/no-tunnel server)
set -euo pipefail

FQDN="${1:?usage: add-site-remote.sh <fqdn> <php_choice> <add_tunnel_ingress>}"
PHP_CHOICE="${2:?}"
ADD_TUNNEL_INGRESS="${3:?}"

log() { echo "[add-site] $*"; }

WEBROOT="/var/www/html/sites/${FQDN}/public"
VHOST="/etc/apache2/vhosts.d/${FQDN}.conf"

if [ -d "$WEBROOT" ]; then
  log "Webroot already exists at $WEBROOT — leaving content as-is"
else
  log "Creating webroot at $WEBROOT"
  sudo mkdir -p "$WEBROOT"
  # Same styled welcome-card splash page the Proxmox toolkit's
  # install-test-vhost.sh writes for a new public hostname — this used to be
  # a bare `<?php echo "It works: ..."` line with no styling at all, out of
  # step with what every other newly-provisioned vhost in either toolkit
  # actually looks like.
  if [ "$PHP_CHOICE" = "none" ]; then
    sudo tee "$WEBROOT/index.html" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${FQDN}</title>
<style>
  body { font-family: -apple-system, Helvetica, Arial, sans-serif; background: #0f172a; color: #e2e8f0;
         display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  .card { text-align: center; padding: 2.5rem 3rem; border-radius: 12px; background: #1e293b; }
  h1 { margin: 0 0 0.5rem; font-size: 1.8rem; }
  p { color: #94a3b8; margin: 0.25rem 0; }
</style>
</head>
<body>
  <div class="card">
    <h1>&#x2705; Welcome to ${FQDN}</h1>
    <p>Provisioned via the server-provisioning toolkit on the control host.</p>
    <p>Static site &middot; no PHP</p>
  </div>
</body>
</html>
EOF
  else
    sudo tee "$WEBROOT/index.php" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${FQDN}</title>
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
    <h1>&#x2705; Welcome to ${FQDN}</h1>
    <p>Provisioned via the server-provisioning toolkit on the control host.</p>
    <p><?php echo "PHP " . PHP_VERSION . " &middot; " . \$_SERVER['SERVER_NAME']; ?></p>
  </div>
</body>
</html>
EOF
  fi
  sudo chown -R www-data:www-data "/var/www/html/sites/${FQDN}"
fi

PHP_BLOCK=""
if [ "$PHP_CHOICE" != "none" ]; then
  # Stock Ubuntu php-fpm packages (what install-lamp.sh actually installs)
  # name their socket php{version}-fpm.sock — NOT the www{version}.sock
  # convention an existing hand-configured multi-version setup uses.
  if [ "$PHP_CHOICE" = "highest" ]; then
    # [0-9] after "php" excludes the versionless php-fpm.sock alternatives symlink
    PHP_VER="$(ls /run/php/php[0-9]*-fpm.sock 2>/dev/null | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm\.sock#\1#' | sort -V | tail -1)"
  else
    PHP_VER="$PHP_CHOICE"
  fi
  [ -S "/run/php/php${PHP_VER}-fpm.sock" ] || { echo "No PHP-FPM socket found for version '$PHP_VER' (looked for /run/php/php${PHP_VER}-fpm.sock)" >&2; exit 1; }
  PHP_BLOCK="
    <FilesMatch \\.php\$>
        SetHandler \"proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost\"
    </FilesMatch>"
  log "Wiring PHP ${PHP_VER}"
else
  log "Static site (no PHP)"
fi

if [ -f "$VHOST" ]; then
  log "Vhost $VHOST already exists — leaving it as-is (re-run add-site with a PHP version change to update just the PHP block manually if needed)"
else
  log "Writing vhost $VHOST"
  sudo tee "$VHOST" >/dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@${FQDN}
    ServerName ${FQDN}
    DocumentRoot ${WEBROOT}

    ErrorLog \${APACHE_LOG_DIR}/${FQDN}.error.log
    CustomLog \${APACHE_LOG_DIR}/${FQDN}.access.log combined

    SetEnvIf X-Forwarded-Proto "^https\$" HTTPS=on
    SetEnvIf X-Forwarded-Proto "^https\$" HTTP_X_FORWARDED_PROTO=https

    <FilesMatch "^\.ht">
        Require all denied
    </FilesMatch>
${PHP_BLOCK}
    <Directory ${WEBROOT}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
fi

sudo apache2ctl configtest
sudo systemctl reload apache2
log "Apache vhost active for $FQDN"

if [ "$ADD_TUNNEL_INGRESS" = "true" ]; then
  CONFIG_YML=/etc/cloudflared/config.yml
  [ -f "$CONFIG_YML" ] || { echo "$CONFIG_YML not found — this server wasn't provisioned with --cloudflare-tunnel" >&2; exit 1; }
  if sudo grep -qE "hostname:\s*${FQDN}\$" "$CONFIG_YML"; then
    log "Ingress rule for $FQDN already present in $CONFIG_YML"
  else
    log "Adding ingress rule for $FQDN -> http://localhost:80"
    sudo cp "$CONFIG_YML" "${CONFIG_YML}.bak-$(date +%Y%m%d%H%M%S)"
    sudo python3 - "$CONFIG_YML" "$FQDN" <<'PYEOF'
import sys, yaml
path, fqdn = sys.argv[1:3]
with open(path) as f:
    cfg = yaml.safe_load(f)
rules = cfg.setdefault("ingress", [])
new_rule = {"hostname": fqdn, "service": "http://localhost:80"}
catch_all_idx = next((i for i, r in enumerate(rules) if "hostname" not in r), len(rules))
rules.insert(catch_all_idx, new_rule)
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PYEOF
    sudo cloudflared tunnel --config "$CONFIG_YML" ingress validate
    sudo systemctl restart cloudflared
    sleep 2
    [ "$(systemctl is-active cloudflared)" = "active" ] || { echo "cloudflared failed to restart after adding ingress rule" >&2; exit 1; }
    log "cloudflared restarted with new ingress rule"
  fi
fi

echo "PHP_VERSION_USED=${PHP_VER:-none}"
