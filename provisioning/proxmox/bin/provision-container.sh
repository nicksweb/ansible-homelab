#!/usr/bin/env bash
# Provision a new Ubuntu Proxmox LXC container.
#
# Usage:
#   provision-container.sh --hostname host001 [options]
#
# Options:
#   --hostname NAME     Logical hostname (default: auto-pick next hostNNN). FQDN = NAME.<INTERNAL_DOMAIN>
#   --cores N           vCPUs (default: config DEFAULT_CORES)
#   --memory MB         RAM in MB (default: config DEFAULT_MEMORY_MB)
#   --disk GB           Rootfs size in GB (default: config DEFAULT_DISK_GB)
#   --node NAME         Force a specific Proxmox node (default: auto-pick one with the template cached)
#   --vlan TAG           VLAN tag for the container's NIC (default: config PVE_VLAN_TAG, empty = native)
#   --public-hostname FQDN[,FQDN...]  Expose this container externally via a dedicated Cloudflare
#                            Tunnel. Accepts a comma-separated list to attach multiple public
#                            hostnames at creation time (any domain the Cloudflare token can see) —
#                            the first becomes the primary; the rest are added the same way
#                            add-vhost.sh adds one to an existing container (shared tunnel, own
#                            CNAME + local override + vhost each).
#   --enable-tls          Issue a real Let's Encrypt cert for the container's *internal* FQDN via
#                          DNS-01 (Cloudflare API) — works even though .in.example.com isn't
#                          publicly resolvable, since DNS-01 only needs to create a TXT record.
#   --skip-web            Don't install the minimal Apache test vhost (default: installed)
#   --skip-beszel          Don't install the Beszel monitoring agent (default: installed)
#   --dry-run            Print the plan and exit, no resources created
#   --yes                Skip the interactive confirmation prompt
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/cloudflare.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/udm.sh"
require_jq

HOSTNAME_ARG="" CORES="$DEFAULT_CORES" MEMORY="$DEFAULT_MEMORY_MB" DISK="$DEFAULT_DISK_GB"
NODE_ARG="" VLAN_TAG="$PVE_VLAN_TAG" PUBLIC_HOSTNAME_RAW="" ENABLE_TLS=false SKIP_WEB=false SKIP_BESZEL=false DRY_RUN=false ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOSTNAME_ARG="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --public-hostname) PUBLIC_HOSTNAME_RAW="$2"; shift 2 ;;
    --enable-tls) ENABLE_TLS=true; shift ;;
    --skip-web) SKIP_WEB=true; shift ;;
    --skip-beszel) SKIP_BESZEL=true; shift ;;
    --disk) DISK="${2%G}"; shift 2 ;;
    --node) NODE_ARG="$2"; shift 2 ;;
    --vlan) VLAN_TAG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Split --public-hostname on commas. PUBLIC_HOSTNAME (the first entry) drives
# every existing single-hostname code path below unchanged; anything after
# it is attached post-creation via the same add-vhost.sh logic used to add a
# hostname to an already-existing container — shared tunnel, own CNAME +
# local override + vhost each, not a second tunnel per hostname.
PUBLIC_HOSTNAMES=()
if [ -n "$PUBLIC_HOSTNAME_RAW" ]; then
  IFS=',' read -ra _raw_hosts <<< "$PUBLIC_HOSTNAME_RAW"
  for h in "${_raw_hosts[@]}"; do
    h="$(echo "$h" | xargs)"  # trim whitespace, e.g. "a.com, b.com"
    [ -n "$h" ] && PUBLIC_HOSTNAMES+=("$h")
  done
fi
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAMES[0]:-}"
ADDITIONAL_PUBLIC_HOSTNAMES=("${PUBLIC_HOSTNAMES[@]:1}")

load_proxmox_creds

# ---------------------------------------------------------------------------
# Auto-pick the next available hostNNN if none was given
# ---------------------------------------------------------------------------
if [ -z "$HOSTNAME_ARG" ]; then
  log "No --hostname given, auto-selecting next available hostNNN..."
  EXISTING_NAMES="$(pve_api GET "/cluster/resources?type=vm" | jq -r '.data[] | select(.type=="lxc") | .name' 2>/dev/null)"
  for n in $(seq -w 1 999); do
    CANDIDATE="host${n}"
    if ! echo "$EXISTING_NAMES" | grep -qx "$CANDIDATE" && ! state_exists "$CANDIDATE"; then
      HOSTNAME_ARG="$CANDIDATE"
      break
    fi
  done
  [ -n "$HOSTNAME_ARG" ] || die "Could not find a free hostNNN name"
  log "Selected hostname: $HOSTNAME_ARG"
