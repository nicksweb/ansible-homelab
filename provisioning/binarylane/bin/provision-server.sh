#!/usr/bin/env bash
# Provision a new BinaryLane Ubuntu 24.04 LAMP server with Cloudflare DNS
# identity and optional Cloudflare Tunnel exposure.
#
# Usage:
#   provision-server.sh --name sacloudserver01 [options]
#
# Options:
#   --name NAME                 Logical server name (required). FQDN = NAME.<domain>
#   --domain DOMAIN               Override SERVER_DOMAIN for this server (default: config SERVER_DOMAIN).
#                                  Must be a zone the Cloudflare token can see — validated live, not assumed.
#                                  Note: local state/records are keyed by --name alone, not name+domain, so
#                                  the same short name can't be in use under two domains at once.
#   --region SLUG                BinaryLane region (default: config BINARYLANE_REGION)
#   --plan SLUG                  BinaryLane size slug (default: config BINARYLANE_PLAN)
#   --image SLUG                 BinaryLane image slug (default: config BINARYLANE_IMAGE)
#   --cloudflare-tunnel           Enable Cloudflare Tunnel exposure (requires --cloudflare-hostname)
#   --cloudflare-hostname FQDN    Public hostname routed through this server's dedicated tunnel
#   --cloudflare-proxy on|off     Proxy mode for the base A record (default: off / DNS-only)
#   --enable-tls                  Issue a real Let's Encrypt cert for the server's own base FQDN
#                                  (never the tunnel hostname — that already gets TLS from Cloudflare's
#                                  edge). Requires the base A record to actually be publicly resolving —
#                                  skipped with a clear warning if DNS hasn't propagated in time.
#   --letsencrypt-email EMAIL     Contact email for the cert (default: config LETSENCRYPT_EMAIL, or
#                                  none — registers with --register-unsafely-without-email)
#   --skip-lamp                   Skip LAMP install
#   --skip-mysql                  Install Apache/PHP but skip local MySQL (this server
#                                  expects to connect to a separate --db-only server instead)
#   --db-only                     Install a standalone MySQL server instead of LAMP — no
#                                  Apache/PHP. Requires --db-allow-from. Never opens 3306
#                                  publicly: ufw restricts it to exactly the IP(s) given.
#   --db-allow-from IP[,IP...]    Required with --db-only. IPv4 address(es)/CIDR(s) allowed
#                                  through ufw to reach MySQL (typically the app server's
#                                  own public IP, from its state file after provisioning it).
#   --skip-harden                 Skip SSH/firewall hardening (not recommended)
#   --dry-run                     Print the plan and exit, no chargeable action taken
#   --yes                         Skip the interactive confirmation prompt
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="" DOMAIN="" CF_TUNNEL=false CF_HOSTNAME=""
case "${CLOUDFLARE_PROXY:-false}" in
  true|on) CF_PROXY="on" ;;
  *) CF_PROXY="off" ;;
esac
SKIP_LAMP=false SKIP_HARDEN=false DRY_RUN=false ASSUME_YES=false
SKIP_MYSQL=false DB_ONLY=false DB_ALLOW_FROM=""
ENABLE_TLS=false LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
REGION="$BINARYLANE_REGION" PLAN="$BINARYLANE_PLAN" IMAGE="$BINARYLANE_IMAGE"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --cloudflare-tunnel) CF_TUNNEL=true; shift ;;
    --cloudflare-hostname|--hostname) CF_HOSTNAME="$2"; shift 2 ;;
    --cloudflare-proxy) CF_PROXY="$2"; shift 2 ;;
    --enable-tls) ENABLE_TLS=true; shift ;;
    --letsencrypt-email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
    --skip-lamp) SKIP_LAMP=true; shift ;;
    --skip-mysql) SKIP_MYSQL=true; shift ;;
    --db-only) DB_ONLY=true; shift ;;
    --db-allow-from) DB_ALLOW_FROM="$2"; shift 2 ;;
    --skip-harden) SKIP_HARDEN=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[ -n "$NAME" ] || die "--name is required"
validate_server_name "$NAME"
[ -n "$DOMAIN" ] && SERVER_DOMAIN="$DOMAIN"
FQDN="$(fqdn_for "$NAME")"

if $CF_TUNNEL && [ -z "$CF_HOSTNAME" ]; then
  die "--cloudflare-tunnel requires --cloudflare-hostname (or --hostname) — the base FQDN ($FQDN) always stays a plain DNS-only A record for reliable SSH; the tunnel needs its own distinct public hostname to avoid an A/CNAME conflict on the same name."
fi
if [ "$CF_HOSTNAME" = "$FQDN" ]; then
  die "--cloudflare-hostname must differ from the server's own FQDN ($FQDN) — that name is reserved for the DNS-only SSH/admin A record."
fi
case "$CF_PROXY" in on|off) ;; *) die "--cloudflare-proxy must be 'on' or 'off'" ;; esac

if $DB_ONLY; then
  [ -n "$DB_ALLOW_FROM" ] || die "--db-only requires --db-allow-from <ip[,ip...]> — who's allowed to reach MySQL"
  $SKIP_MYSQL && die "--skip-mysql and --db-only are mutually exclusive (--db-only always installs MySQL, just without Apache/PHP)"
  $ENABLE_TLS && die "--enable-tls doesn't apply to --db-only servers (no Apache/certbot installed) — drop it"
  SKIP_LAMP=true
