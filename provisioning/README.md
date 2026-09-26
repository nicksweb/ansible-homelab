# Server Provisioning

Turns a bare hostname into a running, reachable, HTTPS-capable server, then
manages the websites (vhosts) on it. Creating the machine and wiring its
DNS/tunnel is done by small bash orchestrators per backend (`*/bin/`);
everything that runs *on* a server, and every vhost, is Ansible. This
replaces the old standalone `server-provisioning` repo.

| Toolkit | Backend | Use when |
|---|---|---|
| [`proxmox/`](proxmox/README.md) | Proxmox VE (LXC containers) | You have a Proxmox cluster/host and want free, fast, local capacity |
| [`binarylane/`](binarylane/README.md) | [BinaryLane](https://binarylane.com.au) (cloud VMs) | You need a publicly-hosted VM outside your own network, or don't run Proxmox |

BinaryLane servers come in two flavours: LAMP (default) or `--role docker`
(static sites in nginx + Nginx Proxy Manager behind a dedicated tunnel, with
NPM's direct 443 restricted to Cloudflare and trusted IPs) — see
[binarylane/README.md](binarylane/README.md#docker-static-site-servers---role-docker).

Both share the same design:

- **Split-horizon-friendly**: an internal DNS identity for SSH/admin, an
  optional public hostname routed through a dedicated Cloudflare Tunnel
  (one tunnel per server/container — never shared, so destroying one never
  risks another).
- **Idempotent, state-tracked**: each run writes non-secret JSON under its
  own `state/` (gitignored) so re-running is safe and `destroy-*` knows
  exactly what to tear down.
- **No secrets in git, ever**: API tokens live in one gitignored file
  (`.api-auth.env`) at the repo root, never in `config.env`, never in state,
  never printed to logs. See each toolkit's README for its exact credential
  format.
- **Plan-then-confirm**: every provisioning/destroy script prints what it's
  about to do and asks for confirmation (`--yes` to skip, `--dry-run` to
  just see the plan) before creating or deleting anything.

The bash scripts under `*/bin/` only orchestrate: cloud/Proxmox APIs,
Cloudflare, the UDM, Tailscale keys and local state. Everything that runs
*on* a server is an Ansible role under `playbooks/roles/provisioning/`,
invoked through `common/ansible.sh`. `common/` holds the helpers both
toolkits share (Cloudflare, UDM, Tailscale, SSH, logging, the Ansible
runner); `binarylane/lib/` keeps the BinaryLane-specific ones.

## Server types compared

Three kinds of server, one vhost workflow (see [Vhosts](#vhosts-ansible)).

| | BinaryLane LAMP | BinaryLane docker | Proxmox LXC |
|---|---|---|---|
| Create with | `binarylane/bin/provision-server.sh` | `... --role docker --cloudflare-tunnel` | `proxmox/bin/provision-container.sh` |
| Lives | Public cloud | Public cloud | Office LAN |
| Web stack | Apache + PHP-FPM, local MySQL (or `--skip-mysql` / `--db-only` variants) | `web` nginx container for static sites, Nginx Proxy Manager, MariaDB container | Apache (optional MariaDB/phpMyAdmin stack via `deploy-mariadb-stack.sh`) |
| In front of the web server | Nothing — Apache answers 80/443 itself | NPM on 443 (direct path); the tunnel goes straight to the container | Nothing — Apache answers 80/443 itself |
| Host firewall (ufw) | SSH, and 80/443 **open to everyone** | SSH only. NPM's published 443 is restricted in the `DOCKER-USER` chain to Cloudflare's ranges + `TRUSTED_443_IPS` (ufw can't see Docker ports) | SSH, and 80/443 (LAN-only address) |
| SSH | Key-only, fail2ban, management IP always allowed; also Tailscale SSH | Same | Key-only on the LAN; Tailscale optional (`enable-tailscale.sh`) |
| Server's own name | `<name>.<domain>` — DNS-only A record, for SSH; not a website | Same | `<name>.<internal domain>` — UDM DHCP reservation |
| Public path for a vhost | Cloudflare → tunnel (systemd `cloudflared`) → Apache :80 | Cloudflare → tunnel (`cloudflared` container) → `web:80` or the vhost's `service` | Cloudflare → tunnel (systemd `cloudflared`) → Apache :80 |
| LAN path for a vhost (UDM) | `<vhost>` CNAME → `<name>.<domain>` A → public IP → Apache :443 | Same, → NPM :443 → `web:80` / `service` | `<vhost>` CNAME → `<name>.<internal domain>` → LAN IP → Apache :443 |
| Vhost options | `php: none \| highest \| 8.3` | `service: http://container:port` | — |
| Monitoring | Beszel agent → hub over the tailnet | Same | Beszel agent → hub's internal URL |

### TLS certificates

Every vhost has two certificates, one per path:

- **Public visitors** get Cloudflare's edge certificate (Universal SSL),
  issued and renewed by Cloudflare automatically. It covers `example.com`
  and `*.example.com` only — a deeper name like `a.b.example.com` needs an
  Advanced Certificate in Cloudflare.
- **LAN clients on the direct path** get a Let's Encrypt certificate issued
  on the server itself by the `certbot_dns01` role: DNS-01 through the
  Cloudflare API, so it works for any name regardless of routing, one cert
  per vhost. `certbot.timer` renews it (twice daily check, renews within 30
  days of expiry) using the stored `/etc/letsencrypt/cloudflare.ini`, and a
  deploy hook (`/etc/letsencrypt/renewal-hooks/deploy/reload-web`) reloads
  Apache, or NPM's nginx on a docker server, so the new cert is served.

## Vhosts (Ansible)

Once a server exists, what it *serves* is declared in the Ansible
inventory and converged by one playbook — for BinaryLane LAMP and
`--role docker` servers and Proxmox containers alike.

- **Inventory:** `provisioning/inventory/provisioned.py` lists every live
  server straight from the toolkits' `state/` (groups `provisioned` >
  `binarylane`, `proxmox_lxc`), so it never needs updating by hand.
  It isn't in `ansible.cfg`'s default inventory — pass
  `-i provisioning/inventory`.
- **Declared vhosts:** `provisioning/inventory/host_vars/<server>/vhosts.yml`
  (gitignored). Format and options (`service`, `udm`, `takeover`,
  `state: absent`) in `playbooks/roles/provisioning/vhosts/defaults/main.yml`.

```bash
# from the repo root
ansible-playbook -i provisioning/inventory playbooks/provisioning/vhost_add.yml    -l web01 -e vhost=shop.example.com
ansible-playbook -i provisioning/inventory playbooks/provisioning/vhost_remove.yml -l web01 -e vhost=shop.example.com
ansible-playbook -i provisioning/inventory playbooks/provisioning/vhosts.yml [-l web01]   # converge after editing vhosts.yml
```

Per vhost: a DNS-01 cert, the web server config (Apache on a LAMP server or
container; the `web` container plus an NPM server block on a docker
server), a route
on the server's dedicated tunnel and a proxied Cloudflare CNAME. Then the
direct HTTPS path is tested from the control host, and only if it works
does the UDM get a record, so LAN clients go straight to the server:

| Server | UDM static DNS |
|---|---|
| Proxmox container | `<vhost>` CNAME → `<container fqdn>` (its DHCP-reservation record) |
| BinaryLane docker server | `<server fqdn>` A → public IP, and `<vhost>` CNAME → `<server fqdn>` (the office IP is on the server's 443 allow-list) |
| BinaryLane LAMP server | as above — Apache answers 443 directly |

If the direct path stops working, the next run withdraws the UDM record, so
LAN clients fall back to Cloudflare instead of breaking. `destroy-*.sh` removes
every declared vhost's CNAME and UDM records, then archives its host_vars.


## Getting started

```bash
cd provisioning/proxmox      # or provisioning/binarylane
cp config.example.env config.env   # edit as needed — never put secrets here
```

Then create `.api-auth.env` at the repo root (mode 600) with the credentials
your chosen toolkit needs — see its README for the exact variable names.
Both toolkits read from this same file, so one file covers both if you ever
use both.

```bash
chmod 600 .api-auth.env
```