fi

validate_hostname "$HOSTNAME_ARG"
FQDN="$(fqdn_for "$HOSTNAME_ARG")"

# ---------------------------------------------------------------------------
# Duplicate / safety checks
# ---------------------------------------------------------------------------
if state_exists "$HOSTNAME_ARG" && ! $DRY_RUN; then
  EXISTING_STATUS="$(state_read_field "$HOSTNAME_ARG" '.status')"
  if [ "$EXISTING_STATUS" != "DESTROYED" ]; then
    die "Local state already has a container named '$HOSTNAME_ARG' (status: $EXISTING_STATUS). Use destroy-container.sh first if you want to replace it."
  fi
  warn "Local state shows '$HOSTNAME_ARG' was previously DESTROYED — proceeding will create a new record."
fi

log "Checking Proxmox for an existing container named '$HOSTNAME_ARG'..."
EXISTING_LXC="$(pve_api GET "/cluster/resources?type=vm" | jq -r --arg n "$HOSTNAME_ARG" '.data[] | select(.type=="lxc" and .name==$n) | .vmid' | head -1)"
[ -z "$EXISTING_LXC" ] || die "A Proxmox LXC named '$HOSTNAME_ARG' already exists (VMID $EXISTING_LXC). Refusing to proceed — investigate manually before reusing this name."

log "Checking UDM Pro for an existing local DNS record for '$FQDN'..."
load_udm_creds
EXISTING_DNS="$(udm_api GET "/proxy/network/api/s/${UDM_SITE}/rest/user?limit=1000" | jq -r --arg f "$FQDN" '.data[] | select(.local_dns_record==$f) | .mac' | head -1)"
[ -z "$EXISTING_DNS" ] || die "A UDM local DNS record for '$FQDN' already exists (client MAC $EXISTING_DNS). Refusing to proceed — this may be an existing unmanaged reservation. Investigate manually before reusing this name."

if [ "${#PUBLIC_HOSTNAMES[@]}" -gt 0 ]; then
  log "Checking local state for existing containers already using any of: ${PUBLIC_HOSTNAMES[*]}..."
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    OTHER_NAME="$(jq -r '.name' "$f")"
    [ "$OTHER_NAME" = "$HOSTNAME_ARG" ] && continue
    OTHER_STATUS="$(jq -r '.status' "$f")"
    [ "$OTHER_STATUS" = "DESTROYED" ] && continue
    OTHER_PUBLIC="$(jq -r '.cloudflare.public_hostname // empty' "$f")"
    OTHER_ADDITIONAL="$(jq -r '.cloudflare.additional_hostnames[]?.hostname // empty' "$f")"
    for want in "${PUBLIC_HOSTNAMES[@]}"; do
      if [ "$OTHER_PUBLIC" = "$want" ] || printf '%s\n' "$OTHER_ADDITIONAL" | grep -qx "$want"; then
        die "'$want' is already in use by '$OTHER_NAME' (status: $OTHER_STATUS). Proceeding would silently steal its Cloudflare CNAME and local DNS override. Destroy '$OTHER_NAME' first, add this hostname to it with add-vhost.sh instead, or pick a different --public-hostname."
      fi
    done
  done
  # Also refuse duplicates within the list itself (e.g. --public-hostname a.com,a.com)
  DEDUPED_COUNT="$(printf '%s\n' "${PUBLIC_HOSTNAMES[@]}" | sort -u | wc -l)"
  [ "$DEDUPED_COUNT" -eq "${#PUBLIC_HOSTNAMES[@]}" ] || die "Duplicate hostname(s) in --public-hostname: ${PUBLIC_HOSTNAMES[*]}"
fi

# ---------------------------------------------------------------------------
# Pick a node: prefer one with the template already cached
# ---------------------------------------------------------------------------
if [ -n "$NODE_ARG" ]; then
  TARGET_NODE="$NODE_ARG"