fi

# ---------------------------------------------------------------------------
# Phase 6: duplicate / safety checks
# ---------------------------------------------------------------------------
if state_exists "$NAME" && ! $DRY_RUN; then
  EXISTING_STATUS="$(state_read_field "$NAME" '.status')"
  if [ "$EXISTING_STATUS" != "DESTROYED" ]; then
    die "Local state already has a server named '$NAME' (status: $EXISTING_STATUS). Use server-status.sh to inspect, or destroy-server.sh first."
  fi
  warn "Local state shows '$NAME' was previously DESTROYED — proceeding will create a new record."
fi

load_binarylane_key
log "Checking BinaryLane for an existing server named '$FQDN'..."
BL_LIST="$(bl_api GET "/servers?per_page=200")" || die "Could not list BinaryLane servers"
BL_MATCH="$(echo "$BL_LIST" | jq -r --arg n "$FQDN" '.servers[] | select(.name == $n) | .id' | head -1)"
if [ -n "$BL_MATCH" ]; then
  die "A BinaryLane server named '$FQDN' already exists (id $BL_MATCH). Refusing to proceed — this may be an existing unmanaged resource. Investigate manually before reusing this name."
fi

load_cloudflare_creds
if [ -n "$DOMAIN" ]; then
  log "Resolving Cloudflare zone ID for custom domain '$DOMAIN'..."
  CLOUDFLARE_ZONE_ID="$(resolve_zone_id_for_domain "$DOMAIN")" || exit 1
  log "Zone ID: $CLOUDFLARE_ZONE_ID"
fi
log "Checking Cloudflare for an existing DNS record for '$FQDN'..."
CF_EXISTING="$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${FQDN}")" || die "Cloudflare DNS lookup failed"
CF_EXISTING_COUNT="$(echo "$CF_EXISTING" | jq -r '.result_info.count')"
if [ "$CF_EXISTING_COUNT" != "0" ]; then
  # Only acceptable if it's a record this toolkit created previously (tracked in state) and now destroyed/reprovisioning.
  KNOWN_RECORD_ID="$(state_exists "$NAME" && state_read_field "$NAME" '.cloudflare.dns_record_id // empty' || true)"
  CF_RECORD_ID="$(echo "$CF_EXISTING" | jq -r '.result[0].id')"
  if [ "$KNOWN_RECORD_ID" != "$CF_RECORD_ID" ]; then
    die "A Cloudflare DNS record for '$FQDN' already exists (id $CF_RECORD_ID) and is not tracked by this toolkit's state. Refusing to overwrite an unknown record — investigate manually."
  fi
  warn "Existing DNS record $CF_RECORD_ID belongs to a previously-tracked (destroyed) server with this name — it will be updated, not duplicated."
fi

# ---------------------------------------------------------------------------
# Resolve BinaryLane region/plan/image to confirm they're valid before spending money
# ---------------------------------------------------------------------------
REGIONS_JSON="$(bl_api GET "/regions")" || die "Could not list regions"
echo "$REGIONS_JSON" | jq -e --arg r "$REGION" '.regions[] | select(.slug == $r and .available == true)' >/dev/null \
  || die "Region '$REGION' is not a valid/available BinaryLane region slug"

# Build the ordered region-attempt list: the requested/default region first,
# then the rest of the fallback chain (deduplicated), for use if the primary
# region has no host capacity ("Unable to find a suitable host" — a real,
# observed BinaryLane condition, not something our config controls).
REGION_ATTEMPTS=("$REGION")
for r in $BINARYLANE_REGION_FALLBACK; do
  [[ " ${REGION_ATTEMPTS[*]} " == *" $r "* ]] && continue
  if echo "$REGIONS_JSON" | jq -e --arg r "$r" '.regions[] | select(.slug == $r and .available == true)' >/dev/null; then
    REGION_ATTEMPTS+=("$r")
  fi
done

SIZES_JSON="$(bl_api GET "/sizes")" || die "Could not list sizes"
SIZE_INFO="$(echo "$SIZES_JSON" | jq -c --arg p "$PLAN" '.sizes[] | select(.slug == $p)')"
[ -n "$SIZE_INFO" ] || die "Plan/size '$PLAN' is not a valid BinaryLane size slug"
echo "$SIZE_INFO" | jq -e '.available == true' >/dev/null || die "Plan '$PLAN' is not currently available"
PLAN_MEM="$(echo "$SIZE_INFO" | jq -r '.memory')"
PLAN_DISK="$(echo "$SIZE_INFO" | jq -r '.disk')"
PLAN_VCPUS="$(echo "$SIZE_INFO" | jq -r '.vcpus')"
PLAN_PRICE="$(echo "$SIZE_INFO" | jq -r '.price_monthly')"

IMAGES_JSON="$(bl_api GET "/images?per_page=200")" || die "Could not list images"
IMAGE_INFO="$(echo "$IMAGES_JSON" | jq -c --arg i "$IMAGE" '.images[] | select(.slug == $i)')"
[ -n "$IMAGE_INFO" ] || die "Image '$IMAGE' is not a valid BinaryLane image slug"
IMAGE_ID="$(echo "$IMAGE_INFO" | jq -r '.id')"
IMAGE_FULLNAME="$(echo "$IMAGE_INFO" | jq -r '.full_name')"
REMOTE_ACCESS_USER="$(echo "$IMAGE_INFO" | jq -r '.distribution_info.remote_access_user')"

