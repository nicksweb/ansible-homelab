#!/usr/bin/env bash
# smoke-test.sh <server> — checks a provisioned LAMP server end to end:
# every declared vhost answers over HTTPS through Cloudflare, the core
# services run, CrowdSec's bouncers are registered and the stats timer is on.
# Exit status is the number of failed checks (0 = all good). Run from a
# trusted address (office/tailnet), since `access: trusted` vhosts refuse
# everyone else.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INV="$REPO/provisioning/inventory"
SERVER="${1:?usage: smoke-test.sh <server>}"

HOSTVARS="$(ANSIBLE_CONFIG="$REPO/ansible.cfg" ansible-inventory -i "$INV" --host "$SERVER" 2>/dev/null)" \
  || { echo "$SERVER isn't in the provisioned inventory." >&2; exit 1; }
TARGET="$(jq -r '.ansible_user + "@" + .ansible_host' <<<"$HOSTVARS")"
KEY="$(jq -r '.ansible_ssh_private_key_file' <<<"$HOSTVARS")"

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

echo "== Sites (HTTPS through Cloudflare, redirects followed)"
mapfile -t HOSTS < <(python3 - "$INV/host_vars/$SERVER/vhosts.yml" <<'PY'
import sys, yaml
try:
    vs = (yaml.safe_load(open(sys.argv[1])) or {}).get("vhosts") or []
except FileNotFoundError:
    vs = []
for v in vs:
    v = {"hostname": v} if isinstance(v, str) else v
    if v.get("state", "present") == "present":
        print(v["hostname"])
PY
)
for h in "${HOSTS[@]}"; do
  code="$(curl -s -o /dev/null -L --max-time 25 -w '%{http_code}' "https://$h/?smoke=$(date +%s)")"
  [ "$code" = 200 ] && ok "https://$h/ ($code)" || bad "https://$h/ ($code)"
done

echo "== PHP apps (each at its own URL; apps.yml smoke_path overrides)"
mapfile -t APP_URLS < <(python3 - "$INV/host_vars/$SERVER/apps.yml" <<'PY'
import sys, yaml
try:
    apps = (yaml.safe_load(open(sys.argv[1])) or {}).get("apps") or []
except FileNotFoundError:
    apps = []
for a in apps:
    path = a.get("smoke_path") or (("/" + a["path"].strip("/") + "/") if a.get("path") else "/")
    print("%s https://%s%s" % (a["name"], a["hostname"], path))
PY
)
for row in "${APP_URLS[@]}"; do
  name="${row%% *}"; url="${row#* }"
  code="$(curl -s -o /dev/null -L --max-time 25 -w '%{http_code}' "$url")"
  [ "$code" = 200 ] && ok "$name $url ($code)" || bad "$name $url ($code)"
done

echo "== Server"
OUT="$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" '
  for s in apache2 mysql cloudflared crowdsec crowdsec-firewall-bouncer crowdsec-custom-bouncer; do
    printf "svc %s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  for u in $(systemctl list-units --type=service --no-legend "php*-fpm.service" | awk "{print \$1}"); do
    printf "svc %s %s\n" "$u" "$(systemctl is-active "$u")"
  done
  printf "timer goaccess-report %s\n" "$(systemctl is-active goaccess-report.timer 2>/dev/null)"
  printf "bouncers %s\n" "$(sudo cscli bouncers list -o json 2>/dev/null | jq -r "length" 2>/dev/null)"
  printf "swap %s\n" "$(swapon --noheadings --show=SIZE | head -1)"
  printf "mem %s\n" "$(free -m | awk "/Mem/{print \$3\"/\"\$2\"MB\"}")"
' 2>/dev/null)" || bad "ssh to $TARGET"
while read -r kind name state; do
  case "$kind" in
    svc|timer) [ "$state" = active ] && ok "$name $state" || bad "$name ${state:-missing}" ;;
    bouncers) [ "${name:-0}" -ge 2 ] 2>/dev/null && ok "CrowdSec bouncers registered: $name" || bad "CrowdSec bouncers registered: ${name:-0} (want 2)" ;;
    swap) [ -n "$name" ] && ok "swap $name" || bad "no swap" ;;
    mem) ok "memory used $name" ;;
  esac
done <<<"$OUT"

echo
[ "$fails" -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
exit "$fails"
