#!/usr/bin/env bash
# Runs ON THE REMOTE CONTAINER via ssh+sudo, orchestrated by
# bin/provision-container.sh when --enable-tls is passed. Issues a real
# Let's Encrypt certificate for the container's *internal* FQDN
# (host001.in.example.com) using DNS-01 validation via the Cloudflare
# API — NOT HTTP-01. This matters specifically because of the split-DNS
# design: .in.example.com is only resolvable on the internal LAN (via the
# UDM), so an HTTP-01 challenge from Let's Encrypt's public validation
# servers could never reach it. DNS-01 only needs the ability to create a
# TXT record via the API — it works regardless of whether the A record
# itself is public. Idempotent — skips cleanly if a cert already covers
# every requested domain, expands it (adds SANs) otherwise.
#
# Usage: install-https-dns01.sh <fqdn> <email> [additional_domain ...]
# <email> may be an empty string (still a required positional arg). Any
# additional domains (typically --public-hostname, when a LAN client reaches
# it via the local DNS override instead of the real Cloudflare Tunnel — that
# path terminates TLS on this container directly, so it needs its own valid
# SAN, not just Cloudflare's edge cert) are added to the same certificate as
# extra SANs rather than issuing a second cert, since Apache only has one
# HTTPS vhost here and just needs one cert covering every name it might be
# asked for. The Cloudflare token is read from stdin (never an argument),
# same discipline as the tunnel connector token.
set -euo pipefail

FQDN="${1:?usage: install-https-dns01.sh <fqdn> <email> [additional_domain ...]  (Cloudflare token via stdin)}"
EMAIL="${2:-}"
shift 2
ADDITIONAL_DOMAINS=("$@")

log() { echo "[https-dns01] $*"; }

CF_TOKEN="$(cat -)"
[ -n "$CF_TOKEN" ] || { echo "No Cloudflare token received on stdin" >&2; exit 1; }

DOMAIN_ARGS=(-d "$FQDN")
for d in "${ADDITIONAL_DOMAINS[@]}"; do
  DOMAIN_ARGS+=(-d "$d")
done

NEED_ISSUANCE=true
if sudo test -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem"; then
  EXISTING_SANS="$(sudo openssl x509 -in "/etc/letsencrypt/live/${FQDN}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | cut -d: -f2)"
  MISSING=""
  for d in "$FQDN" "${ADDITIONAL_DOMAINS[@]}"; do
    echo "$EXISTING_SANS" | grep -qx "$d" || MISSING="$MISSING $d"
  done
  if [ -z "$MISSING" ]; then
    log "Certificate for $FQDN already covers every requested domain — skipping issuance. Run 'sudo certbot renew' to refresh manually if needed."
    NEED_ISSUANCE=false
  else
    log "Existing certificate for $FQDN is missing:$MISSING — expanding it"
    # Rebuild DOMAIN_ARGS as the FULL union of every existing SAN plus every
    # newly requested domain, deduplicated (FQDN first). This matters:
    # certbot's --expand does NOT union with the current cert's SANs on its
    # own — confirmed directly by testing (a cert with SANs {A, B}, expanded
    # with only `-d A -d C`, came back with SANs {A, C} — B was silently
    # dropped, not kept). Passing only the newly-requested domain(s), as an
    # earlier version of this script did, would silently un-cover every
    # previously added hostname on every subsequent add-vhost.sh run.
    DOMAIN_ARGS=()
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      DOMAIN_ARGS+=(-d "$d")
    done < <(printf '%s\n' "$FQDN" "${ADDITIONAL_DOMAINS[@]}" "$EXISTING_SANS" | awk '!seen[$0]++')
  fi
fi

if $NEED_ISSUANCE; then
  log "Installing certbot + the Cloudflare DNS plugin"
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -qq
  sudo apt-get install -y -qq certbot python3-certbot-dns-cloudflare >/dev/null

  log "Writing scoped credentials file for the certbot plugin (mode 600, root-only)"
  sudo install -d -m 700 /etc/letsencrypt
  CRED_FILE=/etc/letsencrypt/cloudflare.ini
  printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" | sudo tee "$CRED_FILE" >/dev/null
  sudo chmod 600 "$CRED_FILE"
  unset CF_TOKEN

  EMAIL_ARGS=(--register-unsafely-without-email)
  [ -n "$EMAIL" ] && EMAIL_ARGS=(-m "$EMAIL" --no-eff-email)

  log "Requesting certificate for ${DOMAIN_ARGS[*]} via DNS-01 (this waits ~30s per zone for the TXT record to propagate)..."
  # Retried — confirmed via testing that certbot can hit a transient DNS
  # resolution failure for acme-v02.api.letsencrypt.org shortly after a
  # container has just come up (everything else, incl. apt and GitHub
  # downloads, resolved fine seconds before and after; the UDM resolver was
  # likely momentarily busy from the burst of API/DNS calls provisioning makes
  # right before this step runs). Not fatal — just retry with a short backoff
  # rather than treating one flaky lookup as a hard failure.
  CERTBOT_OK=false
  for attempt in 1 2 3; do
    if sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CRED_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$FQDN" --expand \
        "${DOMAIN_ARGS[@]}" --non-interactive --agree-tos "${EMAIL_ARGS[@]}"; then
      CERTBOT_OK=true
      break
    fi
    log "certbot attempt $attempt/3 failed — waiting 15s before retrying (often a transient DNS resolution blip)..."
    sleep 15
  done
  $CERTBOT_OK || { echo "certbot failed after 3 attempts" >&2; exit 1; }
fi

log "Certificate status:"
sudo certbot certificates --cert-name "$FQDN" 2>/dev/null | grep -E "Certificate Name|Domains|Expiry Date"

# certbot's own systemd timer (installed with the package on Ubuntu) handles
# renewal automatically — confirm it's enabled rather than assuming.
sudo systemctl enable --now certbot.timer >/dev/null 2>&1 || true
log "Renewal timer: $(systemctl is-enabled certbot.timer 2>/dev/null || echo 'not found — check manually')"