# ---------------------------------------------------------------------------
# Ensure provisioning SSH key exists locally + is uploaded to BinaryLane
# ---------------------------------------------------------------------------
[ -f "${PROVISIONING_SSH_KEY}.pub" ] || die "Provisioning public key not found at ${PROVISIONING_SSH_KEY}.pub — generate it first with: ssh-keygen -t ed25519 -f ${PROVISIONING_SSH_KEY} -N ''"
SSH_PUBLIC_KEY="$(cat "${PROVISIONING_SSH_KEY}.pub")"
SSH_FINGERPRINT="$(ssh-keygen -lf "${PROVISIONING_SSH_KEY}.pub" | awk '{print $2}')"
# BinaryLane's API reports key fingerprints in legacy MD5 colon-hex format, not
# OpenSSH's modern SHA256 default — needed separately to match existing keys.
SSH_FINGERPRINT_MD5="$(ssh-keygen -E md5 -lf "${PROVISIONING_SSH_KEY}.pub" | awk '{print $2}' | sed 's/^MD5://')"

# ---------------------------------------------------------------------------
# Print the plan and stop for confirmation
# ---------------------------------------------------------------------------
if $DB_ONLY; then
  ROLE_LINE="Database only (standalone MySQL — ufw-restricted to: $DB_ALLOW_FROM)"
  LAMP_LINE="N/A — standalone MySQL install instead (see Server Role above)"
elif $SKIP_LAMP; then
  ROLE_LINE="Base OS only (--skip-lamp)"
  LAMP_LINE="Skipped"
elif $SKIP_MYSQL; then
  ROLE_LINE="Web/App (Apache + PHP, no local MySQL — expects a remote --db-only server)"
  LAMP_LINE="Apache 2 + PHP 8.3 + Composer + certbot (--skip-mysql: no local MySQL)"
else
  ROLE_LINE="Web/App (full LAMP)"
  LAMP_LINE="Apache 2 + MySQL 8 + PHP 8.3 + Composer + certbot (matches reference baseline)"
fi

cat <<PLAN

============================================================
Provisioning Plan
============================================================
Server Name:        $NAME
Server Role:         $ROLE_LINE
FQDN (SSH/admin):    $FQDN
BinaryLane Region:   $REGION $( [ "${#REGION_ATTEMPTS[@]}" -gt 1 ] && echo "(falls back to: ${REGION_ATTEMPTS[*]:1} if no host capacity)" )
BinaryLane Plan:     $PLAN  (RAM: ${PLAN_MEM}MB, Disk: ${PLAN_DISK}GB, vCPU: ${PLAN_VCPUS}, ~\$${PLAN_PRICE}/mo)
BinaryLane Image:    $IMAGE ($IMAGE_FULLNAME, id $IMAGE_ID)
Initial SSH user:    $REMOTE_ACCESS_USER (image default; cloud-init then creates '$ADMIN_USER' with sudo + key auth)
Admin User:          $ADMIN_USER
Timezone:            $TIMEZONE
Provisioning Key:    ${PROVISIONING_SSH_KEY}.pub (fingerprint $SSH_FINGERPRINT)

Cloudflare DNS (base, always DNS-only A record for SSH):
  $FQDN -> <public IPv4 once allocated>
  Proxy: $CF_PROXY $( [ "$CF_PROXY" = "on" ] && echo "  *** WARNING: proxied A record will break direct SSH by hostname; use the raw IP or ssh-server.sh --ip ***" )

Cloudflare Tunnel:   $( $CF_TUNNEL && echo "ENABLED — dedicated per-server tunnel ('${NAME}-tunnel', created or reused this run)" || echo "Disabled" )
$( $CF_TUNNEL && echo "  Public hostname: $CF_HOSTNAME (proxied CNAME once the tunnel is created)" )
$( $CF_TUNNEL && echo "  cloudflared will be installed on the new server itself, with only its own connector token" )

LAMP install:        $LAMP_LINE
Hardening:            $( $SKIP_HARDEN && echo "Skipped" || echo "Key-only SSH, root login disabled, ufw, fail2ban, unattended-upgrades" )
Let's Encrypt (base FQDN): $( $ENABLE_TLS && echo "Enabled — real cert for $FQDN, only attempted if DNS has actually propagated" || echo "Disabled" )
============================================================

PLAN

if $DRY_RUN; then
  log "Dry run — no chargeable action taken."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Proceed with creating this BinaryLane server? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Upload SSH key to BinaryLane if not already present (match by fingerprint)
# ---------------------------------------------------------------------------
BL_KEYS_JSON="$(bl_api GET "/account/keys")" || die "Could not list BinaryLane SSH keys"
BL_KEY_ID="$(echo "$BL_KEYS_JSON" | jq -r --arg fp "$SSH_FINGERPRINT_MD5" '.ssh_keys[] | select(.fingerprint == $fp) | .id' | head -1)"
if [ -z "$BL_KEY_ID" ]; then
  log "Uploading provisioning SSH key to BinaryLane account"
  KEY_PAYLOAD="$(jq -n --arg name "binarylane-provisioning-controlhost" --arg key "$SSH_PUBLIC_KEY" '{name:$name, public_key:$key, default:false}')"
  KEY_RESULT="$(bl_api POST "/account/keys" "$KEY_PAYLOAD")" || die "Failed to upload SSH key"
  BL_KEY_ID="$(echo "$KEY_RESULT" | jq -r '.ssh_key.id')"