else
  log "Selecting a node with the Ubuntu template already cached..."
  ONLINE_NODES="$(pve_api GET "/nodes" | jq -r '.data[] | select(.status=="online") | .node')"
  TARGET_NODE=""
  for n in $ONLINE_NODES; do
    if pve_api GET "/nodes/$n/storage/${PVE_TEMPLATE_STORAGE}/content?content=vztmpl" 2>/dev/null | jq -e --arg t "$PVE_TEMPLATE" '.data[] | select(.volid | endswith($t))' >/dev/null 2>&1; then
      TARGET_NODE="$n"
      break
    fi
  done
  if [ -z "$TARGET_NODE" ]; then
    TARGET_NODE="$(echo "$ONLINE_NODES" | head -1)"
    warn "Template not cached on any online node — will download it to '$TARGET_NODE'"
    pve_api POST "/nodes/$TARGET_NODE/aplinfo" "storage=${PVE_TEMPLATE_STORAGE}" "template=${PVE_TEMPLATE}" >/dev/null \
      || die "Template download failed on $TARGET_NODE"
    sleep 15
  fi
fi
log "Target node: $TARGET_NODE"

# ---------------------------------------------------------------------------
# VMID + MAC address
# ---------------------------------------------------------------------------
VMID="$(pve_api GET "/cluster/nextid" | jq -r '.data')"
[ -n "$VMID" ] && [ "$VMID" != "null" ] || die "Could not determine next VMID"
MAC_ADDR="$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"

# ---------------------------------------------------------------------------
# UDM Pro: DHCP reservation + local DNS record, created *before* the
# container so it gets the right IP and resolves correctly from its very
# first DHCP request — no lease-renewal wait needed.
# ---------------------------------------------------------------------------
RESERVED_IP="$(find_free_reservation_ip "$UDM_RESERVATION_RANGE_START" "$UDM_RESERVATION_RANGE_END")" \
  || die "No free IP in the reservation range $UDM_RESERVATION_RANGE_START-$UDM_RESERVATION_RANGE_END"
log "Reserved IP: $RESERVED_IP"

# ---------------------------------------------------------------------------
# SSH key
# ---------------------------------------------------------------------------
[ -f "${PROVISIONING_SSH_KEY}.pub" ] || die "SSH public key not found at ${PROVISIONING_SSH_KEY}.pub"
SSH_PUBLIC_KEY="$(cat "${PROVISIONING_SSH_KEY}.pub")"
SSH_FINGERPRINT="$(ssh-keygen -lf "${PROVISIONING_SSH_KEY}.pub" | awk '{print $2}')"

cat <<PLAN

============================================================
Provisioning Plan (Proxmox LXC)
============================================================
Hostname:            $HOSTNAME_ARG
FQDN (internal):      $FQDN
Proxmox Node:         $TARGET_NODE
VMID:                 $VMID
Template:             ${PVE_TEMPLATE_STORAGE}:vztmpl/${PVE_TEMPLATE}
CPU:                  ${CORES} vCPU
RAM:                  ${MEMORY} MB
Disk:                 ${DISK} GB (storage: $PVE_STORAGE)
Network:              bridge=$PVE_BRIDGE, vlan=${VLAN_TAG:-none (native/VLAN1)}, DHCP reservation via UDM Pro -> $RESERVED_IP
Internal DNS:          $FQDN -> $RESERVED_IP (local DNS record, created on the UDM before the container so it resolves from first boot)
MAC Address:          $MAC_ADDR
Type:                 Unprivileged LXC, start at boot
Admin User:           $ADMIN_USER (created during bootstrap; template ships with root only)
SSH Key:              ${PROVISIONING_SSH_KEY}.pub (fingerprint $SSH_FINGERPRINT)
Timezone:             $TIMEZONE
Public access:         $( [ "${#PUBLIC_HOSTNAMES[@]}" -gt 0 ] && echo "Cloudflare Tunnel -> ${PUBLIC_HOSTNAMES[*]}" || echo "None (internal only)" )
Internal HTTPS:         $( $ENABLE_TLS && echo "Let's Encrypt via DNS-01 for $FQDN" || echo "Disabled" )
Beszel Monitoring:      $( $SKIP_BESZEL && echo "Skipped" || echo "Enabled -> $BESZEL_HUB_URL" )
============================================================

PLAN

if $DRY_RUN; then
  log "Dry run — no resources created."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Proceed with creating this LXC container? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 1; }
fi

# ---------------------------------------------------------------------------
# UDM Pro reservation + DNS record — created first, so the container gets
# the right IP and resolves correctly from its very first DHCP request.
# ---------------------------------------------------------------------------
log "Creating UDM Pro DHCP reservation + local DNS record: $FQDN -> $RESERVED_IP..."
UDM_OBJECT_ID="$(create_dhcp_reservation_and_dns "$MAC_ADDR" "$RESERVED_IP" "$FQDN" "$UDM_NETWORK_ID")"
[ -n "$UDM_OBJECT_ID" ] && [ "$UDM_OBJECT_ID" != "null" ] || die "UDM reservation creation did not return an object id"
log "UDM reservation created (id: $UDM_OBJECT_ID)"

