# BinaryLane / Cloudflare Server Provisioning

Repeatable provisioning of Ubuntu 24.04 LAMP servers on [BinaryLane](https://binarylane.com.au)
Cloud, with a Cloudflare DNS identity and optional exposure through a
dedicated Cloudflare Tunnel. Run from your Ansible control host.

> For new provisioning, prefer [`../proxmox/README.md`](../proxmox/README.md)
> if you run a Proxmox cluster — it's free, local capacity with the same
> split-horizon DNS and Cloudflare Tunnel pattern. This toolkit is for when
> you specifically need a publicly-hosted cloud VM (or don't run Proxmox).

## Prerequisites

- `jq`, `curl`, `dig`, `ssh`, `envsubst` on the control host
- A BinaryLane account and API token
- A Cloudflare API token with DNS-edit on the zone(s) you'll use, plus
  Tunnel:Edit if you'll use `--cloudflare-tunnel`

## Credentials

All in `<repo root>/.api-auth.env` (mode 600, gitignored) — shared with the
Proxmox toolkit if you use both:

| Variable | Purpose |
|---|---|
| `BINARYLANE_API_KEY` | Full BinaryLane account API access |
| `CLOUDFLARE_API_TOKEN` | DNS edit + Tunnel edit |

`lib/common.sh` also supports legacy per-toolkit fallback files
(`<repo root>/.binarylane`, `binarylane/.cloudflare`) if you'd rather keep
credentials split — both are gitignored. `.api-auth.env` is checked first.

## Provisioning a new server

```bash
cd provisioning/binarylane
cp config.example.env config.env   # edit as needed
./bin/provision-server.sh --name webserver01
```

Prints a full plan (region, plan, image, DNS, cost) and asks for
confirmation before creating anything chargeable. `--yes` skips the prompt,
`--dry-run` shows the plan without proceeding.

Result: `webserver01.<SERVER_DOMAIN>`, Ubuntu 24.04, LAMP stack installed,
hardened, DNS created, reboot-tested, and a record written to
`<repo root>/provisioned-servers-webserver01.txt`.

| Flag | Purpose |
|---|---|
| `--name NAME` | Logical server name (required); FQDN = `NAME.<domain>` |
| `--domain DOMAIN` | Override `SERVER_DOMAIN` for this server — validated against the live Cloudflare zone list |
| `--region` / `--plan` / `--image` | BinaryLane region/size/image slugs |
| `--cloudflare-tunnel` | Enable tunnel exposure (requires `--cloudflare-hostname`) |
| `--cloudflare-hostname FQDN` | Public hostname routed through this server's own dedicated tunnel |
| `--cloudflare-proxy on\|off` | Proxy mode for the base A record (default off — DNS-only, so direct SSH-by-hostname keeps working) |
| `--enable-tls` | Let's Encrypt cert for the server's own base FQDN |
| `--skip-lamp` / `--skip-mysql` | Skip the LAMP install entirely, or install Apache/PHP without local MySQL |
| `--db-only` / `--db-allow-from IP[,IP...]` | Standalone MySQL server, firewalled to exactly the given IP(s) |
| `--skip-harden` | Skip SSH/firewall hardening (not recommended) |
| `--dry-run` / `--yes` | Preview only / skip the confirmation prompt |

Naming: a valid DNS label (lowercase alphanumeric + hyphens, ≤63 chars).
State/records are keyed by `--name` alone, not `name+domain` — two servers
can't share a short name even on different domains.

### Region and capacity fallback

BinaryLane occasionally has no host capacity for a given region+size right
now. `provision-server.sh` tries `BINARYLANE_REGION_FALLBACK` in order
(the requested region first) and only fails if none of them have capacity —
it stops immediately on any other kind of error (validation, auth) rather
than blindly cycling regions.

### Using a different domain

`--domain` only gets you a genuinely working public hostname if that
domain's nameservers are actually delegated to Cloudflare — having "a zone
for it" in the Cloudflare account isn't enough on its own (some free
dynamic-DNS-style domains serve every subdomain from their own
infrastructure via a wildcard regardless of what Cloudflare has configured).
Check `dig NS <domain> @1.1.1.1` actually returns Cloudflare's nameservers
before relying on the hostname.

## SSH access

A dedicated Ed25519 key (`PROVISIONING_SSH_KEY`, default
`~/.ssh/binarylane_provisioning_ed25519`) is created automatically on first
use and injected via cloud-init. Password SSH and root login are disabled by
`scripts/harden-ssh.sh` only after a second, independent SSH session has
confirmed key auth works — hardening never runs blind. It runs in two
externally-verified stages (`harden-ssh.sh` then `harden-fail2ban.sh`), with
a reachability check after each, so a lockout is caught immediately after
the specific change that caused it.

```bash
./bin/ssh-server.sh webserver01
```

### Recovery if SSH becomes unavailable

1. Use BinaryLane's dashboard/API recovery console — doesn't depend on SSH.
2. `./bin/server-status.sh <name>` separately reports API status, DNS
   resolution, and SSH reachability, which usually narrows down whether it's
   DNS, network, or an sshd-config problem.
3. If hardening was interrupted mid-way, the dropped-in sshd config is at
   `/etc/ssh/sshd_config.d/99-provisioning-hardening.conf` — remove it via
   the recovery console and reload `ssh` to restore password auth as a
   stopgap.

## Cloudflare DNS

Every server gets an A record `<name>.<domain> -> <public IPv4>`.
Re-running provisioning for the same name updates the record rather than
duplicating it. `--cloudflare-proxy on` enables the Cloudflare proxy — off
by default because a proxied A record breaks direct SSH-by-hostname.

## Cloudflare Tunnel (optional)

Each server gets its own dedicated tunnel — not shared across servers, so
destroying one server can never affect another's.

```bash
./bin/provision-server.sh --name webserver02 \
  --cloudflare-tunnel --cloudflare-hostname app.example.com
```

Orchestrated from the control host: creates/reuses a tunnel named
`<name>-tunnel`, fetches a connector token scoped to only that tunnel
(piped over SSH, never written to disk or logged), installs `cloudflared`
on the server, and creates a proxied CNAME. TLS terminates at Cloudflare's
edge for tunnel-routed hostnames — no certbot needed there.
`--cloudflare-hostname` must differ from the server's own base FQDN, since
that stays a plain DNS-only A record reserved for SSH/admin.

`destroy-server.sh` deletes the dedicated tunnel unconditionally — safe
since it belongs to exactly one server.

## Adding websites to a provisioned server

```bash
./bin/add-site.sh webserver01 shop example.com 8.3
./bin/add-site.sh webserver01 @ example.com php     # apex domain, highest installed PHP
./bin/add-site.sh webserver02 status example.com none   # static site
```

Creates a webroot + Apache vhost and wires Cloudflare DNS. Routing depends
on how the server was provisioned: a server with `--cloudflare-tunnel` gets
an ingress rule added to its own tunnel + a proxied CNAME; a server without
one gets a direct A record (proxied by default; `--proxy off` for DNS-only,
e.g. if you'll run `certbot --apache` yourself). The domain is validated
against the live Cloudflare zone list first. Idempotent — re-running for the
same hostname reuses the existing webroot/vhost/DNS record.

## Splitting DB and web servers

For a two-tier setup — dedicated DB server plus one or more app servers:

```bash
# 1. App server first (need its IP for the DB firewall rule)
./bin/provision-server.sh --name app01 --region sin --skip-mysql \
  --cloudflare-tunnel --cloudflare-hostname app.example.com --enable-tls

# 2. DB server, restricted to only that app server's IP
./bin/provision-server.sh --name db01 --region sin \
  --db-only --db-allow-from <app01's public IPv4 from its state file>

# 3. Actual vhost content
./bin/add-site.sh app01 app example.com php
```

`--db-only` skips Apache/PHP/certbot entirely and installs standalone MySQL,
relying on `ufw allow from <ip> to any port 3306` for each address in
`--db-allow-from` — nothing else restricts access. The app-user MySQL grant
is also scoped per source IP (`'appuser'@'<app-server-ip>'`, never `%`), so
a misconfigured firewall rule alone wouldn't be enough to expose it.

Credentials (root + app-user) are generated on the DB server itself, shown
once at the end of the run, and stored at
`/etc/mysql-provisioning-credentials.env` (mode 600) — never written to the
control host. Retrieve them again with:

```bash
./bin/ssh-server.sh db01 -- sudo cat /etc/mysql-provisioning-credentials.env
```

### Widening access on an existing `--db-only` server

`provision-server.sh` refuses to re-run against an existing server — that's
a duplicate-creation safety check, not an incremental-update path. Use
`db-allow-ip.sh` instead:

```bash
./bin/db-allow-ip.sh db01 "203.0.113.10,2001:db8::/32"     # MySQL access only
./bin/db-allow-ip.sh db01 "203.0.113.10" --phpmyadmin       # + phpMyAdmin GUI
```

Merges the new IPs with whatever's already in state (deduplicated) and
re-applies — safe to run repeatedly, including for IPv6 ranges on a server
that doesn't have IPv6 enabled yet (the rules are just inert until it does).
phpMyAdmin connects over the local Unix socket (no new MySQL grant needed);
enabling it also replaces the from-anywhere `ufw allow 80/443` rules that
`harden-ssh.sh` leaves on every server with rules scoped to the same
allow-list as MySQL.

Every server this toolkit creates has `ipv6: false` — no IPv6 address at
all, so IPv6 firewall rules can be pre-staged but can't matter until IPv6 is
actually enabled for that server.

## What software gets installed

Apache 2 (rewrite/headers/ssl/proxy_fcgi), MySQL 8 (bound to `127.0.0.1`
only), PHP 8.3 (cli, fpm, mysql, curl, mbstring, xml, zip, gd, intl,
bcmath), Composer, Git, certbot, plus base admin tooling.

### TLS for the server's own hostname

```bash
./bin/provision-server.sh --name webserver01 --enable-tls
./bin/provision-server.sh --name webserver01 --enable-tls --letsencrypt-email you@example.com
```

Issues a Let's Encrypt certificate via certbot's `--apache` plugin for the
server's own base FQDN only — never the tunnel hostname, which already gets
TLS for free at Cloudflare's edge. Off by default (needs real public DNS
propagation to succeed); skips cleanly with a manual follow-up command if
DNS isn't ready rather than wasting a Let's Encrypt rate-limit attempt.
Idempotent — a rebuild under the same name detects the existing certificate.

## Security controls

- Key-only SSH (password auth + root login disabled after a verified second
  session)
- `ufw`: SSH, HTTP, HTTPS only; database port never opened publicly; your
  management host's IP (`MANAGEMENT_SSH_HOSTNAME`, resolved fresh each run)
  gets an explicit allow rule alongside the general SSH rule
- Fail2ban with an `sshd` jail, `ignoreip` covering the management IP,
  `banaction` pinned to `iptables-multiport`
- `unattended-upgrades` enabled
- MySQL bound to loopback only
- Dedicated provisioning SSH key, never reused from any other purpose,
  never leaves the control host

## Destroying a server

```bash
./bin/destroy-server.sh webserver01
./bin/destroy-server.sh webserver01 --yes
```

Shows exactly what will be deleted (server, A record, tunnel/CNAME if
applicable) and requires typing the FQDN back to confirm. Re-fetches the
server by ID from BinaryLane and checks its name still matches local state
before deleting. The provisioning record is updated in place with a
`DESTROYED` block rather than removed.

```bash
cat provisioned-servers-<name>.txt   # ends with a DESTROYED block + timestamp
jq .status state/<name>.json          # "DESTROYED"
```

## Idempotency

Re-running `provision-server.sh` for an existing (non-destroyed) name aborts
early. Each step is independently idempotent: SSH key upload (matched by
fingerprint), DNS records (matched by name, updated not duplicated), tunnel
ingress rules (matched by hostname), hardening drop-in (written once), apt
installs (naturally idempotent).

## Troubleshooting

- Server stuck in a non-`active` status — check the BinaryLane dashboard
  directly; the toolkit's own poll loop times out after ~10 minutes and
  leaves `state/<name>.json` at `status: "CREATING"` so it isn't lost.
- Cloudflare DNS not resolving — `dig <fqdn> @1.1.1.1`; the Cloudflare API
  confirming the record exists is authoritative, propagation is usually
  seconds but can occasionally take much longer, especially on zones with
  DNSSEC enabled (new records can lag behind the next signing pass).
- Tunnel ingress not taking effect — `sudo cat /etc/cloudflared/config.yml`,
  `sudo cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate`,
  `journalctl -u cloudflared -n 50 --no-pager`.

## What can't reasonably be automated

- Adding a brand-new Cloudflare zone/domain to the account.
- Issuing the first Let's Encrypt certificate for a non-tunnel site before
  DNS has actually propagated — run `certbot --apache` manually once
  confirmed reachable.
- BinaryLane account-level changes (payment, 2FA, contact info).
- Rotating or re-scoping the Cloudflare token itself — a dashboard step.