else
  log "Provisioning SSH key already registered on BinaryLane (id $BL_KEY_ID)"
fi

# ---------------------------------------------------------------------------
# Phase 7: create the server
# ---------------------------------------------------------------------------
CLOUD_INIT="$(SHORT_NAME="$NAME" FQDN="$FQDN" ADMIN_USER="$ADMIN_USER" TIMEZONE="$TIMEZONE" SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" \
  envsubst '$SHORT_NAME $FQDN $ADMIN_USER $TIMEZONE $SSH_PUBLIC_KEY' < "$HERE/templates/cloud-init.yaml.tmpl")"

SERVER_ID=""
for TRY_REGION in "${REGION_ATTEMPTS[@]}"; do
  log "Creating BinaryLane server '$FQDN' in region '$TRY_REGION'..."
  CREATE_PAYLOAD="$(jq -n \
    --arg name "$FQDN" --arg region "$TRY_REGION" --arg size "$PLAN" --argjson image "$IMAGE_ID" \
    --argjson key_id "$BL_KEY_ID" --arg userdata "$CLOUD_INIT" \
    '{name:$name, region:$region, size:$size, image:$image, ssh_keys:[$key_id], user_data:$userdata, backups:false, ipv6:false}')"
  TMP_BODY="$(mktemp)"
  HTTP_STATUS="$(curl -s -o "$TMP_BODY" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $BINARYLANE_API_KEY" -H "Content-Type: application/json" \
    -d "$CREATE_PAYLOAD" "$BL_API_BASE/servers")"
  log "BinaryLane API POST /servers ($TRY_REGION) -> HTTP $HTTP_STATUS"
  if [ "$HTTP_STATUS" -lt 400 ]; then
    CREATE_RESULT="$(cat "$TMP_BODY")"; rm -f "$TMP_BODY"
    SERVER_ID="$(echo "$CREATE_RESULT" | jq -r '.server.id // empty')"
    [ -n "$SERVER_ID" ] || die "Could not determine new server ID from API response"
    REGION="$TRY_REGION"
    log "Server created: id=$SERVER_ID (region: $REGION)"
    break
  fi
  ERR_DETAIL="$(jq -r '.detail // .message // empty' "$TMP_BODY" 2>/dev/null)"
  rm -f "$TMP_BODY"
  if echo "$ERR_DETAIL" | grep -qi "suitable host"; then
    warn "No host capacity in '$TRY_REGION': $ERR_DETAIL — trying next region if any remain"
    continue
  else
    die "Server creation failed in '$TRY_REGION' with a non-capacity error: ${ERR_DETAIL:-<no detail>}"
  fi
done
[ -n "$SERVER_ID" ] || die "No BinaryLane host capacity in any of: ${REGION_ATTEMPTS[*]}. Try again later."

# Write initial (partial) state immediately so we don't lose track of a billed resource
NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq -n \
  --arg name "$NAME" --arg fqdn "$FQDN" --argjson server_id "$SERVER_ID" \
  --arg region "$REGION" --arg plan "$PLAN" --argjson image_id "$IMAGE_ID" \
  --arg created "$NOW" --arg status "CREATING" \
  '{name:$name, fqdn:$fqdn, binarylane_server_id:$server_id, region:$region, plan:$plan, image_id:$image_id, created_at:$created, status:$status}')"

# ---------------------------------------------------------------------------
# Poll until active with a public IPv4
# ---------------------------------------------------------------------------
log "Waiting for server to become active with a public IPv4 (this can take a few minutes)..."
PUBLIC_IP=""
for i in $(seq 1 60); do
  sleep 10
  SRV="$(bl_api GET "/servers/$SERVER_ID")" || continue
  STATUS="$(echo "$SRV" | jq -r '.server.status')"
  PUBLIC_IP="$(echo "$SRV" | jq -r '.server.networks.v4[]? | select(.type=="public") | .ip_address' | head -1)"
  log "  status=$STATUS ip=${PUBLIC_IP:-<none yet>} (check $i/60)"
  if [ "$STATUS" = "active" ] && [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
    break
  fi
done
[ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ] || die "Server did not reach active status with a public IPv4 in time. Check BinaryLane dashboard for server id $SERVER_ID before retrying."

log "Server active. Public IPv4: $PUBLIC_IP"

# ---------------------------------------------------------------------------
# Phase 8: Cloudflare DNS — base FQDN, always DNS-only A record
# ---------------------------------------------------------------------------
log "Creating/updating Cloudflare A record for $FQDN -> $PUBLIC_IP"
CF_PROXIED_BOOL="false"; [ "$CF_PROXY" = "on" ] && CF_PROXIED_BOOL="true"
EXISTING_A="$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=A&name=${FQDN}")" || die "Cloudflare DNS lookup failed"
A_RECORD_ID="$(echo "$EXISTING_A" | jq -r '.result[0].id // empty')"
A_PAYLOAD="$(jq -n --arg fqdn "$FQDN" --arg ip "$PUBLIC_IP" --argjson proxied "$CF_PROXIED_BOOL" '{type:"A", name:$fqdn, content:$ip, proxied:$proxied, ttl:1}')"
if [ -n "$A_RECORD_ID" ]; then
  cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${A_RECORD_ID}" "$A_PAYLOAD" >/dev/null || die "Failed to update A record"