# ---------------------------------------------------------------------------
# Create + start
# ---------------------------------------------------------------------------
log "Creating LXC $VMID ($HOSTNAME_ARG) on $TARGET_NODE..."
NET0="name=eth0,bridge=${PVE_BRIDGE},ip=dhcp,hwaddr=${MAC_ADDR},type=veth"
[ -n "$VLAN_TAG" ] && NET0="${NET0},tag=${VLAN_TAG}"

TASK_ID="$(pve_api POST "/nodes/$TARGET_NODE/lxc" \
  "vmid=${VMID}" \
  "hostname=${HOSTNAME_ARG}" \
  "ostemplate=${PVE_TEMPLATE_STORAGE}:vztmpl/${PVE_TEMPLATE}" \
  "cores=${CORES}" \
  "memory=${MEMORY}" \
  "rootfs=${PVE_STORAGE}:${DISK}" \
  "net0=${NET0}" \
  "unprivileged=1" \
  "onboot=1" \
  "start=1" \
  "features=nesting=1" \
  "ssh-public-keys=${SSH_PUBLIC_KEY}" \
  | jq -r '.data')"
[ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ] || die "Container creation failed"
log "Create task: $TASK_ID"

# Write initial state immediately so a billed/allocated resource is never lost track of
NOW="$(date -Iseconds)"
state_write "$HOSTNAME_ARG" "$(jq -n \
  --arg name "$HOSTNAME_ARG" --arg fqdn "$FQDN" --argjson vmid "$VMID" --arg node "$TARGET_NODE" \
  --arg mac "$MAC_ADDR" --arg created "$NOW" --arg status "CREATING" \
  '{name:$name, fqdn:$fqdn, vmid:$vmid, node:$node, mac_address:$mac, created_at:$created, status:$status}')"

log "Waiting for create task to complete..."
for i in $(seq 1 30); do
  STATUS="$(pve_api GET "/nodes/$TARGET_NODE/tasks/$TASK_ID/status" | jq -r '.data.status')"
  [ "$STATUS" = "stopped" ] && break
  sleep 3
done
EXIT_STATUS="$(pve_api GET "/nodes/$TARGET_NODE/tasks/$TASK_ID/status" | jq -r '.data.exitstatus')"
[ "$EXIT_STATUS" = "OK" ] || die "Create task did not finish OK (status: $EXIT_STATUS). Check the Proxmox task log."
log "Container created."

log "Waiting for container status = running..."
for i in $(seq 1 20); do
  CSTATUS="$(pve_api GET "/nodes/$TARGET_NODE/lxc/$VMID/status/current" | jq -r '.data.status')"
  [ "$CSTATUS" = "running" ] && break
  sleep 3
done
[ "$CSTATUS" = "running" ] || die "Container did not reach running status (last seen: $CSTATUS)"
log "Container running."

# ---------------------------------------------------------------------------
# Wait for a DHCP-assigned IP, discovered via Proxmox's own interface report
# ---------------------------------------------------------------------------
log "Waiting for a DHCP lease..."
CONTAINER_IP=""
for i in $(seq 1 20); do
  CONTAINER_IP="$(pve_api GET "/nodes/$TARGET_NODE/lxc/$VMID/interfaces" 2>/dev/null | jq -r '.data[] | select(.name=="eth0") | .inet // empty' | cut -d/ -f1)"
  [ -n "$CONTAINER_IP" ] && [ "$CONTAINER_IP" != "null" ] && break
  sleep 5
done
[ -n "$CONTAINER_IP" ] && [ "$CONTAINER_IP" != "null" ] || die "Container did not get a DHCP address in time. VMID=$VMID node=$TARGET_NODE — check the UDM Pro's DHCP scope for VLAN $VLAN_TAG."
log "Container IP: $CONTAINER_IP"

