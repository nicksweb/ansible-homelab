#!/usr/bin/env bash
# Shared UDM Pro / UniFi Network helpers — sourced by any backend needing
# internal DNS + DHCP reservations. Requires common/logging.sh sourced, and
# UBIQUITI_ROUTER + UBIQUITI_KEY set (via each backend's credential loader)
# before calling these.
#
# Uses the legacy per-site REST API (/proxy/network/api/s/{site}/rest/...),
# not the newer Integration API (v1) — the Integration API doesn't currently
# expose DHCP reservations or local DNS records; those are still
# "user" (client) object fields on the legacy REST surface. Confirmed via
# direct inspection of an existing manually-configured reservation. Both
# APIs accept the same X-API-KEY on this UniFi OS version.

: "${UDM_SITE:=default}"

udm_api() {
  # udm_api <method> <path> [json-data]
  local method="$1" path="$2" data="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-s -k -o "$tmp" -w '%{http_code}' -X "$method" -H "X-API-KEY: ${UBIQUITI_KEY}" -H "Content-Type: application/json")
  [ -n "$data" ] && args+=(-d "$data")
  local code; code="$(curl "${args[@]}" "https://${UBIQUITI_ROUTER}${path}")"
  log "UDM API $method $path -> HTTP $code"
  if [ "$code" -ge 400 ]; then
    warn "UDM API error body: $(cat "$tmp")"
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# find_free_reservation_ip <range_start> <range_end> — echoes the first IP
# in the range not already used by an existing client reservation or last
# known lease. Range should sit outside the DHCP dynamic pool.
find_free_reservation_ip() {
  local range_start="$1" range_end="$2"
  local used
  used="$(udm_api GET "/proxy/network/api/s/${UDM_SITE}/rest/user?limit=1000" | jq -r '.data[] | .fixed_ip, .last_ip' | grep -v '^null$' | sort -u)"
  local base="${range_start%.*}" start_last="${range_start##*.}" end_last="${range_end##*.}"
  local i
  for i in $(seq "$start_last" "$end_last"); do
    local candidate="${base}.${i}"
    echo "$used" | grep -qx "$candidate" || { echo "$candidate"; return 0; }
  done
  return 1
}

# create_dhcp_reservation_and_dns <mac> <ip> <fqdn> <network_id> — creates a
# fixed-IP reservation with a local DNS record in one client object. Echoes
# the new object's _id (needed for later deletion).
create_dhcp_reservation_and_dns() {
  local mac="$1" ip="$2" fqdn="$3" network_id="$4"
  local payload result
  payload="$(jq -n --arg mac "$mac" --arg ip "$ip" --arg fqdn "$fqdn" --arg net "$network_id" \
    '{mac:$mac, use_fixedip:true, fixed_ip:$ip, local_dns_record:$fqdn, network_id:$net}')"
  result="$(udm_api POST "/proxy/network/api/s/${UDM_SITE}/rest/user" "$payload")" || die "Failed to create DHCP reservation + DNS record"
  echo "$result" | jq -r '.data[0]._id'
}

delete_dhcp_reservation() {
  # delete_dhcp_reservation <object_id> <mac> — <mac> is required. Once a
  # client has actually connected to the network (true for every container
  # this toolkit provisions, since it does DHCP + SSH), the UDM promotes it
  # from a plain "configured user" record to a tracked client, and plain
  # `DELETE /rest/user/{id}` starts returning 404 api.err.NotFound even
  # though the record still shows up in GET — confirmed directly via testing
  # (destroying host003 hit exactly this). The supported way to fully remove
  # a client that has connected is `cmd/stamgr forget-sta` by MAC, which was
  # confirmed to work in the same test. Try that first; fall back to the
  # plain DELETE for the (untested but plausible) case of a reservation that
  # was created but never actually connected.
  local object_id="$1" mac="$2"
  [ -n "$mac" ] || die "delete_dhcp_reservation: mac is required"
  if udm_api POST "/proxy/network/api/s/${UDM_SITE}/cmd/stamgr" "$(jq -n --arg mac "$mac" '{cmd:"forget-sta", macs:[$mac]}')" >/dev/null; then
    return 0
  fi
  warn "forget-sta failed for $mac — falling back to DELETE /rest/user/${object_id}"
  udm_api DELETE "/proxy/network/api/s/${UDM_SITE}/rest/user/${object_id}" >/dev/null
}

verify_local_dns() {
  # verify_local_dns <fqdn> <expected_ip> — queries the UDM's own DNS
  # resolver directly (it's the site's DNS server too), not just the client
  # list, so this actually proves resolution works, not just that the
  # record exists in UniFi's config.
  local fqdn="$1" expected_ip="$2"
  local resolved
  resolved="$(dig +short "$fqdn" "@${UBIQUITI_ROUTER}" 2>/dev/null | tail -1)"
  [ "$resolved" = "$expected_ip" ]
}

# ---------------------------------------------------------------------------
# Local overrides for PUBLIC hostnames (split-DNS for the tunnel side) — a
# separate mechanism from create_dhcp_reservation_and_dns above. That one
# attaches a DNS name to a specific client (MAC) object and only works for
# names inside a domain the UDM considers "ours". This one uses UniFi's
# general-purpose static-DNS record store, which accepts ANY hostname
# (including a public domain like example.net that the UDM has no other
# opinion about) and just answers it directly for LAN clients — while
# Cloudflare's edge still answers it normally for everyone else. Confirmed
# working via direct API testing against app-test.example.net ->
# host003.in.example.com.
# ---------------------------------------------------------------------------

# find_local_dns_override <hostname> — echoes "id<TAB>value" for the
# existing static-dns entry with this exact key, empty if none exists.
find_local_dns_override() {
  local hostname="$1"
  udm_api GET "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" \
    | jq -r --arg h "$hostname" '.[] | select(.key == $h) | "\(._id)\t\(.value)"' | head -n1
}

# create_local_dns_override <hostname> <target_fqdn> — makes <hostname>
# (typically the --public-hostname, e.g. app-test.example.net) resolve
# directly to <target_fqdn> (the container's internal FQDN) for LAN clients,
# via a CNAME in the static-dns store. Idempotent: a re-run pointing at the
# same target is a no-op. If a record for this hostname exists but points
# somewhere else (e.g. the hostname was reassigned to a different
# container), it's replaced — confirmed via direct testing that this API has
# no in-place update (PUT re-validates key uniqueness and always rejects
# with api.err.StaticDnsRecordAlreadyExists even for an unchanged payload;
# PATCH isn't a supported method, HTTP 405), so delete-then-recreate is the
# only way to actually repoint it rather than silently leaving stale data
# that would split-brain internal vs external traffic. Echoes the record's
# _id (needed for later deletion).
create_local_dns_override() {
  local hostname="$1" target_fqdn="$2"
  local existing_id existing_value
  IFS=$'\t' read -r existing_id existing_value < <(find_local_dns_override "$hostname")
  if [ -n "$existing_id" ]; then
    if [ "$existing_value" = "$target_fqdn" ]; then
      log "Local DNS override for $hostname already points to $target_fqdn — nothing to do"
      echo "$existing_id"
      return 0
    fi
    warn "Local DNS override for $hostname currently points to '$existing_value', not '$target_fqdn' — replacing it"
    delete_local_dns_override "$existing_id" || die "Failed to remove the stale local DNS override for $hostname before replacing it"
  fi
  local payload result
  payload="$(jq -n --arg key "$hostname" --arg value "$target_fqdn" \
    '{key:$key, record_type:"CNAME", value:$value, enabled:true, ttl:0, port:0, priority:0, weight:0}')"
  result="$(udm_api POST "/proxy/network/v2/api/site/${UDM_SITE}/static-dns" "$payload")" || die "Failed to create local DNS override for $hostname"
  echo "$result" | jq -r '._id'
}

delete_local_dns_override() {
  local object_id="$1"
  udm_api DELETE "/proxy/network/v2/api/site/${UDM_SITE}/static-dns/${object_id}" >/dev/null
}
