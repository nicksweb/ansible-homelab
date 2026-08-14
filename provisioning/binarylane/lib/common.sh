#!/usr/bin/env bash
# Shared helpers for the server-provisioning toolkit.
# Sourced by every script under bin/ and scripts/ — never executed directly.

set -uo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="$(cd "$TOOLKIT_ROOT/../.." && pwd)"
STATE_DIR="$TOOLKIT_ROOT/state"

# ---------------------------------------------------------------------------
# Logging — never log secrets. Callers must pass already-redacted strings.
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }

# ---------------------------------------------------------------------------
# Configuration — config.env (gitignored, non-secret) with built-in defaults.
# ---------------------------------------------------------------------------
: "${SERVER_DOMAIN:=example.com}"
: "${BINARYLANE_REGION:=bne}"
: "${BINARYLANE_REGION_FALLBACK:=bne syd adl per}"  # tried in this order on "no suitable host" capacity errors
: "${BINARYLANE_PLAN:=std-1vcpu}"
: "${BINARYLANE_IMAGE:=ubuntu-24.04}"
: "${ADMIN_USER:=localadmin}"
: "${TIMEZONE:=Australia/Brisbane}"
: "${ENABLE_LAMP:=true}"
: "${ENABLE_CLOUDFLARE_TUNNEL:=false}"
: "${CLOUDFLARE_PROXY:=false}"
: "${BINARYLANE_CREDENTIAL_FILE:=$SRC_ROOT/.binarylane}"
: "${CLOUDFLARE_CREDENTIAL_FILE:=$TOOLKIT_ROOT/.cloudflare}"
: "${PROVISIONING_SSH_KEY:=$HOME/.ssh/binarylane_provisioning_ed25519}"
: "${CLOUDFLARE_ZONE_ID:=}"     # zone id for SERVER_DOMAIN — non-secret, from the Cloudflare dashboard or `GET /zones?name=<domain>`
: "${CLOUDFLARE_ACCOUNT_ID:=}"  # your Cloudflare account id — non-secret, from the dashboard or `GET /accounts`
: "${MANAGEMENT_SSH_HOSTNAME:=manage.example.com}"  # resolved fresh each run, explicitly allowed through ufw + fail2ban ignoreip on every provisioned server
: "${LETSENCRYPT_EMAIL:=}"  # optional; empty uses certbot --register-unsafely-without-email

if [ -f "$TOOLKIT_ROOT/config.env" ]; then
  # shellcheck disable=SC1091
  source "$TOOLKIT_ROOT/config.env"
fi

# ---------------------------------------------------------------------------
# Secret loading — values live only in shell variables, never echoed/logged.
# ---------------------------------------------------------------------------
# Consolidated credential store shared across projects (BINARYLANE_API_KEY,
# CLOUDFLARE_API_TOKEN as plain KEY=VALUE lines). This toolkit's own
# per-project credential files (below) are kept as a fallback only — the
# consolidated file is the canonical source going forward.
: "${API_AUTH_FILE:=$SRC_ROOT/.api-auth.env}"

load_binarylane_key() {
  if [ -f "$API_AUTH_FILE" ]; then
    BINARYLANE_API_KEY="$(sed -n 's/^BINARYLANE_API_KEY=//p' "$API_AUTH_FILE" | head -n1)"
  fi
  if [ -z "${BINARYLANE_API_KEY:-}" ]; then
    [ -f "$BINARYLANE_CREDENTIAL_FILE" ] || die "BinaryLane credential not found in $API_AUTH_FILE or $BINARYLANE_CREDENTIAL_FILE"
    BINARYLANE_API_KEY="$(sed -n 's/^binarylane-api=//p' "$BINARYLANE_CREDENTIAL_FILE" | head -n1)"
  fi
  [ -n "$BINARYLANE_API_KEY" ] || die "Could not parse a BinaryLane API key from $API_AUTH_FILE or $BINARYLANE_CREDENTIAL_FILE"
  export BINARYLANE_API_KEY
}

load_cloudflare_creds() {
  # This is a dedicated token for this toolkit (broader scope: DNS edit across
  # the account's zones + Cloudflare Tunnel:Edit) — separate from the
  # DNS-only token a separate site-management tool uses at
  # /etc/cloudflared/cf-api.env, which this toolkit does not touch.
  if [ -f "$API_AUTH_FILE" ]; then
    CF_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$API_AUTH_FILE" | head -n1)"
  fi
  if [ -z "${CF_API_TOKEN:-}" ]; then
    [ -f "$CLOUDFLARE_CREDENTIAL_FILE" ] || die "Cloudflare credential not found in $API_AUTH_FILE or $CLOUDFLARE_CREDENTIAL_FILE"
    CF_API_TOKEN="$(head -n1 "$CLOUDFLARE_CREDENTIAL_FILE" | tr -d '[:space:]')"
  fi
  [ -n "$CF_API_TOKEN" ] || die "Could not parse a Cloudflare API token from $API_AUTH_FILE or $CLOUDFLARE_CREDENTIAL_FILE"
  CF_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID"
  export CF_API_TOKEN CF_ACCOUNT_ID
}

# ---------------------------------------------------------------------------
# API wrappers. Body goes to a temp file so it never lands in shell history
# or process listings; only the redacted request line is logged.
# ---------------------------------------------------------------------------
BL_API_BASE="https://api.binarylane.com.au/v2"
CF_API_BASE="https://api.cloudflare.com/client/v4"

