#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER via ssh+sudo, orchestrated by bin/provision-server.sh
# when --enable-tls is passed. Issues a real Let's Encrypt certificate for the
# server's own base FQDN only — never the Cloudflare Tunnel hostname, which
# already gets TLS for free at Cloudflare's edge and isn't reachable directly
# by the ACME HTTP-01 challenge in the way this needs anyway. Idempotent —
# skips cleanly if a certificate already exists (also keeps this off Let's
# Encrypt's rate limits when a server gets rebuilt repeatedly under the same
# name during testing).
#
# Usage: install-certbot.sh <fqdn> [email]
#   email: optional. If omitted, registers with certbot's
#   --register-unsafely-without-email (no renewal-failure notifications).
set -euo pipefail

FQDN="${1:?usage: install-certbot.sh <fqdn> [email]}"
EMAIL="${2:-}"

log() { echo "[certbot] $*"; }

if sudo test -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem"; then
  log "Certificate for $FQDN already exists — skipping issuance. Run 'sudo certbot renew' to refresh manually if needed."
  exit 0
fi

EMAIL_ARGS=(--register-unsafely-without-email)
[ -n "$EMAIL" ] && EMAIL_ARGS=(-m "$EMAIL" --no-eff-email)

log "Requesting a certificate for $FQDN (HTTP-01 via the apache plugin)..."
sudo certbot --apache -d "$FQDN" --non-interactive --agree-tos --redirect "${EMAIL_ARGS[@]}"

sudo apache2ctl configtest
sudo systemctl reload apache2
log "Certificate issued and Apache configured for HTTPS (with HTTP->HTTPS redirect) on $FQDN"
