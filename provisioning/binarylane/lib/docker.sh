#!/usr/bin/env bash
# Helpers for --role docker servers, shared by provision-server.sh,
# add-static-site.sh, add-tunnel-hostname.sh and allow-cloudflare-ips.sh.
# Requires lib/common.sh and common/ansible.sh already sourced, and
# load_cloudflare_creds already called for the route helpers.
#
# Local state is the source of truth for the tunnel's ingress:
# .cloudflare.tunnel_routes holds every hostname the tunnel serves
# ({hostname, service, zone_id, dns_record_id}), and every change re-renders
# the server's full cloudflared config from it via the docker_cloudflared
# role. destroy-server.sh deletes every CNAME listed there.

# docker_require_server <name> — dies unless <name> is a live docker-role
# server with a tunnel. Sets PUBLIC_IP and TUNNEL_ID.
docker_require_server() {
  local name="$1" status role
  state_exists "$name" || die "No local state for server '$name'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
  status="$(state_read_field "$name" '.status')"
  [ "$status" != "DESTROYED" ] || die "Server '$name' is marked DESTROYED in local state."
  role="$(state_read_field "$name" '.role // empty')"
  [ "$role" = "docker-static" ] || die "Server '$name' was not provisioned with --role docker (role: ${role:-unknown})."
  PUBLIC_IP="$(state_read_field "$name" '.public_ipv4')"
  TUNNEL_ID="$(state_read_field "$name" '.cloudflare.tunnel_id // empty')"
  [ -n "$TUNNEL_ID" ] || die "Server '$name' has no Cloudflare Tunnel id in state — --role docker servers always need one."
}

# docker_state_update <name> <jq-filter> [jq args...] — applies a jq filter
# to the server's state file in place and bumps updated_at.
docker_state_update() {
  local name="$1" filter="$2"; shift 2
  state_write "$name" "$(jq --arg _now "$(date -Iseconds)" "$@" "($filter) | .updated_at = \$_now" "$(state_file "$name")")"
}

# docker_tunnel_apply <name> — re-renders the server's cloudflared ingress
# from the full route list in state.
docker_tunnel_apply() {
  local name="$1" vars
  vars="$(jq -c '{docker_cloudflared_tunnel_id: .cloudflare.tunnel_id,
                  docker_cloudflared_routes: [.cloudflare.tunnel_routes[] | {hostname, service}]}' "$(state_file "$name")")"
  ansible_run_playbook "playbooks/provisioning/docker_cloudflared.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$vars"
}

# docker_route_upsert <name> <hostname> <service> — creates/updates the
# proxied CNAME for <hostname> to this server's tunnel, records the route
# in state (replacing any existing entry for the same hostname), and
# re-renders the tunnel config. Sets ROUTE_RECORD_ID.
docker_route_upsert() {
  local name="$1" fqdn="$2" service="$3" zone_id existing payload result
  zone_id="$(resolve_zone_id_for_hostname "$fqdn")" || return 1

  log "Creating/updating proxied CNAME $fqdn -> ${TUNNEL_ID}.cfargotunnel.com"
  existing="$(cf_api GET "/zones/${zone_id}/dns_records?name=${fqdn}")" || die "Cloudflare DNS lookup failed"
  if echo "$existing" | jq -e '.result[] | select(.type != "CNAME")' >/dev/null; then
    die "'$fqdn' already has a non-CNAME DNS record — refusing to overwrite it. Remove it manually first if it's really unused."
  fi
  ROUTE_RECORD_ID="$(echo "$existing" | jq -r '.result[0].id // empty')"
  local current_target; current_target="$(echo "$existing" | jq -r '.result[0].content // empty')"
  if [ -n "$current_target" ] && [ "$current_target" != "${TUNNEL_ID}.cfargotunnel.com" ]; then
    warn "$fqdn currently points at $current_target — repointing it to this server's tunnel."
  fi
  payload="$(jq -n --arg fqdn "$fqdn" --arg target "${TUNNEL_ID}.cfargotunnel.com" '{type:"CNAME", name:$fqdn, content:$target, proxied:true, ttl:1}')"
  if [ -n "$ROUTE_RECORD_ID" ]; then
    cf_api PUT "/zones/${zone_id}/dns_records/${ROUTE_RECORD_ID}" "$payload" >/dev/null || die "Failed to update DNS record for $fqdn"
  else
    result="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")" || die "Failed to create DNS record for $fqdn"
    ROUTE_RECORD_ID="$(echo "$result" | jq -r '.result.id')"
  fi
  log "DNS record id: $ROUTE_RECORD_ID"

  docker_state_update "$name" \
    '.cloudflare.tunnel_routes = ([(.cloudflare.tunnel_routes // [])[] | select(.hostname != $h)] + [{hostname:$h, service:$s, zone_id:$z, dns_record_id:$r}])' \
    --arg h "$fqdn" --arg s "$service" --arg z "$zone_id" --arg r "$ROUTE_RECORD_ID"

  log "Updating cloudflared ingress on $name..."
  docker_tunnel_apply "$name" || die "docker_cloudflared Ansible role failed — DNS and local state already list $fqdn; fix and re-run to converge."
}

# docker_https_check <fqdn> — echoes the HTTP status of https://<fqdn>/,
# retrying for up to ~90s while a new CNAME/ingress rule propagates or a
# container (NPM's admin UI is slow on first start) comes up.
docker_https_check() {
  local fqdn="$1" code=""
  for _ in $(seq 1 18); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${fqdn}/" || true)"
    # Any answer from the origin counts (a 404 from the catch-all server
    # still proves DNS + tunnel + container work); retry only on Cloudflare
    # edge errors (52x/530) or no answer at all.
    case "$code" in 000|5*) ;; *) break ;; esac
    sleep 5
  done
  echo "$code"
}
