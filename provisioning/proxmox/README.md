# Proxmox LXC Provisioning

Repeatable provisioning of Ubuntu LXC containers on a Proxmox cluster, with
split-horizon DNS (internal via a UniFi Dream Machine, external via
Cloudflare Tunnel) and trusted HTTPS on both paths. This is the preferred
provisioning method in this repo — see [`../binarylane/README.md`](../binarylane/README.md)
for provisioning a cloud VM instead (e.g. when you need public hosting
outside your own network).

## Architecture

```
                       INTERNET
                           |
                     Cloudflare DNS
                           |
                    Cloudflare Tunnel
                           |
                     +-------------+
                     | Proxmox LXC |
                     |   host001   |
                     +-------------+
                           ^
                           |
LAN Client ---> UDM Pro DNS
                    |
     host001.in.example.com          (internal FQDN, always local)
     app.example.com (public hostname, LOCAL OVERRIDE -> internal FQDN)
                    |
                    +----> your LAN subnet (see IP allocation)
```

External traffic goes through Cloudflare Tunnel; internal traffic stays on
the LAN via split DNS. No unnecessary hairpinning through Cloudflare for
local clients, and no ports opened on the router's WAN interface. This
applies to **both** the internal FQDN and the public hostname — a LAN client
resolving `app.example.com` never leaves the network, while an external
resolver querying the same name gets Cloudflare's normal answer.

**Two independent things**, easy to conflate:
- **Internal FQDN** (`host001.in.example.com`) — the container's own
  identity, resolved only on the LAN, used for SSH/admin and for HTTPS
  issued via DNS-01 (see below).
- **Public hostname** (anything, e.g. `app.example.com`) — optional, only
  configured when `--public-hostname` is passed, routed through a dedicated
  Cloudflare Tunnel for external clients, and through a local DNS override to
  the internal FQDN for LAN clients. Doesn't have to share a domain with the
  internal FQDN.

## Prerequisites

- `jq`, `curl`, `ssh`, `dig`, `openssl` on the control host
- A Proxmox API token with `VM.*`/`Datastore.*`/`Sys.*` on the nodes you'll
  provision to. Proxmox's "API token privilege separation" means a token
  doesn't inherit its user's permissions unless privilege separation is
  disabled on the token or it has its own ACL entry — if every API call
  after auth returns `403`, this is almost always why.
- A Cloudflare API token with DNS-edit on the zones you'll use, plus
  Tunnel:Edit
- A UniFi Dream Machine (or other UniFi OS gateway) if you want the internal
  DNS + DHCP reservation automation — the toolkit still works without it,
  just without that piece (see "Internal DNS" below)
- Network reachability from the control host to the Proxmox API (`8006`) and
  the UDM's local API

## Credentials

All in `<repo root>/.api-auth.env` (mode 600, gitignored):

| Variable | Purpose |
|---|---|
| `PROXMOX_TOKEN_ID`, `PROXMOX_API_SECRET` | Proxmox API token |
| `PROXMOXHOST1`–`PROXMOXHOST4` | Cluster node IPs/hostnames — the toolkit tries each until one responds |
| `CLOUDFLARE_API_TOKEN` | DNS edit (all zones you use) + Tunnel edit |
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account id (non-secret) — from the dashboard or `GET /accounts` |
| `UbiquitiRouter`, `UbiquitiKey` | UDM local API key (Network Integration API + legacy REST) |
| `BESZEL_UNIVERSAL_CODE` | Optional — only needed if you use the default Beszel monitoring agent |

Never printed, logged, or committed — `lib/common.sh`'s `load_*_creds()`
functions parse the file directly and nothing is copied elsewhere.

**UDM key**: create it as a local **Network Integration** key in UniFi OS,
not a personal/cloud API key — they look similar but aren't interchangeable,
and a mismatched key type reliably shows up as `401`.

## Directory layout