bl_api() {
  local method="$1" path="$2" data="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-s -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $BINARYLANE_API_KEY" -H "Content-Type: application/json")
  [ -n "$data" ] && args+=(-d "$data")
  local code; code="$(curl "${args[@]}" "$BL_API_BASE$path")"
  log "BinaryLane API $method $path -> HTTP $code"
  if [ "$code" -ge 400 ]; then
    warn "BinaryLane API error body: $(cat "$tmp")"
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-s -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [ -n "$data" ] && args+=(-d "$data")
  local code; code="$(curl "${args[@]}" "$CF_API_BASE$path")"
  log "Cloudflare API $method $path -> HTTP $code"
  if [ "$code" -ge 400 ]; then
    warn "Cloudflare API error body: $(cat "$tmp")"
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Name validation
# ---------------------------------------------------------------------------
validate_server_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "Invalid server name '$name': must be lowercase alphanumeric/hyphen, matching a valid DNS label"
  [ ${#name} -le 63 ] || die "Server name too long (max 63 chars)"
}

fqdn_for() { echo "${1}.${SERVER_DOMAIN}"; }

# resolve_zone_id_for_domain <domain> — validates the domain against the
# *live* Cloudflare zone list for the account and echoes its zone ID. Used
# whenever a domain other than the configured default SERVER_DOMAIN is
# requested, so a typo can't silently create records in the wrong place (or
# fail confusingly) — matches the same safety check add-site.sh has always
# used for arbitrary domains.
resolve_zone_id_for_domain() {
  local domain="$1"
  local zones zone_id
  zones="$(cf_api GET "/zones?per_page=200")" || die "Could not list Cloudflare zones"
  zone_id="$(echo "$zones" | jq -r --arg d "$domain" '.result[] | select(.name == $d) | .id')"
  [ -n "$zone_id" ] || die "'$domain' is not a zone in this Cloudflare account — refusing to guess. Available zones: $(echo "$zones" | jq -r '.result[].name' | tr '\n' ' ')"
  echo "$zone_id"
}

# resolve_zone_id_for_hostname <hostname> — like resolve_zone_id_for_domain,
# but for a full hostname that may live under any zone in the account, not
# necessarily the zone matching the *server's* own --domain. Suffix-matches
# against the live zone list and picks the longest (most specific) match.
# Cloudflare's API does NOT reject a record whose name doesn't belong to the
# target zone — it silently appends the zone's own suffix instead (e.g. a
# CNAME meant for "foo.example.com" posted against the wrong zone ID becomes
# "foo.example.com.wrongzone.com"). Always resolve the zone from the hostname
# itself before creating a record for it.
resolve_zone_id_for_hostname() {
  local hostname="$1"
  local zones best_name="" best_id=""
  zones="$(cf_api GET "/zones?per_page=200")" || die "Could not list Cloudflare zones"
  while IFS=$'\t' read -r zname zid; do
    case ".${hostname}" in
      *".${zname}")
        [ ${#zname} -gt ${#best_name} ] && { best_name="$zname"; best_id="$zid"; }
        ;;
    esac
  done < <(echo "$zones" | jq -r '.result[] | "\(.name)\t\(.id)"')
  [ -n "$best_id" ] || die "No Cloudflare zone in this account matches '$hostname' — refusing to guess (Cloudflare would otherwise silently misfile the record under the wrong zone). Available zones: $(echo "$zones" | jq -r '.result[].name' | tr '\n' ' ')"
  echo "$best_id"
}

# ---------------------------------------------------------------------------
# State (non-secret JSON per server, under state/)
# ---------------------------------------------------------------------------
state_file() { echo "$STATE_DIR/${1}.json"; }

state_exists() { [ -f "$(state_file "$1")" ]; }

state_write() {
  # state_write <name> <json>
  mkdir -p "$STATE_DIR"
  echo "$2" > "$(state_file "$1")"
}

state_read_field() {
  # state_read_field <name> <jq-filter>
  [ -f "$(state_file "$1")" ] || return 1
  jq -r "$2" "$(state_file "$1")"
}

# ---------------------------------------------------------------------------
# Provisioning record (human-readable, lives outside the toolkit dir)
# ---------------------------------------------------------------------------
record_file() { echo "$SRC_ROOT/provisioned-servers-${1}.txt"; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required but not installed (sudo apt install -y jq)"; }

# ---------------------------------------------------------------------------
# SSH connection multiplexing — reuse one persistent connection per host
# across every ssh/scp call in a run, instead of opening a fresh TCP+SSH
# handshake each time. Observed empirically: fresh BinaryLane servers can
# become unreachable on port 22 a short time after a burst of new
# connections (seen with zero guest-side hardening applied, so it isn't
# ufw/fail2ban/sshd_config — likely a connection-rate protection somewhere
# between here and the guest). Multiplexing keeps new-connection count to one
# per host per run, which is the mitigation, not a confirmed root-cause fix.
SSH_CONTROL_DIR="$HOME/.ssh/controlmasters"
mkdir -p "$SSH_CONTROL_DIR"
chmod 700 "$SSH_CONTROL_DIR"
SSH_MULTIPLEX_OPTS=(-o "ControlMaster=auto" -o "ControlPersist=15m" -o "ControlPath=$SSH_CONTROL_DIR/%r@%h:%p")

ssh_close_multiplexed() {
  # ssh_close_multiplexed <user> <host> — explicitly tear down a persisted
  # control connection (e.g. once a run finishes, or before destroying a
  # server) rather than waiting out the full ControlPersist window.
  local user="$1" host="$2"
  ssh -o "ControlPath=$SSH_CONTROL_DIR/%r@%h:%p" -O exit "${user}@${host}" >/dev/null 2>&1 || true
}
