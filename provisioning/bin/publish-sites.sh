#!/usr/bin/env bash
# publish-sites.sh <server> [site-hostname ...]
# publish-sites.sh --source <repo-dir>     (every server that lists that repo)
#
# Builds Jekyll sites on this (control) host and rsyncs them to <server>.
# Nothing is built on the server, and the server keeps no backups: history
# lives in each site's git repo. Sites are declared in
# provisioning/inventory/host_vars/<server>/sites.yml (gitignored):
#
#   sites:
#     - hostname: www.example.com          # the vhost it's published to
#       source: ~/src/example.com          # Jekyll repo on this host
#       extras: [api]                      # directories copied as-is next to _site
#       htaccess: webroot-htaccess         # file in the repo copied as .htaccess
#       preview: false                     # true: pre-prod copy of a live site, i.e.
#                                          #   - build with url: https://<hostname>
#                                          #   - let <hostname> through canonical-host
#                                          #     redirects in .htaccess
#
# With no site arguments, every declared site is published. Builds go to a
# temporary directory, never the repo's _site. projects/ under each webroot
# belongs to the PHP apps (php_app role) and is never touched here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INV="$REPO/provisioning/inventory"

# publish-sites.sh --source <repo-dir>: publish that repo to every server
# whose sites.yml lists it (what each site's bin/publish-remote calls).
if [ "${1:-}" = "--source" ]; then
  SRC_DIR="$(cd "${2:?usage: publish-sites.sh --source <repo-dir>}" && pwd -P)"
  mapfile -t TARGETS < <(python3 - "$INV/host_vars" "$SRC_DIR" <<'PY'
import glob, os, sys, yaml
hv, src = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(os.path.join(hv, "*", "sites.yml"))):
    server = os.path.basename(os.path.dirname(f))
    if ".destroyed-" in server:
        continue
    for s in (yaml.safe_load(open(f)) or {}).get("sites") or []:
        if os.path.realpath(os.path.expanduser(s["source"])) == src:
            print(server, s["hostname"])
PY
  )
  [ ${#TARGETS[@]} -gt 0 ] || { echo "$SRC_DIR isn't in any server's sites.yml — nothing to publish to." >&2; exit 1; }
  rc=0
  for t in "${TARGETS[@]}"; do
    "$0" ${t% *} ${t#* } || rc=1
  done
  exit $rc
fi

SERVER="${1:?usage: publish-sites.sh <server> [site-hostname ...] | --source <repo-dir>}"; shift
MANIFEST="$INV/host_vars/$SERVER/sites.yml"
[ -f "$MANIFEST" ] || { echo "No $MANIFEST — declare the server's sites there first." >&2; exit 1; }

HOSTVARS="$(ANSIBLE_CONFIG="$REPO/ansible.cfg" ansible-inventory -i "$INV" --host "$SERVER" 2>/dev/null)" \
  || { echo "$SERVER isn't in the provisioned inventory (not built, or destroyed)." >&2; exit 1; }
TARGET="$(jq -r '.ansible_user + "@" + .ansible_host' <<<"$HOSTVARS")"
KEY="$(jq -r '.ansible_ssh_private_key_file' <<<"$HOSTVARS")"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# One line per site: hostname<TAB>source<TAB>extras(,)<TAB>htaccess<TAB>preview
mapfile -t ROWS < <(python3 - "$MANIFEST" "$@" <<'PY'
import os, sys, yaml
manifest, wanted = sys.argv[1], set(sys.argv[2:])
sites = (yaml.safe_load(open(manifest)) or {}).get("sites") or []
known = {s["hostname"] for s in sites}
missing = wanted - known
if missing:
    sys.exit("Not declared in %s: %s" % (manifest, ", ".join(sorted(missing))))
for s in sites:
    if wanted and s["hostname"] not in wanted:
        continue
    print("\t".join([s["hostname"], os.path.expanduser(s["source"]),
                     ",".join(s.get("extras") or []), s.get("htaccess") or "",
                     "1" if s.get("preview") else "0"]))
PY
)
[ ${#ROWS[@]} -gt 0 ] || { echo "No sites to publish." >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r host src extras htaccess preview <<<"$row"
  dest="$WORK/$host"
  echo "==> $host  (from $src)"
  [ -f "$src/_config.yml" ] || { echo "    not a Jekyll site: $src" >&2; fail=1; continue; }

  configs="_config.yml"
  if [ "$preview" = 1 ]; then
    printf 'url: "https://%s"\n' "$host" > "$WORK/$host.preview.yml"
    configs="_config.yml,$WORK/$host.preview.yml"
  fi
  (
    cd "$src"
    bundle config set path vendor/bundle >/dev/null
    bundle install --quiet
    JEKYLL_ENV=production bundle exec jekyll build --quiet --config "$configs" --destination "$dest"
  ) || { echo "    build failed" >&2; fail=1; continue; }

  IFS=',' read -ra extra_dirs <<<"$extras"
  for d in "${extra_dirs[@]}"; do
    [ -n "$d" ] && [ -d "$src/$d" ] && rsync -a --delete "$src/$d/" "$dest/$d/"
  done
  [ -n "$htaccess" ] && [ -f "$src/$htaccess" ] && cp "$src/$htaccess" "$dest/.htaccess"
  if [ "$preview" = 1 ] && [ -f "$dest/.htaccess" ]; then
    HOSTRE="${host//./\\.}" perl -pi -e \
      's/^(\s*RewriteCond\s+%\{HTTP_HOST\}\s+!\^)(.+?)\$(?=\s)/$1(?:$2|$ENV{HOSTRE})\$/' "$dest/.htaccess"
  fi
  [ -s "$dest/index.html" ] || { echo "    build has no index.html — refusing to publish (would empty the live site)" >&2; fail=1; continue; }

  # --delay-updates + --delete-after: new files swap in at the end, so a
  # failed transfer never leaves a half-updated site.
  rsync -az --delete --delay-updates --delete-after --exclude=/projects/ \
    --rsync-path="sudo rsync" -e "${SSH[*]}" \
    "$dest/" "$TARGET:/var/www/html/sites/$host/public/" \
    || { echo "    rsync failed" >&2; fail=1; continue; }
  "${SSH[@]}" "$TARGET" "sudo chown -R www-data:www-data /var/www/html/sites/$host/public" || true

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$host/?publish=$(date +%s)")"
  printf '    published: https://%s/  (HTTP %s)\n' "$host" "$code"
  [ "$code" = 200 ] || fail=1
done
exit $fail
