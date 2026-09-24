#!/usr/bin/env bash
# Restricts inbound 443 on a --role docker server's NPM container to
# Cloudflare's published IP ranges plus explicitly trusted extra IPs — the
# tunnel-independent direct HTTPS path. Run automatically by
# provision-server.sh; re-run any time to refresh Cloudflare's ranges or add
# trusted IPs.
#
# Enforced in the DOCKER-USER iptables chain (docker_port_allowlist role),
# not ufw: ufw never sees traffic to a Docker-published port.
#
# Usage: allow-cloudflare-ips.sh <server-name> [--extra-ip IP[,IP...]] [--offline]
#   --extra-ip:  additional trusted IPv4/IPv6 addresses/CIDRs, merged with
#                (never replacing) those from previous runs and config
#                TRUSTED_443_IPS.
#   --offline:   skip the live fetch and use the ranges captured 2026-09-22
#                (FALLBACK_* below) — verify against
#                https://www.cloudflare.com/ips/ before relying on this.
#
# Idempotent: every run rebuilds the allow-list to match exactly, including
# removing CIDRs Cloudflare has since retired.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
require_jq

NAME="${1:?usage: allow-cloudflare-ips.sh <server-name> [--extra-ip IP[,IP...]] [--offline]}"
shift
EXTRA_IPS_NEW=""
OFFLINE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --extra-ip) EXTRA_IPS_NEW="$2"; shift 2 ;;
    --offline) OFFLINE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

FALLBACK_V4="173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22"
FALLBACK_V6="2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32"

state_exists "$NAME" || die "No local state for '$NAME'. Known servers: $(ls "$STATE_DIR" 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
[ "$(state_read_field "$NAME" '.status')" != "DESTROYED" ] || die "'$NAME' is marked DESTROYED in local state."
ROLE="$(state_read_field "$NAME" '.role // empty')"
[ "$ROLE" = "docker-static" ] || die "'$NAME' was not provisioned with --role docker (role: ${ROLE:-unknown})."
[ "$(state_read_field "$NAME" '.docker.npm_installed // false')" = "true" ] || die "'$NAME' has no NPM container (provisioned with --no-npm) — nothing publishes 443 there."
PUBLIC_IP="$(state_read_field "$NAME" '.public_ipv4')"

if $OFFLINE; then
  log "Using --offline fallback ranges (captured 2026-09-22)"
  IPS_V4="$FALLBACK_V4" IPS_V6="$FALLBACK_V6"
else
  log "Fetching current Cloudflare IP ranges..."
  IPS_V4="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 | paste -sd, -)" || die "Could not fetch https://www.cloudflare.com/ips-v4 — retry, or use --offline"
  IPS_V6="$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 | paste -sd, -)" || die "Could not fetch https://www.cloudflare.com/ips-v6 — retry, or use --offline"
  [ -n "$IPS_V4" ] && [ -n "$IPS_V6" ] || die "Fetched an empty IP list — Cloudflare's endpoint may have changed format"
fi

csv_uniq() { tr ',' '\n' | sed 's/^ *//; s/ *$//' | awk 'NF && !seen[$0]++' | paste -sd, -; }
EXISTING_EXTRA="$(state_read_field "$NAME" '.firewall.extra_ips // [] | join(",")')"
MERGED_EXTRA="$(printf '%s,%s,%s' "$EXISTING_EXTRA" "${TRUSTED_443_IPS:-}" "$EXTRA_IPS_NEW" | csv_uniq)"
ALL_CIDRS="$(printf '%s,%s,%s' "$IPS_V4" "$IPS_V6" "$MERGED_EXTRA" | csv_uniq)"

echo "============================================================"
echo "Restricting port 443 (NPM) on: $NAME ($PUBLIC_IP)"
echo "============================================================"
echo "Cloudflare IPv4 ranges: $(echo "$IPS_V4" | tr ',' '\n' | wc -l)"
echo "Cloudflare IPv6 ranges: $(echo "$IPS_V6" | tr ',' '\n' | wc -l)"
echo "Extra trusted IPs:      ${MERGED_EXTRA:-<none>}"
echo "Enforcement:            DOCKER-USER iptables chain (not ufw)"
echo "============================================================"

VARS="$(jq -n --arg cidrs "$ALL_CIDRS" '{docker_port_allowlist_rule_name:"npm-443", docker_port_allowlist_port:443, docker_port_allowlist_cidrs:($cidrs | split(","))}')"
ansible_run_playbook "playbooks/provisioning/docker_port_allowlist.yml" "$PUBLIC_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$VARS" \
  || die "docker_port_allowlist Ansible role failed"

to_json_array() { tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .; }
state_write "$NAME" "$(jq \
  --argjson v4 "$(echo "$IPS_V4" | to_json_array)" \
  --argjson v6 "$(echo "$IPS_V6" | to_json_array)" \
  --argjson extra "$(echo "$MERGED_EXTRA" | to_json_array)" \
  --arg updated "$(date -Iseconds)" \
  '.firewall = {cloudflare_443_enabled:true, cloudflare_ips_v4:$v4, cloudflare_ips_v6:$v6, extra_ips:$extra} | .updated_at = $updated' \
  "$(state_file "$NAME")")"

log "Done. NPM's 443 on $NAME now accepts only $(echo "$ALL_CIDRS" | tr ',' '\n' | wc -l) CIDRs/IPs."
