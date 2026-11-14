#!/usr/bin/env bash
# rebuild-server.sh <name> [--yes]
#
# Blows a BinaryLane LAMP server away and builds it again exactly as it was,
# then puts everything it serves back — no other input needed:
#
#   1. read how it was built (region, plan, tunnel hostname) from its state
#   2. destroy it, keeping its inventory (vhosts.yml, apps.yml, sites.yml)
#   3. provision it again (hardening, LAMP, tuning, CrowdSec, tunnel)
#   4. vhosts      — every site's vhost, certificate, tunnel route and DNS
#   5. PHP apps    — apps.yml: files + databases copied from their source
#   6. Jekyll sites — sites.yml: built here, rsynced up
#   7. GoAccess    — visitor stats for every site
#   8. smoke test  — every site over HTTPS, services, CrowdSec, stats
#
# Asks before destroying unless --yes. Each step's output goes to the
# terminal; the run stops at the first failing step and says how to resume.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/common.sh"
REPO="$(cd "$HERE/../.." && pwd)"
INV="$REPO/provisioning/inventory"

NAME="${1:?usage: rebuild-server.sh <name> [--yes]}"
ASSUME_YES=false; [ "${2:-}" = "--yes" ] && ASSUME_YES=true

state_exists "$NAME" || die "No state for '$NAME' — nothing to rebuild (use provision-server.sh for a new server)."
[ "$(state_read_field "$NAME" '.status')" = Completed ] || die "'$NAME' isn't a completed server (status: $(state_read_field "$NAME" '.status'))."
ROLE="$(state_read_field "$NAME" '.role // "lamp"')"
[ "$ROLE" = lamp ] || die "rebuild-server.sh handles LAMP servers; '$NAME' is '$ROLE'."

REGION="$(state_read_field "$NAME" '.region')"
PLAN="$(state_read_field "$NAME" '.plan')"
TUNNEL_HOST="$(state_read_field "$NAME" '.cloudflare.tunnel_hostname // empty')"
PROVISION_ARGS=(--name "$NAME" --region "$REGION" --plan "$PLAN" --yes)
[ -n "$TUNNEL_HOST" ] && PROVISION_ARGS+=(--cloudflare-tunnel --cloudflare-hostname "$TUNNEL_HOST")

HV="$INV/host_vars/$NAME"
count() { [ -f "$HV/$1" ] && python3 -c "import sys,yaml; print(len((yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2]) or []))" "$HV/$1" "$2" || echo 0; }

cat <<PLAN

Rebuild plan for $NAME
  Server:   $PLAN in $REGION$( [ -n "$TUNNEL_HOST" ] && echo ", tunnel $TUNNEL_HOST" )
  Vhosts:   $(count vhosts.yml vhosts)   (host_vars/$NAME/vhosts.yml)
  PHP apps: $(count apps.yml apps)   (host_vars/$NAME/apps.yml$(grep -q '^php_app_safe_mode: *true' "$HV/apps.yml" 2>/dev/null && echo ', SAFE MODE'))
  Sites:    $(count sites.yml sites)   (host_vars/$NAME/sites.yml)

This DESTROYS $NAME and everything on it, then builds it again.
PLAN
if ! $ASSUME_YES; then
  read -r -p "Type the server name to continue: " answer
  [ "$answer" = "$NAME" ] || die "Aborted."
fi

step() { echo; echo "=================== $* ==================="; }
playbook() {
  ANSIBLE_CONFIG="$REPO/ansible.cfg" ansible-playbook -i "$INV" "$REPO/playbooks/provisioning/$1" -l "$NAME" "${@:2}"
}
resume() { warn "Step failed: $1. Fix it, then resume from there: $2"; exit 1; }

START=$(date +%s)
step "1-2/8 destroy (keeping inventory)"
"$HERE/bin/destroy-server.sh" "$NAME" --yes --keep-config || resume destroy "$HERE/bin/destroy-server.sh $NAME --yes --keep-config"

step "3/8 provision"
"$HERE/bin/provision-server.sh" "${PROVISION_ARGS[@]}" || resume provision "$HERE/bin/provision-server.sh ${PROVISION_ARGS[*]}"

step "4/8 vhosts"
playbook vhosts.yml || resume vhosts "ansible-playbook -i provisioning/inventory playbooks/provisioning/vhosts.yml -l $NAME"

if [ -f "$HV/apps.yml" ]; then
  step "5/8 PHP apps"
  playbook php_apps.yml || resume apps "ansible-playbook -i provisioning/inventory playbooks/provisioning/php_apps.yml -l $NAME"
fi

if [ -f "$HV/sites.yml" ]; then
  step "6/8 Jekyll sites"
  "$REPO/provisioning/bin/publish-sites.sh" "$NAME" || resume sites "provisioning/bin/publish-sites.sh $NAME"
fi

step "7/8 GoAccess"
playbook goaccess.yml || resume goaccess "ansible-playbook -i provisioning/inventory playbooks/provisioning/goaccess.yml -l $NAME"

step "8/8 smoke test"
if "$REPO/provisioning/bin/smoke-test.sh" "$NAME"; then
  log "Rebuild of $NAME complete in $(( ($(date +%s) - START) / 60 )) minutes."
else
  warn "Rebuild finished but the smoke test found problems (above). Re-check with: provisioning/bin/smoke-test.sh $NAME"
  exit 1
fi
