#!/usr/bin/env bash
# Join an EXISTING container (previously created by provision-container.sh)
# to the tailnet. provision-container.sh only does this at creation time
# via --enable-tailscale; this is the retrofit path for a container that
# was provisioned before you decided it needed tailnet reachability.
#
# Usage: enable-tailscale.sh <hostname> [--dry-run] [--yes]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/tailscale.sh"
# shellcheck disable=SC1091
source "$PROVISIONING_ROOT/common/ansible.sh"
require_jq

NAME="${1:?usage: enable-tailscale.sh <hostname> [--dry-run] [--yes]}"
shift
DRY_RUN=false ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

state_exists "$NAME" || die "No local state for '$NAME' — run provision-container.sh first."
STATUS="$(state_read_field "$NAME" '.status')"
[ "$STATUS" != "DESTROYED" ] || die "'$NAME' is marked DESTROYED — nothing to join."

FQDN="$(state_read_field "$NAME" '.fqdn')"
CONTAINER_IP="$(state_read_field "$NAME" '.public_ipv4 // empty')"
[ -n "$CONTAINER_IP" ] || die "No IP recorded for '$NAME' in local state — investigate before proceeding."
ALREADY_ENABLED="$(state_read_field "$NAME" '.tailscale.enabled // false')"

cat <<PLAN

============================================================
Enable Tailscale Plan
============================================================
Container:      $NAME ($FQDN, $CONTAINER_IP)
Tailnet tag:     $TAILSCALE_TAG (must already have a tagOwners entry in the tailnet ACL)
TUN device:      unprivileged LXC has none by default — falls back to
                 userspace-networking automatically (confirmed working;
                 no subnet routing/exit-node from this container, but
                 normal tailnet reachability + Tailscale SSH both work)
Already joined:  $( [ "$ALREADY_ENABLED" = "true" ] && echo "yes — this will mint a fresh authkey and re-join" || echo "no" )
============================================================

PLAN

if $DRY_RUN; then
  log "Dry run — no changes made."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Proceed? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Aborted by user."; exit 1; }
fi

log "Minting a tagged Tailscale authkey ($TAILSCALE_TAG) for $NAME..."
load_tailscale_creds
tailscale_mint_authkey "proxmox-$NAME"
TS_KEY_ID_USED="$TS_KEY_ID"

log "Installing Tailscale and joining the tailnet as '$NAME' via Ansible..."
TAILSCALE_VARS="$(jq -n --arg host "$NAME" --arg key "$TS_AUTH_KEY" '{tailscale_join_hostname:$host, tailscale_join_authkey:$key}')"
unset TS_AUTH_KEY
TAILSCALE_OK=false
if ansible_run_playbook "playbooks/provisioning/tailscale_join.yml" "$CONTAINER_IP" "$ADMIN_USER" "$PROVISIONING_SSH_KEY" "$TAILSCALE_VARS"; then
  TAILSCALE_OK=true
  log "Tailscale joined."
else
  warn "Tailscale install/join failed — revoking the unused authkey ($TS_KEY_ID_USED)."
  tailscale_revoke_key "$TS_KEY_ID_USED"
fi
unset TAILSCALE_VARS

$TAILSCALE_OK || die "Tailscale join failed — see output above."

NOW="$(date -Iseconds)"
state_write "$NAME" "$(jq --arg updated "$NOW" --arg hostname "$NAME" --arg tag "$TAILSCALE_TAG" --arg key_id "$TS_KEY_ID_USED" \
  '.updated_at = $updated | .tailscale = {enabled:true, hostname:$hostname, tag:$tag, authkey_id:$key_id}' \
  "$(state_file "$NAME")")"

RECORD="$(record_file "$NAME")"
{
  echo
  echo "------------------------------------------------------------"
  echo "Tailscale Enabled: $NOW"
  echo "------------------------------------------------------------"
  echo "Tailnet hostname:"; echo "$NAME"
  echo "Tag:"; echo "$TAILSCALE_TAG"
} >> "$RECORD"
chmod 600 "$RECORD"

cat <<SUMMARY

============================================================
Tailscale Enabled
============================================================
Container:       $NAME ($FQDN)
Tailnet hostname: $NAME
Tag:              $TAILSCALE_TAG
============================================================
SUMMARY