```
provisioning/
├── common/                        # shared across backends (this toolkit only —
│   │                               # binarylane/ keeps its own copies, see ../README.md)
│   ├── logging.sh
│   ├── ssh.sh                     # SSH multiplexing, wait_for_ssh()
│   ├── cloudflare.sh              # cf_api(), zone resolution, tunnel create/reuse
│   ├── udm.sh                     # udm_api(), DHCP reservation + local DNS record
│   ├── install-cloudflared-remote.sh
│   └── install-beszel-agent.sh
└── proxmox/
    ├── bin/
    │   ├── provision-container.sh
    │   ├── destroy-container.sh
    │   ├── add-vhost.sh                 # attach another public hostname to an existing container
    │   └── deploy-mariadb-stack.sh      # deploy the MariaDB/phpMyAdmin/Traefik stack
    ├── lib/common.sh              # config, credentials, pve_api()
    ├── scripts/                   # copied to the container and run there over ssh
    │   ├── bootstrap-container.sh       # admin user + base packages
    │   ├── install-cloudflare-tunnel.sh # orchestrates the tunnel (runs on the control host)
    │   ├── update-tunnel-ingress.sh
    │   ├── install-https-dns01.sh       # DNS-01 cert issuance
    │   ├── install-test-vhost.sh        # minimal Apache welcome page(s)
    │   ├── install-docker.sh
    │   └── install-mariadb-stack.sh
    ├── state/                     # per-container JSON, gitignored
    └── config.example.env         # copy to config.env (gitignored) and edit
```

## Provisioning a container

```bash
cd provisioning/proxmox
./bin/provision-container.sh --hostname host001
```

Auto-picks the next free `hostNNN` if `--hostname` is omitted. Prints a full
plan and asks for confirmation before creating anything (`--yes` to skip,
`--dry-run` to just see the plan).

```bash
# With external access and internal HTTPS:
./bin/provision-container.sh \
  --hostname host003 \
  --public-hostname app.example.com \
  --enable-tls \
  --cores 2 --memory 2048 --disk 30
```

| Flag | Purpose |
|---|---|
| `--hostname NAME` | Logical hostname; FQDN = `NAME.<INTERNAL_DOMAIN>` |
| `--cores` / `--memory` / `--disk` | vCPUs / RAM (MB) / rootfs (GB) |
| `--node NAME` | Force a specific Proxmox node (default: auto-pick one with the template cached) |
| `--vlan TAG` | VLAN tag for the NIC (default: `PVE_VLAN_TAG`, empty = native) |
| `--public-hostname FQDN[,FQDN...]` | Expose externally via a dedicated Cloudflare Tunnel; comma-separated list attaches more than one at creation time |
| `--enable-tls` | Issue a Let's Encrypt cert for the internal FQDN via DNS-01 |
| `--skip-web` | Skip the minimal Apache test vhost (on by default) |
| `--skip-beszel` | Skip the Beszel monitoring agent (on by default) |
| `--dry-run` / `--yes` | Preview only / skip the confirmation prompt |

### What it does

1. Auto-picks or validates the hostname against local state and live
   Proxmox containers — refuses on a name collision.
2. Picks a Proxmox node that already has the Ubuntu template cached
   (downloads it if none do), gets the next free VMID.
3. Creates an unprivileged LXC (`start=1`, `onboot=1`) with a pre-generated
   MAC address, for the DHCP reservation step below.