# The UDM's reservation doesn't always take effect on the container's very
# first DHCP request — confirmed via testing: the container got a pool IP
# initially, and only picked up the reserved IP after a lease renewal
# several minutes later (mid-bootstrap, breaking a script that assumed the
# first IP was final). Rather than race that, force a fresh DHCP request via
# reboot once, and re-check — much more reliable than hoping a later
# passive renewal happens before we need the IP to be stable.
if [ "$CONTAINER_IP" != "$RESERVED_IP" ]; then
  warn "Container got $CONTAINER_IP but the UDM reservation was for $RESERVED_IP — reservation may not have propagated to the DHCP server yet. Rebooting to force a fresh DHCP request..."
  sleep 20
  pve_api POST "/nodes/$TARGET_NODE/lxc/$VMID/status/reboot" >/dev/null || warn "Reboot request failed — continuing with $CONTAINER_IP"
  sleep 15
  for i in $(seq 1 20); do
    NEW_IP="$(pve_api GET "/nodes/$TARGET_NODE/lxc/$VMID/interfaces" 2>/dev/null | jq -r '.data[] | select(.name=="eth0") | .inet // empty' | cut -d/ -f1)"
    [ -n "$NEW_IP" ] && [ "$NEW_IP" != "null" ] && [ "$NEW_IP" = "$RESERVED_IP" ] && { CONTAINER_IP="$NEW_IP"; break; }
    sleep 5
  done
  if [ "$CONTAINER_IP" = "$RESERVED_IP" ]; then
    log "Reservation now confirmed: $CONTAINER_IP"
  else
    warn "Still not on the reserved IP after a reboot (currently ${NEW_IP:-unknown}) — continuing with whatever's currently assigned, but this container's IP may not be stable yet. Investigate the UDM reservation manually if this persists."
    [ -n "$NEW_IP" ] && [ "$NEW_IP" != "null" ] && CONTAINER_IP="$NEW_IP"
  fi
fi

log "Verifying local DNS resolution for $FQDN..."
DNS_OK=false
for i in $(seq 1 6); do
  verify_local_dns "$FQDN" "$CONTAINER_IP" && { DNS_OK=true; break; }
  sleep 5
done
$DNS_OK && log "DNS confirmed: $FQDN -> $CONTAINER_IP" || warn "Could not confirm DNS resolution for $FQDN against the UDM Pro directly — the record was created via API (id $UDM_OBJECT_ID) but verification failed; check manually with: dig $FQDN @$UBIQUITI_ROUTER"

# ---------------------------------------------------------------------------
# SSH as root (only account on this template), bootstrap, verify admin user
# ---------------------------------------------------------------------------
log "Waiting for SSH as root@$CONTAINER_IP..."
wait_for_ssh "$PROVISIONING_SSH_KEY" root "$CONTAINER_IP" 20 10 || die "Could not establish SSH as root within the timeout. VMID=$VMID ip=$CONTAINER_IP"
log "SSH confirmed as root."

ssh_opts "$PROVISIONING_SSH_KEY"

log "Running bootstrap-container.sh remotely..."
scp "${SSH_OPTS[@]}" "$HERE/scripts/bootstrap-container.sh" "root@$CONTAINER_IP:/tmp/bootstrap-container.sh"
BOOTSTRAP_OUT="$(ssh "${SSH_OPTS[@]}" "root@$CONTAINER_IP" "chmod +x /tmp/bootstrap-container.sh && /tmp/bootstrap-container.sh '$FQDN' '$TIMEZONE' '$ADMIN_USER' '$SSH_PUBLIC_KEY' && rm -f /tmp/bootstrap-container.sh")"
log "Bootstrap complete."

log "Verifying SSH as $ADMIN_USER@$CONTAINER_IP..."
wait_for_ssh "$PROVISIONING_SSH_KEY" "$ADMIN_USER" "$CONTAINER_IP" 6 5 || die "SSH as $ADMIN_USER failed after bootstrap"
log "$ADMIN_USER SSH confirmed."

# ---------------------------------------------------------------------------
# Beszel monitoring agent (default on) — connects outbound to the existing
# Beszel hub via a universal token, so nothing needs opening inbound on this
# container for it. Independent of everything else below (tunnel/TLS/web),
# so it runs early.
# ---------------------------------------------------------------------------
BESZEL_OK=false
if ! $SKIP_BESZEL; then
  log "Installing Beszel monitoring agent..."
  load_beszel_creds
  scp "${SSH_OPTS[@]}" "$PROVISIONING_ROOT/common/install-beszel-agent.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-beszel-agent.sh"
  if printf '%s' "$BESZEL_TOKEN" | ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
      "chmod +x /tmp/install-beszel-agent.sh && /tmp/install-beszel-agent.sh '$BESZEL_HUB_URL' '$BESZEL_HUB_KEY' '$BESZEL_PORT' && rm -f /tmp/install-beszel-agent.sh" 2>&1; then
    BESZEL_OK=true
    log "Beszel agent connected."
  else
    warn "Beszel agent install/connection failed — check the output above. Not fatal to the rest of provisioning."
  fi
fi

