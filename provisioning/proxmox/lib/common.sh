#!/usr/bin/env bash
# Shared helpers for the Proxmox LXC provisioning workflow.
# Sourced by every script under bin/ and scripts/ — never executed directly.
set -uo pipefail

PVE_TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVISIONING_ROOT="$(cd "$PVE_TOOLKIT_ROOT/.." && pwd)"
SRC_ROOT="$(cd "$PROVISIONING_ROOT/.." && pwd)"
STATE_DIR="$PVE_TOOLKIT_ROOT/state"

# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/logging.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ssh.sh"

# ---------------------------------------------------------------------------
# Configuration — config.env (gitignored, non-secret) with built-in defaults.
# ---------------------------------------------------------------------------
: "${INTERNAL_DOMAIN:=in.example.com}"        # host001.in.example.com etc.
: "${PVE_STORAGE:=storage}"                      # rootdir/images pool — confirmed present on all online nodes
: "${PVE_TEMPLATE_STORAGE:=local}"               # vztmpl-capable storage
: "${PVE_TEMPLATE:=ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
: "${PVE_BRIDGE:=vmbr0}"
: "${PVE_VLAN_TAG:=}"  # empty = native/untagged VLAN1 (172.16.0.0/23) — confirmed working via testing.
                        # VLAN20 was tried first but has no DHCP response on this trunk; set this to a
                        # numeric tag to use a different VLAN once its DHCP scope is confirmed working.
: "${DEFAULT_CORES:=2}"
: "${DEFAULT_MEMORY_MB:=2048}"
: "${DEFAULT_DISK_GB:=30}"
: "${ADMIN_USER:=localadmin}"
: "${TIMEZONE:=Australia/Brisbane}"
: "${PROVISIONING_SSH_KEY:=$HOME/.ssh/homelab_provisioning}"
: "${LETSENCRYPT_EMAIL:=}"  # optional; empty uses certbot --register-unsafely-without-email
: "${UDM_NETWORK_ID:=}"                                # your UDM network's object id (Settings > Networks > ... > API), required for DHCP reservations/local DNS
: "${UDM_RESERVATION_RANGE_START:=172.16.0.100}"      # static-reservation range, deliberately below the DHCP dynamic
: "${UDM_RESERVATION_RANGE_END:=172.16.0.159}"        # pool (172.16.0.160-172.16.0.250) to avoid any conflict — adjust to your own DHCP scope
: "${BESZEL_HUB_URL:=}"                                # e.g. https://beszel.example.com — your Beszel hub, required unless --skip-beszel is always used
: "${BESZEL_HUB_KEY:=}"                                # the hub's own SSH public key (not secret) — from the hub's Settings > Add System page
: "${BESZEL_PORT:=45876}"
: "${API_AUTH_FILE:=$SRC_ROOT/.api-auth.env}"

if [ -f "$PVE_TOOLKIT_ROOT/config.env" ]; then
  # shellcheck disable=SC1091
  source "$PVE_TOOLKIT_ROOT/config.env"
fi

# ---------------------------------------------------------------------------
# Secret loading
# ---------------------------------------------------------------------------
load_proxmox_creds() {
  [ -f "$API_AUTH_FILE" ] || die "Credential file not found: $API_AUTH_FILE"
  PROXMOX_TOKEN_ID="$(sed -n 's/^PROXMOX_TOKEN_ID=//p' "$API_AUTH_FILE" | head -n1)"
  PROXMOX_API_SECRET="$(sed -n 's/^PROXMOX_API_SECRET=//p' "$API_AUTH_FILE" | head -n1)"
  [ -n "$PROXMOX_TOKEN_ID" ] && [ -n "$PROXMOX_API_SECRET" ] || die "Could not parse PROXMOX_TOKEN_ID/PROXMOX_API_SECRET from $API_AUTH_FILE"
  PROXMOX_HOSTS=()
  local h
  for var in PROXMOXHOST1 PROXMOXHOST2 PROXMOXHOST3 PROXMOXHOST4; do
    h="$(sed -n "s/^${var}=//p" "$API_AUTH_FILE" | head -n1)"
    [ -n "$h" ] && PROXMOX_HOSTS+=("$h")
  done
  [ "${#PROXMOX_HOSTS[@]}" -gt 0 ] || die "No PROXMOXHOST* entries found in $API_AUTH_FILE"
  export PROXMOX_TOKEN_ID PROXMOX_API_SECRET
}