else
  A_RESULT="$(cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "$A_PAYLOAD")" || die "Failed to create A record"
  A_RECORD_ID="$(echo "$A_RESULT" | jq -r '.result.id')"
fi
log "A record id: $A_RECORD_ID"

# Incremental state save — so a failure anywhere after this point still lets
# destroy-server.sh find and clean up the IP, and this DNS record, correctly.
state_write "$NAME" "$(jq -n \
  --arg name "$NAME" --arg fqdn "$FQDN" --argjson server_id "$SERVER_ID" \
  --arg region "$REGION" --arg plan "$PLAN" --argjson image_id "$IMAGE_ID" \
  --arg created "$NOW" --arg status "CREATING" --arg ip "$PUBLIC_IP" \
  --arg zone_id "$CLOUDFLARE_ZONE_ID" --arg a_record_id "$A_RECORD_ID" \
  '{name:$name, fqdn:$fqdn, binarylane_server_id:$server_id, region:$region, plan:$plan, image_id:$image_id,
    created_at:$created, status:$status, public_ipv4:$ip,
    cloudflare:{zone_id:$zone_id, dns_record_id:$a_record_id, tunnel_enabled:false}}')"

log "Verifying DNS resolution for $FQDN..."
DNS_OK=false
for i in $(seq 1 12); do
  RESOLVED="$(dig +short "$FQDN" @1.1.1.1 2>/dev/null | tail -1)"
  if [ "$RESOLVED" = "$PUBLIC_IP" ]; then DNS_OK=true; break; fi
  sleep 5
done
$DNS_OK && log "DNS resolves correctly ($FQDN -> $PUBLIC_IP)" || warn "DNS did not confirm resolution within 60s (Cloudflare API record is correct; propagation may just be slow)"

# ---------------------------------------------------------------------------
# Wait for SSH as the admin user (cloud-init creates it at first boot)
# ---------------------------------------------------------------------------
SSH_OPTS=(-i "$PROVISIONING_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MULTIPLEX_OPTS[@]}")
log "Waiting for SSH as $ADMIN_USER@$PUBLIC_IP (cloud-init needs to finish first)..."
SSH_OK=false
for i in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'test -f /var/log/provisioning-bootstrap-done' 2>/dev/null; then
    SSH_OK=true; break
  fi
  sleep 15
done
$SSH_OK || die "Could not establish SSH as $ADMIN_USER within the timeout. Server id=$SERVER_ID, ip=$PUBLIC_IP — investigate via BinaryLane console before retrying."
log "SSH confirmed as $ADMIN_USER."

# Second independent session, per hardening safety requirement, before we let harden-ssh.sh touch sshd.
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'echo second-session-ok' >/dev/null 2>&1 \
  || die "Second SSH session check failed — refusing to run hardening. Investigate before retrying."
log "Second SSH session confirmed — safe to proceed with hardening."

# ---------------------------------------------------------------------------
# Harden — staged in two steps, each externally verified before the next
# runs, so a lockout is caught immediately after the specific change that
# caused it rather than after several entangled firewall/ssh changes.
# ---------------------------------------------------------------------------
if ! $SKIP_HARDEN; then
  MANAGEMENT_IP="$(dig +short "$MANAGEMENT_SSH_HOSTNAME" @1.1.1.1 2>/dev/null | tail -1)"
  if [ -n "$MANAGEMENT_IP" ]; then
    log "Resolved management hostname $MANAGEMENT_SSH_HOSTNAME -> $MANAGEMENT_IP (will get an explicit ufw allow + fail2ban ignoreip)"
  else
    warn "Could not resolve $MANAGEMENT_SSH_HOSTNAME — proceeding without an explicit management-IP allow rule"
  fi

  log "Stage 1/2: SSH + firewall hardening..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/harden-ssh.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/harden-ssh.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/harden-ssh.sh && /tmp/harden-ssh.sh '$MANAGEMENT_IP' && rm -f /tmp/harden-ssh.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'echo post-ssh-hardening-ok' >/dev/null 2>&1 \
    || die "SSH broke after the SSH/firewall hardening stage! Server id=$SERVER_ID ip=$PUBLIC_IP — use the BinaryLane console/recovery. (fail2ban was NOT yet touched, so the cause is in sshd_config or ufw.)"
  log "Stage 1/2 complete; SSH still reachable."

  log "Stage 2/2: fail2ban..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/harden-fail2ban.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/harden-fail2ban.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/harden-fail2ban.sh && /tmp/harden-fail2ban.sh '$MANAGEMENT_IP' && rm -f /tmp/harden-fail2ban.sh"
  ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'echo post-fail2ban-hardening-ok' >/dev/null 2>&1 \
    || die "SSH broke after the fail2ban stage! Server id=$SERVER_ID ip=$PUBLIC_IP — SSH/ufw were confirmed fine, so this isolates fail2ban as the cause. Use the BinaryLane console/recovery."
  log "Stage 2/2 complete; SSH still reachable."
fi