# ---------------------------------------------------------------------------
# Cloudflare Tunnel (optional) — dedicated tunnel for this container. Note:
# cloudflared connects outbound to Cloudflare's edge and proxies to
# http://localhost:80 *locally on the container* — no ufw/firewall change is
# needed for the tunnel itself to work, only if/when an actual web service is
# added later.
# ---------------------------------------------------------------------------
TUNNEL_RECORD_ID="" DEDICATED_TUNNEL_ID="" TUNNEL_ZONE_ID="" TUNNEL_ACCOUNT_ID="" LOCAL_OVERRIDE_ID=""
if [ -n "$PUBLIC_HOSTNAME" ]; then
  log "Provisioning dedicated Cloudflare Tunnel for $PUBLIC_HOSTNAME -> $CONTAINER_IP ..."
  TUNNEL_OUT="$("$HERE/scripts/install-cloudflare-tunnel.sh" "$HOSTNAME_ARG" "$PUBLIC_HOSTNAME" "$CONTAINER_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY")" || die "Cloudflare Tunnel provisioning failed"
  DEDICATED_TUNNEL_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ID=' | cut -d= -f2)"
  TUNNEL_RECORD_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_RECORD_ID=' | cut -d= -f2)"
  TUNNEL_ZONE_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_TUNNEL_ZONE_ID=' | cut -d= -f2)"
  TUNNEL_ACCOUNT_ID="$(echo "$TUNNEL_OUT" | grep '^CLOUDFLARE_ACCOUNT_ID=' | cut -d= -f2)"
  log "Tunnel ready: id=$DEDICATED_TUNNEL_ID, DNS record id=$TUNNEL_RECORD_ID"

  # Local override so LAN clients resolve $PUBLIC_HOSTNAME directly to this
  # container's internal FQDN instead of round-tripping out through
  # Cloudflare's edge and back in via the tunnel. External resolvers are
  # unaffected — they still see Cloudflare's proxied answer.
  log "Creating local DNS override so $PUBLIC_HOSTNAME resolves directly to $FQDN for LAN clients..."
  LOCAL_OVERRIDE_ID="$(create_local_dns_override "$PUBLIC_HOSTNAME" "$FQDN")"
  [ -n "$LOCAL_OVERRIDE_ID" ] && [ "$LOCAL_OVERRIDE_ID" != "null" ] || warn "Local DNS override creation did not return an id — check manually"
  log "Local DNS override ready (id: $LOCAL_OVERRIDE_ID)"
fi

# ---------------------------------------------------------------------------
# HTTPS via DNS-01 (optional) — for the container's *internal* FQDN. Uses
# the Cloudflare API to create a validation TXT record rather than HTTP-01,
# since .in.example.com isn't (and shouldn't be) publicly resolvable.
# ---------------------------------------------------------------------------
TLS_OK=false
if $ENABLE_TLS; then
  load_cloudflare_token
  # If --public-hostname is also set, it's added as an extra SAN on the same
  # certificate — that hostname can be reached two ways (Cloudflare Tunnel
  # externally, the local DNS override internally) and the internal path
  # terminates TLS on this container directly, so it needs its own valid SAN
  # too, not just Cloudflare's edge cert.
  TLS_DOMAIN_DESC="$FQDN"
  [ -n "$PUBLIC_HOSTNAME" ] && TLS_DOMAIN_DESC="$FQDN + $PUBLIC_HOSTNAME"
  log "Requesting Let's Encrypt certificate for $TLS_DOMAIN_DESC via DNS-01..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-https-dns01.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-https-dns01.sh"
  if printf '%s' "$CF_API_TOKEN" | ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
      "chmod +x /tmp/install-https-dns01.sh && /tmp/install-https-dns01.sh '$FQDN' '$LETSENCRYPT_EMAIL' ${PUBLIC_HOSTNAME:+'$PUBLIC_HOSTNAME'} && rm -f /tmp/install-https-dns01.sh" 2>&1; then
    TLS_OK=true
    log "Certificate issued for $TLS_DOMAIN_DESC."
  else
    warn "Let's Encrypt DNS-01 issuance failed — check the output above. Not fatal to the rest of provisioning."
  fi
fi

