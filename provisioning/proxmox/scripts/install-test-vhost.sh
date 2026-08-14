#!/usr/bin/env bash
# Runs ON THE REMOTE CONTAINER via ssh+sudo, orchestrated by
# bin/provision-container.sh and bin/add-vhost.sh. NOT a "role" system (the
# brief explicitly said not to build --role webserver/docker/etc. yet) —
# just a minimal Apache + welcome page so HTTP/HTTPS verification (internal
# and, if a tunnel is configured, external) has something real to check
# against. Mirrors the BinaryLane workflow's install-lamp.sh welcome page,
# much lighter (no PHP/MySQL — add those only once an actual application
# needs them).
#
# Usage: install-test-vhost.sh <fqdn> [public_hostname ...]
# Each [public_hostname] (typically a --public-hostname from
# provision-container.sh, or a hostname passed to add-vhost.sh) gets its OWN
# vhost with its own docroot and content, keyed by that hostname — not
# served as an alias off the internal FQDN's vhost, and not sharing a config
# file/docroot with any other public hostname either. Without per-hostname
# naming, a second call for a different hostname would silently overwrite
# the first one's Apache config (this exact bug existed in an earlier
# version — a fixed "010-public.conf"/"/var/www/public" pair regardless of
# which hostname was passed). Idempotent and additive — re-running for one
# hostname never touches another hostname's files, so this can be called
# once per vhost over the life of the container.
#
# If a Let's Encrypt cert already exists for <fqdn> (from install-https-dns01.sh,
# which uses certonly — no web server needed for DNS-01) and covers a given
# public hostname too (install-https-dns01.sh adds each one as a SAN on the
# same cert), that vhost gets HTTPS wired up using the same certificate.
set -euo pipefail

FQDN="${1:?usage: install-test-vhost.sh <fqdn> [public_hostname ...]}"
shift
PUBLIC_HOSTNAMES=("$@")

log() { echo "[test-vhost] $*"; }

export DEBIAN_FRONTEND=noninteractive

if ! command -v apache2 >/dev/null 2>&1; then
  log "Installing Apache"
  sudo apt-get update -qq
  sudo apt-get install -y -qq apache2 >/dev/null
fi

log "Opening ufw for HTTP/HTTPS (SSH-only until now)"
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null

# conf_name_for <hostname> — a filesystem/Apache-safe, unique config name
# derived from the hostname itself, so multiple public vhosts can coexist.
conf_name_for() { echo "site-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-')"; }

# write_welcome_page <docroot> <hostname> <subtitle>
write_welcome_page() {
  local webroot="$1" hostname="$2" subtitle="$3"
  sudo install -d -m 755 "$webroot"
  sudo tee "$webroot/index.html" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${hostname}</title>
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
    <h1>&#x2705; Welcome to ${hostname}</h1>
    <p>${subtitle}</p>
  </div>
</body>
</html>
EOF
  sudo chown -R www-data:www-data "$webroot"
}

# write_vhost <sites_available_name> <port> <hostname> <docroot> [cert_dir]
write_vhost() {
  local conf_name="$1" port="$2" hostname="$3" docroot="$4" cert_dir="${5:-}"
  if [ "$port" = "443" ]; then
    sudo a2enmod -q ssl >/dev/null
    sudo tee "/etc/apache2/sites-available/${conf_name}.conf" >/dev/null <<EOF
<VirtualHost *:443>
    ServerName ${hostname}
    DocumentRoot ${docroot}
    SSLEngine on
    SSLCertificateFile ${cert_dir}/fullchain.pem
    SSLCertificateKeyFile ${cert_dir}/privkey.pem
    ErrorLog \${APACHE_LOG_DIR}/${conf_name}.error.log
    CustomLog \${APACHE_LOG_DIR}/${conf_name}.access.log combined
</VirtualHost>
EOF
  else
    sudo tee "/etc/apache2/sites-available/${conf_name}.conf" >/dev/null <<EOF
<VirtualHost *:80>
    ServerName ${hostname}
    DocumentRoot ${docroot}
    ErrorLog \${APACHE_LOG_DIR}/${conf_name}.error.log
    CustomLog \${APACHE_LOG_DIR}/${conf_name}.access.log combined
</VirtualHost>
EOF
  fi
  sudo a2ensite -q "$conf_name" >/dev/null
}

sudo a2dissite -q 000-default >/dev/null 2>&1 || true

INTERNAL_WEBROOT="/var/www/html"
log "Writing internal vhost (ServerName ${FQDN})"
write_welcome_page "$INTERNAL_WEBROOT" "$FQDN" "Provisioned via the Proxmox LXC provisioning toolkit on the control host (internal FQDN)."
write_vhost "000-internal" 80 "$FQDN" "$INTERNAL_WEBROOT"

CERT_DIR="/etc/letsencrypt/live/${FQDN}"
HAVE_CERT=false
if sudo test -f "${CERT_DIR}/fullchain.pem"; then
  HAVE_CERT=true
  log "Existing Let's Encrypt cert found — wiring up HTTPS for the internal vhost"
  write_vhost "000-internal-ssl" 443 "$FQDN" "$INTERNAL_WEBROOT" "$CERT_DIR"
else
  log "No cert found for ${FQDN} yet — HTTP only (run with --enable-tls to get HTTPS)"
fi

for PUBLIC_HOSTNAME in "${PUBLIC_HOSTNAMES[@]}"; do
  CONF_NAME="$(conf_name_for "$PUBLIC_HOSTNAME")"
  PUBLIC_WEBROOT="/var/www/${PUBLIC_HOSTNAME}"
  log "Writing separate vhost for ${PUBLIC_HOSTNAME} (${CONF_NAME}) — its own docroot, not shared with any other hostname"
  write_welcome_page "$PUBLIC_WEBROOT" "$PUBLIC_HOSTNAME" "Provisioned via the Proxmox LXC provisioning toolkit on the control host (public hostname — reached via Cloudflare Tunnel externally, or the local DNS override internally)."
  write_vhost "$CONF_NAME" 80 "$PUBLIC_HOSTNAME" "$PUBLIC_WEBROOT"

  if $HAVE_CERT; then
    # Same certificate file as the internal vhost: install-https-dns01.sh
    # adds each public hostname as an extra SAN on that one cert (rather
    # than issuing a separate cert per hostname) when --enable-tls is used
    # alongside it, so it's valid for this vhost too as long as it actually
    # covers this name — check rather than assume, since --enable-tls could
    # have been run before this hostname was ever added.
    if sudo openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -qF "DNS:${PUBLIC_HOSTNAME}"; then
      log "Cert covers ${PUBLIC_HOSTNAME} — wiring up HTTPS for its vhost too"
      write_vhost "${CONF_NAME}-ssl" 443 "$PUBLIC_HOSTNAME" "$PUBLIC_WEBROOT" "$CERT_DIR"
    else
      log "Cert for ${FQDN} does NOT cover ${PUBLIC_HOSTNAME} — HTTP only for this vhost. Re-run with --enable-tls to expand it."
    fi
  fi
done

sudo apache2ctl configtest
sudo systemctl enable --now apache2 >/dev/null
sudo systemctl reload apache2
log "Apache active, serving ${FQDN}$([ "${#PUBLIC_HOSTNAMES[@]}" -gt 0 ] && printf ' and %s' "${PUBLIC_HOSTNAMES[@]}")"