# ---------------------------------------------------------------------------
# LAMP install, or standalone MySQL for --db-only servers
# ---------------------------------------------------------------------------
LAMP_VERSIONS="" MYSQL_INSTALL_OUT="" DB_CREDS_DISPLAY=""
if $DB_ONLY; then
  log "Installing standalone MySQL (db-only server, restricted to: $DB_ALLOW_FROM)..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-mysql-standalone.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/install-mysql-standalone.sh"
  MYSQL_INSTALL_OUT="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/install-mysql-standalone.sh && /tmp/install-mysql-standalone.sh '$DB_ALLOW_FROM' && rm -f /tmp/install-mysql-standalone.sh")"
  log "Standalone MySQL install complete."
  DB_CREDS_DISPLAY="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'sudo cat /etc/mysql-provisioning-credentials.env')" \
    || warn "Could not retrieve DB credentials for display — check manually via SSH: sudo cat /etc/mysql-provisioning-credentials.env"
elif ! $SKIP_LAMP; then
  log "Running install-lamp.sh remotely (this takes a few minutes)..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-lamp.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/install-lamp.sh"
  LAMP_VERSIONS="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/install-lamp.sh && /tmp/install-lamp.sh '$FQDN' '$SKIP_MYSQL' && rm -f /tmp/install-lamp.sh")"
  log "LAMP install complete."
fi

# ---------------------------------------------------------------------------
# Cloudflare Tunnel (optional) — dedicated tunnel for this server, orchestrated
# from the control host: creates the tunnel via API, installs cloudflared on the remote
# server with only its own connector token, and wires the DNS CNAME.
# ---------------------------------------------------------------------------
TUNNEL_RECORD_ID="" DEDICATED_TUNNEL_ID="" TUNNEL_ZONE_ID=""
if $CF_TUNNEL; then
  log "Provisioning dedicated Cloudflare Tunnel for $CF_HOSTNAME -> $PUBLIC_IP ..."
  TUNNEL_OUT="$("$HERE/scripts/install-cloudflare-tunnel.sh" "$NAME" "$CF_HOSTNAME" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY")" || die "Cloudflare Tunnel provisioning failed"
  DEDICATED_TUNNEL_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ID=' | cut -d= -f2)"
  TUNNEL_RECORD_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_RECORD_ID=' | cut -d= -f2)"
  TUNNEL_ZONE_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ZONE_ID=' | cut -d= -f2)"
  log "Tunnel ready: id=$DEDICATED_TUNNEL_ID, DNS record id=$TUNNEL_RECORD_ID, zone id=$TUNNEL_ZONE_ID"
fi

# ---------------------------------------------------------------------------
# HTTP test (skipped for --db-only servers — no web server to test)
# ---------------------------------------------------------------------------
HTTP_OK=false HTTP_CODE=""
if ! $DB_ONLY; then
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$PUBLIC_IP/" || true)"
  [ "$HTTP_CODE" = "200" ] && HTTP_OK=true
  log "HTTP test (direct IP): $HTTP_CODE"
fi

# ---------------------------------------------------------------------------
# Let's Encrypt (optional) — base FQDN only. Never the tunnel hostname: that
# already terminates TLS at Cloudflare's edge, and the ACME HTTP-01 challenge
# needs to reach this server directly the way only the DNS-only base A
# record does. Requires DNS to have actually propagated — a real HTTP-01
# challenge from Let's Encrypt's servers needs the hostname to resolve
# publicly, not just "the Cloudflare API says the record exists".
# ---------------------------------------------------------------------------
TLS_OK=false TLS_SKIPPED_REASON=""
if $ENABLE_TLS; then
  if $SKIP_LAMP; then
    TLS_SKIPPED_REASON="--skip-lamp was used (no Apache/certbot installed)"
  elif ! $DNS_OK; then
    TLS_SKIPPED_REASON="DNS for $FQDN had not confirmed propagation — run manually once it has: ssh-server.sh $NAME -- sudo certbot --apache -d $FQDN --agree-tos --redirect"
  else
    log "Requesting Let's Encrypt certificate for $FQDN..."
    scp "${SSH_OPTS[@]}" "$HERE/scripts/install-certbot.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/install-certbot.sh"
    if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" "chmod +x /tmp/install-certbot.sh && /tmp/install-certbot.sh '$FQDN' '$LETSENCRYPT_EMAIL' && rm -f /tmp/install-certbot.sh"; then
      HTTPS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$FQDN/" || true)"
      if [ "$HTTPS_CODE" = "200" ]; then
        TLS_OK=true
        log "HTTPS confirmed working: https://$FQDN/ -> $HTTPS_CODE"
      else
        TLS_SKIPPED_REASON="certbot reported success but the HTTPS check got '$HTTPS_CODE' — inspect manually"
      fi
    else
      TLS_SKIPPED_REASON="certbot failed — check 'sudo certbot certificates' and /var/log/letsencrypt/letsencrypt.log on the server"
    fi
  fi
  $TLS_OK || warn "Let's Encrypt skipped/failed: $TLS_SKIPPED_REASON"
fi

# ---------------------------------------------------------------------------
# Reboot test
# ---------------------------------------------------------------------------
log "Rebooting server to verify services restart automatically..."
ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'sudo reboot' >/dev/null 2>&1 || true
sleep 20
REBOOT_OK=false
for i in $(seq 1 20); do
  if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'echo reboot-ok' >/dev/null 2>&1; then
    REBOOT_OK=true; break
  fi
  sleep 10