4. Waits for a DHCP lease, then SSH as `root` (the template's only account)
   and runs `bootstrap-container.sh`: creates the admin user (sudo,
   `NOPASSWD`, SSH key installed, password locked), updates packages,
   installs base tooling (`curl wget git jq ufw htop bwm-ng vnstat` +
   `unattended-upgrades`), sets timezone/hostname, opens SSH in `ufw`.
5. If `--public-hostname`: creates/reuses a dedicated Cloudflare Tunnel,
   then a local DNS override so the hostname resolves directly to the
   container on the LAN.
6. If `--enable-tls`: issues a Let's Encrypt cert for the internal FQDN via
   DNS-01.
7. Unless `--skip-web`: installs a minimal Apache welcome page so there's
   something real to verify HTTP/HTTPS against.
8. Writes `state/<hostname>.json` (non-secret) and a human-readable record
   under `<repo root>/provisioned-servers/`.

### SSH key

Uses `PROVISIONING_SSH_KEY` (default `~/.ssh/homelab_provisioning`) — not a
freshly generated one, so it can reuse a key you already trust and have
distributed.

```bash
ssh -i ~/.ssh/homelab_provisioning localadmin@<fqdn>
```

## IP allocation

A MAC address is generated up front and a fixed-IP DHCP reservation + local
DNS record created via the UDM API *before* the container exists, so it gets
the reserved address (and working DNS) from its first DHCP request in the
common case. Reservation IPs come from `UDM_RESERVATION_RANGE_START`–`UDM_RESERVATION_RANGE_END`
— keep this range outside your dynamic DHCP pool.

The reservation doesn't always take effect on the very first DHCP request —
if the first lease doesn't match the reservation, `provision-container.sh`
reboots the container once (forcing a fresh DHCP negotiation) and re-checks,
rather than assuming either the first IP or a passive later renewal.

## Internal DNS (UDM Pro)

Uses the UDM's **legacy per-site REST API**
(`/proxy/network/api/s/{site}/rest/user`) for DHCP reservations and local DNS
records — the newer Integration API doesn't expose those yet. Verifies
resolution by querying the UDM directly (`dig <fqdn> @<udm-ip>`) rather than
just trusting the API call succeeded, since propagation isn't always instant.

Deleting a reservation for a client that has actually connected requires
`POST cmd/stamgr {"cmd":"forget-sta","macs":[...]}` rather than a plain
`DELETE` (which returns a `404` for connected clients even though `GET`
still shows the object) — `delete_dhcp_reservation` in `../common/udm.sh`
does this automatically.

## Split DNS — why DNS-01 for HTTPS, not HTTP-01

An internal-only domain (like `in.example.com`) is never publicly
resolvable, so Let's Encrypt's standard **HTTP-01** validation can never
work for it. **DNS-01** solves this by proving domain control through a
temporary TXT record via the Cloudflare API instead — works regardless of
whether a public A record exists at all. `install-https-dns01.sh` handles
this with `certbot` + `python3-certbot-dns-cloudflare`.

Covers the public hostname too: when a LAN client reaches
`--public-hostname` via the local DNS override, TLS terminates on the
container itself (not at Cloudflare's edge), so the cert needs the public
hostname as an extra SAN — `install-https-dns01.sh` checks the existing
cert's SANs first and expands rather than reissues.

**Gotcha**: `certbot --expand` does **not** union the requested `-d` list
with the cert's *existing* SANs — it replaces the domain list outright. A
cert with SANs `{A, B}`, expanded with only `-d A -d C`, silently drops `B`.
Always read the existing cert's SANs first and pass the full union
(existing ∪ new) — `install-https-dns01.sh` and `add-vhost.sh` both do this.

Credentials for the DNS-01 plugin live in `/etc/letsencrypt/cloudflare.ini`
on the container itself (mode 600, root-only) — necessary for unattended
renewal via certbot's own systemd timer. This means the broad Cloudflare
token is present on every container with `--enable-tls`; consider a
narrower DNS-only token if that blast radius is a concern for your setup.

## Cloudflare Tunnel (external access)

```bash
./bin/provision-container.sh --hostname host003 --public-hostname app.example.com
```

Creates/reuses a Cloudflare Tunnel named `<hostname>-tunnel`, installs
`cloudflared` on the container with only that tunnel's own connector token
(piped over SSH, never written to the control host's disk or logged), and
creates a proxied CNAME. The public hostname can be on any domain the
Cloudflare token can see — it's resolved independently, not assumed to
share a domain with the container's internal FQDN.

`cloudflared` is installed directly from its GitHub release `.deb`
(architecture-specific), not from Cloudflare's apt repo — the apt repo is
keyed by Ubuntu codename and lags behind on very new Ubuntu releases.

### Multiple public hostnames — `add-vhost.sh`

`provision-container.sh` only wires up one public hostname at creation time.
To add another to an already-running container:

```bash
./bin/add-vhost.sh host004 second.example.com
# non-interactively:
./bin/add-vhost.sh host004 second.example.com --yes
```

Reuses the container's existing tunnel (adds a route + new CNAME rather than
a second tunnel), creates a local DNS override, expands the TLS cert if one
exists, and installs a vhost with its own docroot. Refuses if the hostname
is already claimed by a *different* container; re-running for the *same*
container is treated as an idempotent repair.

## Local DNS override for the public hostname (no hairpin on LAN)

When `--public-hostname` is used, a local override on the UDM makes LAN
clients resolve the public hostname straight to the container's internal
FQDN instead of round-tripping through Cloudflare's edge. This uses UniFi's
general-purpose static-DNS store (`/proxy/network/v2/api/site/{site}/static-dns`),
distinct from the per-client mechanism used for internal FQDNs. Idempotent:
re-running with the same target is a no-op; a different target replaces the
record. This API has no in-place update (`PUT` rejects unconditionally,
`PATCH` isn't supported) — a repoint is delete-then-recreate.

`provision-container.sh` refuses upfront if `--public-hostname` is already
claimed by a different, non-destroyed container — without that check, a
second container with the same public hostname would silently steal the
first one's tunnel CNAME and local override.

## Test vhost

`--skip-web` disables it; on by default. The container gets a genuinely
separate vhost for the public hostname (own docroot, own welcome page) when
one is configured — otherwise Apache's single vhost would answer *any* Host
header with content labelled for the internal FQDN.

## MariaDB + phpMyAdmin + Traefik stack (Docker Compose)

Deployed onto an already-provisioned container, the same layering pattern as
`add-vhost.sh` rather than baked into `provision-container.sh`:

```bash
./bin/provision-container.sh --hostname db01 --enable-tls --skip-web
./bin/deploy-mariadb-stack.sh db01
```

```
LAN client --HTTPS(trusted cert)--> nginx :443 --http--> Traefik :8080 (127.0.0.1 only)
                                                                |
                                                           phpMyAdmin (Docker network)
                                                                |
                                                            MariaDB (Docker network)

Any host on your LAN --3306/tcp--> MariaDB directly (plain Docker-published port,
  restricted at the firewall)
```

- **nginx** (native, not Docker) terminates TLS with the same DNS-01
  certificate and reverse-proxies to Traefik.
- **Traefik** binds `127.0.0.1:8080` only — never reachable directly from
  the LAN — and auto-discovers phpMyAdmin via Docker labels.
- **MariaDB** publishes 3306 directly, restricted via a `DOCKER-USER`
  iptables chain rather than `ufw` — Docker manipulates iptables directly
  and inserts its own `ACCEPT` rules ahead of anything `ufw` would apply, so
  a `ufw` rule alone would be silently ignored for Docker-published ports.
  `install-mariadb-stack.sh` also allows the compose stack's own bridge
  subnet through the same chain — without it, container-to-container
  traffic on the same Docker network gets caught by the same rule meant for
  external sources (phpMyAdmin's own connection to MariaDB would otherwise
  hang).
- Stack lives at `~/docker/mariadb-stack/` on the container; credentials are
  generated on the container itself (never on the control host), shown once
  at the end of the run, never written to state or the provisioning record.

## Beszel monitoring agent

Installed by default on every container — connects outbound to an existing
Beszel hub, so nothing needs to be opened inbound. `--skip-beszel` opts a
container out.

```bash
./bin/provision-container.sh --hostname host008              # included by default
./bin/provision-container.sh --hostname host009 --skip-beszel
```

The hub's public key (`BESZEL_HUB_KEY`) is required even in
"universal token" mode — an empty value looks like it should work for
token-only registration but the agent hard-refuses to start without a key.
Get it from the hub's own Settings → Add System page.

## Provisioning records

`<repo root>/provisioned-servers/<hostname>.txt` (mode 600) — non-secret
fields only: hostname, FQDN, VMID, node, IP, MAC, OS, specs, DNS status,
public hostname, tunnel/override IDs, SSH command. Never API keys, tokens,
passwords, or private keys. `state/<hostname>.json` mirrors this for the
scripts themselves to read back.

## Destroying a container

```bash
./bin/destroy-container.sh host001
./bin/destroy-container.sh host001 --yes   # skip the confirmation prompt
```

Shows exactly what will be deleted — container, internal DNS/DHCP
reservation, tunnel and **every** public hostname attached to it — and
requires typing the FQDN back to confirm unless `--yes` is passed. Re-checks
the container's Proxmox config against local state before deleting; refuses
on a mismatch. The provisioning record is never deleted, just updated with a
`DESTROYED` block as an audit trail.

If a container was stopped/destroyed some other way (directly through the
Proxmox console), its tunnel/CNAME/DHCP reservation are left orphaned since
nothing outside this toolkit knows to clean them up — check manually via the
Cloudflare API and the UDM's client list.

## Verification checklist

```bash
ping <IP>
ssh -i ~/.ssh/homelab_provisioning localadmin@<fqdn>
curl -I http://<fqdn>/
dig <public-hostname> @<UDM IP>        # should return the container's own IP (local override)
dig <public-hostname> @8.8.8.8         # should return Cloudflare's edge IPs
curl -I https://<public-hostname>/
openssl x509 -in /etc/letsencrypt/live/<fqdn>/fullchain.pem -noout -dates
```

## Troubleshooting

- **`403 Permission check failed`** — the Proxmox token's privilege
  separation is on with no ACL of its own. Disable privilege separation on
  the token, or grant it `Datastore.*` + `Sys.*` directly.
- **Container never gets a DHCP lease** — check the VLAN tag; reconfigure
  `net0` without a `tag=` param and reboot to test the native network as a
  baseline.
- **UDM API `401`** — regenerate the key in UniFi OS; confirm it's a local
  Network Integration key, not a personal/cloud API key.
- **Container on the wrong IP** — the reservation can take a moment to
  propagate; `provision-container.sh` already reboots once to force a fresh
  request, but confirm the reservation exists via the UDM's REST API if it's
  still wrong after that.
- **`destroy-container.sh` refuses with a hostname mismatch** — don't force
  past this; local state and Proxmox disagree about which container this
  VMID actually is. Investigate before deleting anything.
- **Writing new retry loops in a `set -euo pipefail` script** — a plain
  `VAR="$(some_command)"` (not prefixed `local`) still aborts the whole
  script on failure, even inside a loop meant to retry. Tack on
  `|| echo <sentinel>` or `|| true` when capturing output for a check rather
  than for the exit code.
- **`curl <hostname>` hangs for 10+ seconds even though `dig` answers
  instantly** — some UniFi DNS servers hang rather than answering quickly
  with "no AAAA record" for names in their own authoritative zone; tools
  doing dual-stack lookups eat that timeout before falling back to IPv4.
  Workarounds: `curl -4`, `curl --resolve <host>:<port>:<ip>`.
- **`Could not establish SSH as root within the timeout` but the container
  is actually reachable** — almost always a stale SSH host key from a
  previous container that reused the same reservation IP. `wait_for_ssh()`
  in `../common/ssh.sh` already clears stale entries for a freshly-created
  container's IP; if it still happens (e.g. calling `ssh`/`scp` directly),
  `ssh-keygen -f ~/.ssh/known_hosts -R <ip>` is the manual fix.

## Future work

- `--role webserver` / `--role docker` / etc. — deliberately not built yet;
  current structure (bootstrap + optional tunnel + optional TLS, each gated
  independently) should extend cleanly to a `--role` flag later.
- A narrower, DNS-only Cloudflare token for `--enable-tls` specifically, if
  the shared-token blast radius becomes a concern for your setup.
