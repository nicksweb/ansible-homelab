#!/usr/bin/env bash
# Shared Cloudflare API helpers — sourced by any backend's provisioning
# scripts (proxmox/, binarylane's server-provisioning/ still has its own
# copy for now — not touched, to avoid risk to working code). Requires
# common/logging.sh already sourced, and CF_API_TOKEN + CF_ACCOUNT_ID set
# (via each backend's own credential loader) before calling these.

CF_API_BASE="https://api.cloudflare.com/client/v4"

cf_api() {
  # cf_api <method> <path> [json-data]
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

# resolve_zone_id_for_hostname <hostname> — suffix-matches against the live
# zone list, picks the longest (most specific) match. Cloudflare silently
# misfiles a record under the wrong zone rather than rejecting a mismatch,
# so never assume a hostname belongs to a zone — always resolve it.
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
  [ -n "$best_id" ] || die "No Cloudflare zone in this account matches '$hostname'. Available zones: $(echo "$zones" | jq -r '.result[].name' | tr '\n' ' ')"
  echo "$best_id"
}

# create_or_reuse_tunnel <tunnel_name> — echoes "tunnel_id" on success.
create_or_reuse_tunnel() {
  local tunnel_name="$1"
  local existing tunnel_id
  existing="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${tunnel_name}&is_deleted=false")" || die "Cloudflare tunnel lookup failed"
  tunnel_id="$(echo "$existing" | jq -r '.result[0].id // empty')"
  if [ -n "$tunnel_id" ]; then
    log "Reusing existing tunnel $tunnel_id" >&2
  else
    log "Creating new locally-managed tunnel '$tunnel_name'" >&2
    local secret payload result
    secret="$(openssl rand -base64 32)"
    payload="$(jq -n --arg name "$tunnel_name" --arg secret "$secret" '{name:$name, tunnel_secret:$secret, config_src:"local"}')"
    unset secret
    result="$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" "$payload")" || die "Tunnel creation failed"
    tunnel_id="$(echo "$result" | jq -r '.result.id')"
    [ -n "$tunnel_id" ] && [ "$tunnel_id" != "null" ] || die "Could not determine new tunnel ID from API response"
  fi
  echo "$tunnel_id"
}

# fetch_tunnel_token <tunnel_id> — echoes the connector token. Caller must
# pipe this straight to the remote install script's stdin, never write it
# to disk or log it.
fetch_tunnel_token() {
  local tunnel_id="$1"
  local result token
  result="$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")" || die "Could not fetch tunnel token"
  token="$(echo "$result" | jq -r '.result')"
  [ -n "$token" ] && [ "$token" != "null" ] || die "Tunnel token response was empty"
  echo "$token"
}

# create_or_update_cname <hostname> <zone_id> <target> — proxied CNAME,
# echoes the record id.
create_or_update_cname() {
  local hostname="$1" zone_id="$2" target="$3"
  local existing record_id payload result
  existing="$(cf_api GET "/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}")" || die "Cloudflare DNS lookup failed"
  record_id="$(echo "$existing" | jq -r '.result[0].id // empty')"
  payload="$(jq -n --arg fqdn "$hostname" --arg target "$target" '{type:"CNAME", name:$fqdn, content:$target, proxied:true, ttl:1}')"
  if [ -n "$record_id" ]; then
    cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload" >/dev/null || die "Failed to update CNAME"
  else
    result="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")" || die "Failed to create CNAME"
    record_id="$(echo "$result" | jq -r '.result.id')"
  fi
  echo "$record_id"
}

tunnel_health() {
  local tunnel_id="$1"
  cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}" | jq -r '.result.status'
}
