#!/usr/bin/env bash
# Shared Tailscale API helpers — sourced by any backend's provisioning
# scripts. Requires common/logging.sh already sourced, and
# TAILSCALE_CLIENTID + TAILSCALE_CLIENTSECRET set (via each backend's own
# credential loader, e.g. load_tailscale_creds) before calling these.
#
# OAuth client credentials in, a short-lived API access token and per-server
# tagged authkeys out. Never persisted to disk; live only in shell variables
# for the duration of one provisioning run.

TS_API_BASE="https://api.tailscale.com/api/v2"

tailscale_access_token() {
  # Caches in TS_ACCESS_TOKEN for the rest of this run.
  if [ -z "${TS_ACCESS_TOKEN:-}" ]; then
    local resp
    resp="$(curl -s -X POST "$TS_API_BASE/oauth/token" \
      -d "client_id=$TAILSCALE_CLIENTID" -d "client_secret=$TAILSCALE_CLIENTSECRET")"
    TS_ACCESS_TOKEN="$(echo "$resp" | jq -r '.access_token // empty')"
    [ -n "$TS_ACCESS_TOKEN" ] || die "Tailscale OAuth token request failed: $(echo "$resp" | jq -c '.' 2>/dev/null || echo "$resp")"
  fi
  echo "$TS_ACCESS_TOKEN"
}

# tailscale_mint_authkey <description> — mints a reusable, pre-authorized,
# non-ephemeral authkey tagged $TAILSCALE_TAG (must already have a
# tagOwners entry in the tailnet ACL, and the OAuth client must be scoped to
# manage it — Tailscale rejects OAuth-minted keys for tags it doesn't
# recognize). Sets TS_KEY_ID (safe to log/store — not secret, only used to
# revoke the key later) and TS_AUTH_KEY (secret — caller must pipe it to the
# remote host over stdin, never as an argument or into a file this script
# controls the lifetime of).
tailscale_mint_authkey() {
  local desc="${1:-provisioning}"
  local token payload resp
  token="$(tailscale_access_token)"
  payload="$(jq -n --arg tag "$TAILSCALE_TAG" --arg desc "$desc" \
    '{capabilities:{devices:{create:{reusable:true,ephemeral:false,preauthorized:true,tags:[$tag]}}},description:$desc}')"
  resp="$(curl -s -X POST "$TS_API_BASE/tailnet/-/keys" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$payload")"
  TS_KEY_ID="$(echo "$resp" | jq -r '.id // empty')"
  TS_AUTH_KEY="$(echo "$resp" | jq -r '.key // empty')"
  if [ -z "$TS_KEY_ID" ] || [ -z "$TS_AUTH_KEY" ]; then
    die "Failed to mint Tailscale authkey (tag $TAILSCALE_TAG): $(echo "$resp" | jq -c '.' 2>/dev/null || echo "$resp")"
  fi
}

# tailscale_revoke_key <key_id> — used when a key was minted but never
# consumed by a device (e.g. the join failed partway through).
tailscale_revoke_key() {
  local key_id="$1" token
  token="$(tailscale_access_token)"
  curl -s -o /dev/null -X DELETE "$TS_API_BASE/tailnet/-/keys/$key_id" -H "Authorization: Bearer $token"
}

# tailscale_delete_device_by_hostname <hostname> — used by destroy scripts.
# Tailscale's own reported hostname (the --hostname 'tailscale up' was
# given), not necessarily the FQDN. No matching device is not an error.
tailscale_delete_device_by_hostname() {
  local hostname="$1" token devices device_id
  token="$(tailscale_access_token)"
  devices="$(curl -s "$TS_API_BASE/tailnet/-/devices?fields=default" -H "Authorization: Bearer $token")"
  device_id="$(echo "$devices" | jq -r --arg h "$hostname" '.devices[]? | select(.hostname == $h) | .id' | head -1)"
  if [ -z "$device_id" ]; then
    warn "No Tailscale device found with hostname '$hostname' — nothing to remove there."
    return 0
  fi
  log "Removing Tailscale device '$hostname' (id $device_id)..."
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$TS_API_BASE/device/$device_id" -H "Authorization: Bearer $token")"
  [ "$status" -lt 300 ] && log "Tailscale device removed." || warn "Failed to remove Tailscale device $device_id (HTTP $status) — remove manually from the admin console."
}
