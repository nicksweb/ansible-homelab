# Server Provisioning Toolkits

Two independent, self-contained bash toolkits for turning a bare hostname
into a running, reachable, HTTPS-capable server — complementary to the
Ansible playbooks in this repo rather than replacing them. Provisioning
creates the machine and the DNS/tunnel/TLS around it; onboarding (`onboard-linux`,
`onboard-docker-host`, `playbooks/bootstrap.yml`, etc.) then applies the same
Ansible baseline to it as everything else in the inventory.

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
