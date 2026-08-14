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

`common/` holds helpers shared by the Proxmox toolkit (SSH multiplexing,
Cloudflare API wrapper, UDM/UniFi API wrapper, structured logging, remote
installers). The BinaryLane toolkit predates that split and keeps its own
copies of the equivalent helpers under `binarylane/lib/` and
`binarylane/scripts/` — deliberately left alone rather than merged, so
changes to one can't destabilize the other.

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