done
if $REBOOT_OK; then
  log "SSH reachable after reboot."
  if ! $DB_ONLY; then
    POST_REBOOT_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$PUBLIC_IP/" || true)"
    log "HTTP after reboot: $POST_REBOOT_HTTP"
  else
    MYSQL_REBOOT_STATUS="$(ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$PUBLIC_IP" 'systemctl is-active mysql' 2>/dev/null || echo unknown)"
    log "MySQL after reboot: $MYSQL_REBOOT_STATUS"
  fi
  if $TLS_OK; then
    POST_REBOOT_HTTPS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$FQDN/" || true)"
    log "HTTPS after reboot: $POST_REBOOT_HTTPS"
  fi
else
  warn "Server did not come back up over SSH within the timeout after reboot — check manually."
fi

# ---------------------------------------------------------------------------
# Final state + provisioning record
# ---------------------------------------------------------------------------
FINAL_STATUS="Completed"
FINAL_NOW="$(date -Iseconds)"
ROLE="lamp"
$DB_ONLY && ROLE="db-only"
$SKIP_LAMP && ! $DB_ONLY && ROLE="base-os"
$SKIP_MYSQL && ! $DB_ONLY && ! $SKIP_LAMP && ROLE="web-no-local-db"
state_write "$NAME" "$(jq -n \
  --arg name "$NAME" --arg fqdn "$FQDN" --argjson server_id "$SERVER_ID" \
  --arg region "$REGION" --arg plan "$PLAN" --argjson image_id "$IMAGE_ID" \
  --arg created "$NOW" --arg updated "$FINAL_NOW" --arg status "$FINAL_STATUS" \
  --arg ip "$PUBLIC_IP" --arg fingerprint "$SSH_FINGERPRINT" \
  --arg zone_id "$CLOUDFLARE_ZONE_ID" --arg a_record_id "$A_RECORD_ID" \
  --argjson tunnel_enabled "$CF_TUNNEL" --arg tunnel_hostname "$CF_HOSTNAME" --arg tunnel_record_id "$TUNNEL_RECORD_ID" \
  --arg tunnel_id "$DEDICATED_TUNNEL_ID" --arg tunnel_zone_id "$TUNNEL_ZONE_ID" \
  --arg role "$ROLE" --argjson db_only "$DB_ONLY" --arg db_allow_from "$DB_ALLOW_FROM" \
  '{name:$name, fqdn:$fqdn, binarylane_server_id:$server_id, region:$region, plan:$plan, image_id:$image_id,
    created_at:$created, updated_at:$updated, status:$status, public_ipv4:$ip, ssh_key_fingerprint:$fingerprint,
    role:$role,
    cloudflare:{zone_id:$zone_id, dns_record_id:$a_record_id, tunnel_enabled:$tunnel_enabled, tunnel_hostname:$tunnel_hostname, tunnel_dns_record_id:$tunnel_record_id, tunnel_id:$tunnel_id, tunnel_zone_id:$tunnel_zone_id},
    mysql:{db_only:$db_only, allowed_from:$db_allow_from, credentials_file:(if $db_only then "/etc/mysql-provisioning-credentials.env" else null end)}}')"