# ---------------------------------------------------------------------------
# Minimal test/welcome vhost — NOT a --role system (deliberately not built
# yet). Just enough Apache + a welcome page for HTTP/HTTPS verification to
# have something real to check, internally and externally. Runs after the
# TLS step so it can detect and wire up an existing cert if one was issued.
# ---------------------------------------------------------------------------
WEB_OK=false
if ! $SKIP_WEB; then
  log "Installing minimal test vhost..."
  scp "${SSH_OPTS[@]}" "$HERE/scripts/install-test-vhost.sh" "$ADMIN_USER@$CONTAINER_IP:/tmp/install-test-vhost.sh"
  if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$CONTAINER_IP" \
      "chmod +x /tmp/install-test-vhost.sh && /tmp/install-test-vhost.sh '$FQDN' ${PUBLIC_HOSTNAME:+'$PUBLIC_HOSTNAME'} && rm -f /tmp/install-test-vhost.sh"; then
    WEB_OK=true
    log "Test vhost active."
  else
    warn "Test vhost install failed — check the output above. Not fatal to the rest of provisioning."
  fi
fi

# ---------------------------------------------------------------------------
# Final state + provisioning record
# ---------------------------------------------------------------------------
UBUNTU_VERSION="$(echo "$BOOTSTRAP_OUT" | grep '^UBUNTU_VERSION=' | cut -d= -f2)"
FINAL_NOW="$(date -Iseconds)"
state_write "$HOSTNAME_ARG" "$(jq -n \
  --arg name "$HOSTNAME_ARG" --arg fqdn "$FQDN" --argjson vmid "$VMID" --arg node "$TARGET_NODE" \
  --arg mac "$MAC_ADDR" --arg ip "$CONTAINER_IP" --arg created "$NOW" --arg updated "$FINAL_NOW" \
  --arg status "Completed" --argjson cores "$CORES" --argjson memory "$MEMORY" --argjson disk "$DISK" \
  --arg ubuntu "$UBUNTU_VERSION" \
  --argjson tunnel_enabled "$([ -n "$PUBLIC_HOSTNAME" ] && echo true || echo false)" \
  --arg public_hostname "$PUBLIC_HOSTNAME" --arg tunnel_id "$DEDICATED_TUNNEL_ID" \
  --arg tunnel_record_id "$TUNNEL_RECORD_ID" --arg tunnel_zone_id "$TUNNEL_ZONE_ID" --arg tunnel_account_id "$TUNNEL_ACCOUNT_ID" \
  --arg local_override_id "$LOCAL_OVERRIDE_ID" \
  --argjson tls_enabled "$TLS_OK" --argjson web_enabled "$WEB_OK" --argjson beszel_enabled "$BESZEL_OK" \
  --argjson dns_ok "$DNS_OK" --arg udm_object_id "$UDM_OBJECT_ID" --arg reserved_ip "$RESERVED_IP" \
  '{name:$name, fqdn:$fqdn, vmid:$vmid, node:$node, mac_address:$mac, public_ipv4:$ip,
    created_at:$created, updated_at:$updated, status:$status, cores:$cores, memory_mb:$memory, disk_gb:$disk,
    ubuntu_version:$ubuntu, tls_enabled:$tls_enabled, web_enabled:$web_enabled, beszel_enabled:$beszel_enabled,
    internal_dns:{configured:true, verified:$dns_ok, udm_object_id:$udm_object_id, reserved_ip:$reserved_ip},
    cloudflare:{tunnel_enabled:$tunnel_enabled, public_hostname:$public_hostname, tunnel_id:$tunnel_id,
                tunnel_dns_record_id:$tunnel_record_id, tunnel_zone_id:$tunnel_zone_id, account_id:$tunnel_account_id,
                local_dns_override_id:$local_override_id}}')"

