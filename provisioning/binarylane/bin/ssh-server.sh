#!/usr/bin/env bash
# Usage: ssh-server.sh <name> [--ip] [-- extra ssh args]
#   --ip   connect to the raw public IP instead of the FQDN (useful if the
#          base A record was deliberately proxied via --cloudflare-proxy on)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
require_jq

NAME="${1:?usage: ssh-server.sh <name> [--ip]}"
shift || true
USE_IP=false
if [ "${1:-}" = "--ip" ]; then USE_IP=true; shift; fi

state_exists "$NAME" || die "No local state for '$NAME'."
TARGET="$(state_read_field "$NAME" '.fqdn')"
if $USE_IP; then
  TARGET="$(state_read_field "$NAME" '.public_ipv4')"
fi

exec ssh -i "$PROVISIONING_SSH_KEY" -o StrictHostKeyChecking=accept-new "${SSH_MULTIPLEX_OPTS[@]}" "$ADMIN_USER@$TARGET" "$@"