RECORD="$(record_file "$NAME")"
{
  echo "============================================================"
  echo "Provisioned Server Record"
  echo "============================================================"
  echo
  echo "Server Name:"; echo "$NAME"; echo
  echo "Server Role:"; echo "$ROLE_LINE"; echo
  echo "FQDN:"; echo "$FQDN"; echo
  echo "Provider:"; echo "BinaryLane"; echo
  echo "BinaryLane Server ID:"; echo "$SERVER_ID"; echo
  echo "BinaryLane Region:"; echo "$REGION"; echo
  echo "BinaryLane Plan:"; echo "$PLAN"; echo
  echo "CPU:"; echo "$PLAN_VCPUS"; echo
  echo "RAM:"; echo "${PLAN_MEM} MB"; echo
  echo "Disk:"; echo "${PLAN_DISK} GB"; echo
  echo "Operating System:"; echo "$IMAGE_FULLNAME"; echo
  echo "BinaryLane Image ID:"; echo "$IMAGE_ID"; echo
  echo "Public IPv4:"; echo "$PUBLIC_IP"; echo
  echo "Public IPv6:"; echo "Not Configured"; echo
  echo "Created:"; echo "$NOW"; echo
  echo "Provisioned From:"; echo "control-host"; echo
  echo "Provisioning User:"; echo "$(whoami)"; echo
  echo
  echo "============================================================"
  echo "SSH"
  echo "============================================================"
  echo
  echo "Administrative User:"; echo "$ADMIN_USER"; echo
  echo "SSH Host:"; echo "$FQDN"; echo
  echo "SSH Port:"; echo "22"; echo
  echo "SSH Key:"; echo "$PROVISIONING_SSH_KEY"; echo
  echo "SSH Public Key Fingerprint:"; echo "$SSH_FINGERPRINT"; echo
  echo "SSH Command:"; echo "ssh -i $PROVISIONING_SSH_KEY $ADMIN_USER@$FQDN"; echo
  echo "Password Authentication:"; echo "$($SKIP_HARDEN && echo 'Enabled (hardening skipped)' || echo 'Disabled')"; echo
  echo "Root SSH:"; echo "$($SKIP_HARDEN && echo 'Enabled (hardening skipped)' || echo 'Disabled')"; echo
  echo
  echo "============================================================"
  echo "Cloudflare"
  echo "============================================================"
  echo
  echo "Cloudflare Zone:"; echo "$SERVER_DOMAIN"; echo
  echo "Cloudflare Zone ID:"; echo "$CLOUDFLARE_ZONE_ID"; echo
  echo "DNS Record:"; echo "$FQDN"; echo
  echo "DNS Record Type:"; echo "A"; echo
  echo "DNS Record ID:"; echo "$A_RECORD_ID"; echo
  echo "DNS Target:"; echo "$PUBLIC_IP"; echo
  echo "Cloudflare Proxy:"; echo "$( [ "$CF_PROXY" = "on" ] && echo Proxied || echo "DNS Only" )"; echo
  echo "Cloudflare Tunnel:"; echo "$( $CF_TUNNEL && echo Enabled || echo Disabled )"; echo
  echo "Cloudflare Tunnel ID:"; echo "$( $CF_TUNNEL && echo "$DEDICATED_TUNNEL_ID" || echo 'Not Configured' )"; echo
  echo "Cloudflare Tunnel Hostname:"; echo "$( $CF_TUNNEL && echo "$CF_HOSTNAME" || echo 'Not Configured' )"; echo
  echo "Cloudflare Tunnel DNS Record ID:"; echo "$( $CF_TUNNEL && echo "$TUNNEL_RECORD_ID" || echo 'Not Configured' )"; echo
  echo
  echo "============================================================"
  echo "TLS (base FQDN — the tunnel hostname, if any, uses Cloudflare's edge TLS instead)"
  echo "============================================================"
  echo
  echo "Let's Encrypt:"; echo "$( $TLS_OK && echo "Enabled — https://$FQDN/" || echo "Not enabled${TLS_SKIPPED_REASON:+ ($TLS_SKIPPED_REASON)}" )"; echo
  echo
  echo "============================================================"
  echo "Services"
  echo "============================================================"
  echo
  echo "Apache:"; echo "$( { $SKIP_LAMP || $DB_ONLY; } && echo 'Not Installed' || echo 'Installed / Running' )"; echo
  if $DB_ONLY; then
    echo "MySQL (standalone):"; echo "$MYSQL_INSTALL_OUT"
    echo "MySQL allowed from (ufw):"; echo "$DB_ALLOW_FROM"; echo
    echo "MySQL port:"; echo "3306"; echo
    echo "MySQL credentials:"; echo "See /etc/mysql-provisioning-credentials.env (mode 600) on this server — displayed once in the provisioning terminal output, never stored in this record or in local state/${NAME}.json"; echo
  else
    echo "PHP / MySQL / Composer:"; echo "$LAMP_VERSIONS"
  fi
  echo "UFW:"; echo "$( $SKIP_HARDEN && echo 'Not Configured' || echo Enabled )"; echo
  echo "Fail2ban:"; echo "$( $SKIP_HARDEN && echo 'Not Configured' || echo Enabled )"; echo
  echo "Unattended Upgrades:"; echo "Enabled"; echo
  echo "cloudflared (on this server, dedicated tunnel):"; echo "$( $CF_TUNNEL && echo 'Installed / Running' || echo 'Not Installed' )"; echo
  echo
  echo "============================================================"
  echo "Provisioning"
  echo "============================================================"
  echo
  echo "Provisioning Toolkit:"; echo "$HERE"; echo
  echo "Provisioning Status:"; echo "$FINAL_STATUS"; echo
  echo "Initial SSH Test:"; echo "$($SSH_OK && echo Passed || echo Failed)"; echo
  echo "HTTP Test:"; echo "$( $DB_ONLY && echo "N/A (db-only server)" || ( $HTTP_OK && echo Passed || echo "Failed (code $HTTP_CODE)" ) )"; echo
  echo "DNS Test:"; echo "$($DNS_OK && echo Passed || echo "Not confirmed within timeout")"; echo
  echo "Reboot Test:"; echo "$($REBOOT_OK && echo Passed || echo Failed)"; echo
  echo "Last Provisioning Update:"; echo "$FINAL_NOW"; echo
  echo "Notes:"; echo "Created by server-provisioning toolkit."; echo
} > "$RECORD"
chmod 600 "$RECORD"

cat <<SUMMARY

============================================================
Provisioning complete: $FQDN
============================================================
Server Role:              $ROLE_LINE
BinaryLane Server ID:   $SERVER_ID
Public IPv4:             $PUBLIC_IP
Region / Plan:           $REGION / $PLAN
Image:                    $IMAGE_FULLNAME
Cloudflare DNS Record:   $A_RECORD_ID ($( [ "$CF_PROXY" = "on" ] && echo Proxied || echo "DNS Only" ))
Cloudflare Tunnel:        $( $CF_TUNNEL && echo "Enabled ($CF_HOSTNAME)" || echo Disabled )
Let's Encrypt:            $( $TLS_OK && echo "https://$FQDN/" || echo "Not enabled" )
SSH Command:              ssh -i $PROVISIONING_SSH_KEY $ADMIN_USER@$FQDN
Provisioning Record:      $RECORD
============================================================
SUMMARY

if $DB_ONLY; then
cat <<CREDS
MySQL credentials (shown once — also stored at /etc/mysql-provisioning-credentials.env,
mode 600, root-only, on $FQDN itself. Not written anywhere on the control host.)
============================================================
$DB_CREDS_DISPLAY
============================================================
Connect from an allowed host: mysql -h $PUBLIC_IP -u <DB_USER> -p <DB_NAME>
Allowed client IP(s):  $DB_ALLOW_FROM
CREDS
fi