RECORD="$(record_file "$HOSTNAME_ARG")"
{
  echo "============================================================"
  echo "Provisioned Server Record (Proxmox LXC)"
  echo "============================================================"
  echo
  echo "Hostname:"; echo "$HOSTNAME_ARG"; echo
  echo "FQDN:"; echo "$FQDN"; echo
  echo "VMID:"; echo "$VMID"; echo
  echo "Proxmox Node:"; echo "$TARGET_NODE"; echo
  echo "IP Address:"; echo "$CONTAINER_IP"; echo
  echo "MAC Address:"; echo "$MAC_ADDR"; echo
  echo "OS:"; echo "Ubuntu $UBUNTU_VERSION"; echo
  echo "CPU:"; echo "$CORES vCPU"; echo
  echo "RAM:"; echo "${MEMORY} MB"; echo
  echo "Disk:"; echo "${DISK} GB"; echo
  echo "Created:"; echo "$NOW"; echo
  echo "Internal DNS:"; echo "$FQDN -> $CONTAINER_IP (UDM object $UDM_OBJECT_ID, verified: $DNS_OK)"; echo
  echo "Public Hostname:"; echo "${PUBLIC_HOSTNAME:-Not configured}"; echo
  echo "Cloudflare Tunnel:"; echo "$( [ -n "$PUBLIC_HOSTNAME" ] && echo Enabled || echo 'Not configured' )"; echo
  echo "Cloudflare Tunnel ID:"; echo "${DEDICATED_TUNNEL_ID:-Not configured}"; echo
  echo "Local DNS Override (public hostname resolves to internal FQDN on LAN):"; echo "$( [ -n "$PUBLIC_HOSTNAME" ] && echo "$PUBLIC_HOSTNAME -> $FQDN (UDM static-dns object ${LOCAL_OVERRIDE_ID:-unknown})" || echo 'Not configured' )"; echo
  echo "Internal HTTPS (DNS-01):"; echo "$( $TLS_OK && echo "Enabled — https://$FQDN/" || echo 'Not configured' )"; echo
  echo "Test Web Server:"; echo "$( $WEB_OK && echo "Enabled — Apache welcome page" || echo 'Not configured' )"; echo
  echo "Beszel Monitoring:"; echo "$( $BESZEL_OK && echo "Enabled — $BESZEL_HUB_URL" || echo 'Not configured' )"; echo
  echo "SSH User:"; echo "$ADMIN_USER"; echo
  echo "SSH Command:"; echo "ssh -i $PROVISIONING_SSH_KEY $ADMIN_USER@$FQDN"; echo
  echo "Service:"; echo "None yet — base OS only"; echo
  echo "Notes:"; echo "Created by provisioning/proxmox toolkit."; echo
} > "$RECORD"
chmod 600 "$RECORD"

# ---------------------------------------------------------------------------
# Any additional public hostnames beyond the primary (from a comma-separated
# --public-hostname) are attached now, via the exact same path add-vhost.sh
# uses for an already-existing container — the primary tunnel/CNAME/DNS
# override/state/record are already fully written above, so from here on
# this container looks no different to add-vhost.sh than one that's been
# running for a while. A failure here warns but doesn't undo the successful
# primary provisioning that already happened.
# ---------------------------------------------------------------------------
ADDITIONAL_OK=0 ADDITIONAL_FAILED=0
for extra in "${ADDITIONAL_PUBLIC_HOSTNAMES[@]}"; do
  log "Adding additional public hostname $extra ..."
  if "$HERE/bin/add-vhost.sh" "$HOSTNAME_ARG" "$extra" --yes; then
    ADDITIONAL_OK=$((ADDITIONAL_OK + 1))
  else
    ADDITIONAL_FAILED=$((ADDITIONAL_FAILED + 1))
    warn "Failed to add $extra — the container and its primary hostname are still fine. Retry with: ./bin/add-vhost.sh $HOSTNAME_ARG $extra"
  fi
done

cat <<SUMMARY

============================================================
Provisioning Complete
============================================================
Container:
  VMID:        $VMID
  Hostname:    $HOSTNAME_ARG
  FQDN:        $FQDN
  Node:        $TARGET_NODE
  IP:          $CONTAINER_IP
  OS:          Ubuntu $UBUNTU_VERSION

Internal DNS:
  $FQDN -> $CONTAINER_IP $( $DNS_OK && echo "(verified)" || echo "(created, verification pending)" )

Internal HTTPS:
  $( $TLS_OK && echo "https://$FQDN/ (Let's Encrypt via DNS-01)" || echo "Not configured" )

Beszel Monitoring:
  $( $BESZEL_OK && echo "Connected to $BESZEL_HUB_URL" || echo "Not configured" )

Public:
$( [ -n "$PUBLIC_HOSTNAME" ] && echo "  $PUBLIC_HOSTNAME (primary)
  Cloudflare Tunnel: $DEDICATED_TUNNEL_ID
  Local DNS override (LAN resolves directly, no hairpin): $LOCAL_OVERRIDE_ID" || echo "  Not configured" )
$( [ "${#ADDITIONAL_PUBLIC_HOSTNAMES[@]}" -gt 0 ] && printf '  + %s additional hostname(s): %s (%d ok, %d failed — see above)\n' \
     "${#ADDITIONAL_PUBLIC_HOSTNAMES[@]}" "${ADDITIONAL_PUBLIC_HOSTNAMES[*]}" "$ADDITIONAL_OK" "$ADDITIONAL_FAILED" )

SSH:
  ssh -i $PROVISIONING_SSH_KEY $ADMIN_USER@$FQDN

Provisioning record:
  $RECORD
============================================================
SUMMARY