load_cloudflare_token() {
  [ -f "$API_AUTH_FILE" ] || die "Credential file not found: $API_AUTH_FILE"
  CF_API_TOKEN="$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$API_AUTH_FILE" | head -n1)"
  [ -n "$CF_API_TOKEN" ] || die "Could not parse CLOUDFLARE_API_TOKEN from $API_AUTH_FILE"
  export CF_API_TOKEN
}

load_udm_creds() {
  [ -f "$API_AUTH_FILE" ] || die "Credential file not found: $API_AUTH_FILE"
  UBIQUITI_ROUTER="$(sed -n 's/^UbiquitiRouter=//p' "$API_AUTH_FILE" | head -n1)"
  UBIQUITI_KEY="$(sed -n 's/^UbiquitiKey=//p' "$API_AUTH_FILE" | head -n1)"
  [ -n "$UBIQUITI_ROUTER" ] && [ -n "$UBIQUITI_KEY" ] || die "Could not parse UbiquitiRouter/UbiquitiKey from $API_AUTH_FILE"
  export UBIQUITI_ROUTER UBIQUITI_KEY
}

load_beszel_creds() {
  [ -f "$API_AUTH_FILE" ] || die "Credential file not found: $API_AUTH_FILE"
  BESZEL_TOKEN="$(sed -n 's/^BESZEL_UNIVERSAL_CODE=//p' "$API_AUTH_FILE" | head -n1)"
  [ -n "$BESZEL_TOKEN" ] || die "Could not parse BESZEL_UNIVERSAL_CODE from $API_AUTH_FILE"
  export BESZEL_TOKEN
}

# ---------------------------------------------------------------------------
# Proxmox API — finds a reachable cluster member once per process, then
# reuses it (any online node can serve API requests for the whole cluster).
# ---------------------------------------------------------------------------
PVE_API_HOST=""

pve_discover_host() {
  [ -n "$PVE_API_HOST" ] && return 0
  local h
  for h in "${PROXMOX_HOSTS[@]}"; do
    if curl -s -k -o /dev/null -w '' --max-time 5 \
        -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_API_SECRET}" \
        "https://${h}:8006/api2/json/version" 2>/dev/null; then
      PVE_API_HOST="$h"
      log "Using Proxmox API host: $h"
      return 0
    fi
  done
  die "No Proxmox host in PROXMOXHOST1-4 is reachable"
}

pve_api() {
  # pve_api <method> <path> [field ...]
  # Each field is a raw "key=value" string, sent via --data-urlencode (each
  # field urlencoded independently and correctly) rather than a hand-built
  # encoded string — much less error-prone for values containing :,=,/, etc.
  local method="$1" path="$2"
  shift 2
  pve_discover_host
  local tmp; tmp="$(mktemp)"
  local args=(-s -k -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_API_SECRET}")
  local field
  for field in "$@"; do
    args+=(--data-urlencode "$field")
  done
  local code; code="$(curl "${args[@]}" "https://${PVE_API_HOST}:8006/api2/json${path}")"
  log "Proxmox API $method $path -> HTTP $code"
  if [ "$code" -ge 400 ]; then
    warn "Proxmox API error body: $(cat "$tmp")"
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Name / hostname validation
# ---------------------------------------------------------------------------
validate_hostname() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "Invalid hostname '$name': must be lowercase alphanumeric/hyphen, matching a valid DNS label"
}

fqdn_for() { echo "${1}.${INTERNAL_DOMAIN}"; }

# ---------------------------------------------------------------------------
# State (non-secret JSON per container, under state/) + human-readable record
# ---------------------------------------------------------------------------
state_file() { echo "$STATE_DIR/${1}.json"; }
state_exists() { [ -f "$(state_file "$1")" ]; }
state_write() { mkdir -p "$STATE_DIR"; echo "$2" > "$(state_file "$1")"; }
state_read_field() {
  [ -f "$(state_file "$1")" ] || return 1
  jq -r "$2" "$(state_file "$1")"
}

record_dir() { echo "$SRC_ROOT/provisioned-servers"; }
record_file() { mkdir -p "$(record_dir)"; echo "$(record_dir)/${1}.txt"; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required but not installed (sudo apt install -y jq)"; }
