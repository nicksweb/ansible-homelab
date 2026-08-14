# Ansible Homelab

Complete Ansible automation for managing a home laboratory infrastructure including Proxmox hypervisors, Docker servers, workstations, Raspberry Pi systems, and various service machines.

**Forked from**: [TiZuTech/ansible-homelab](https://github.com/TiZuTech/ansible-homelab)  
**Original blog**: https://tizutech.com

---

## 🚀 Quick Start (Returning After 2-6 Months?)

**Start here**: [GETTING_STARTED.md](GETTING_STARTED.md) - Quick reference for common tasks

Most common command:
```bash
# Update all Linux machines
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK
```

---

## 📚 Documentation

This project includes comprehensive documentation to help you work efficiently, even if you haven't touched it in months:

### For First-Time / Returning Users
- **[GETTING_STARTED.md](GETTING_STARTED.md)** - ⭐ Start here! Quick reference and common tasks
- **[ANSIBLE_CHEATSHEET.md](ANSIBLE_CHEATSHEET.md)** - Learning reference for commands, playbooks, variables, Vault, and troubleshooting
- **[REMOTE_CONTROL_NODE_RUNBOOK.md](REMOTE_CONTROL_NODE_RUNBOOK.md)** - Remote control node, WireGuard, inventory aliases, and SSH key rollout
- **[ADD_NEW_HOST.md](ADD_NEW_HOST.md)** - ⭐ Complete workflow for adding new machines
- **[QUICK_COMMANDS.md](QUICK_COMMANDS.md)** - Copy-paste one-liners for common operations (80+ commands)

### For Understanding the Project
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - How the infrastructure is organized and designed
- **[PLAYBOOKS_REFERENCE.md](PLAYBOOKS_REFERENCE.md)** - Complete documentation of all playbooks

### Configuration
- **[inventory.example](inventory.example)** - Safe inventory template to copy locally
- **[provisioning/README.md](provisioning/README.md)** - Bash toolkits that create the machine itself (Proxmox LXC / BinaryLane VM) before Ansible onboarding takes over
- **Local `inventory`** - Ignored by Git; contains your real machines and groups
- **[SSH_REFERENCE.md](SSH_REFERENCE.md)** - SSH host configuration reference

---

## 🏗️ Infrastructure Categories

This homelab manages multiple types of infrastructure:

- **Proxmox Hypervisors** (10 nodes) - VirtualEnvironment for VMs and LXC containers
- **Servers** - Ubuntu 24.04 LTS (Docker, LAMP, LibreNMS, Bitwarden, etc.)
- **Workstations/Desktops** - Ubuntu 24.04, PopOS, Debian for daily work
- **Raspberry Pi/ARM** - DNS servers, IoT devices
- **Surveillance** - Frigate video surveillance system

---

## 🎯 Main Capabilities

### System Maintenance
- ✅ Update/upgrade all machines with automatic reboot handling
- ✅ Check connectivity and gather facts from all hosts
- ✅ Bulk command execution across groups

### Machine Management
- ✅ Bootstrap new machines (users, SSH, sudo, build tools)
- ✅ Onboard new machines with complete setup (networking, SSH hardening, monitoring)
- ✅ Install and configure Docker on hosts
- ✅ LAMP stack setup (Apache, MySQL/MariaDB, PHP)
- ✅ NTP time synchronization
- ✅ Ansible/Jekyll/Bitwarden setup
- ✅ Test group for safe testing before production changes

### Infrastructure
- ✅ Network diagnostics (speedtest, ping, connectivity)
- ✅ Graceful shutdown of machines
- ✅ NTP synchronization across infrastructure

---

## 📋 Quick Examples

```bash
# Check all machines are online
ansible -i inventory all -m ping

# Update all Linux machines
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK

# Run command on specific group
ansible -i inventory docker -m shell -a "docker ps"

# Bootstrap new machine (add to 'setup' group first)
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "new_host"

# Gather system facts/info
ansible -i inventory all -m setup > homelab_facts.json

# Get disk space on all machines
ansible -i inventory all -m shell -a "df -h / | tail -1"
```

**See [QUICK_COMMANDS.md](QUICK_COMMANDS.md) for 80+ more examples!**

---

## 📁 Project Structure

```
ansible-homelab/
├── inventory              # Machine definitions (add/remove hosts here)
├── inventory.example      # Safe template; copy to ignored local inventory
├── ansible.cfg           # Ansible configuration
├── requirements.yml      # Galaxy role requirements
├── deploy-ansible-key    # Roll out the control node public key
├── enable-passwordless-sudo # Configure validated sudoers policy
├── onboard-linux        # Baseline Debian/Ubuntu onboarding
├── onboard-docker-host # Baseline plus Docker Engine and localadmin
├── run-speedtest         # Concurrent or sequential speed tests
├── update-proxmox       # Sequential Proxmox package maintenance
├── provisioning/         # Bash toolkits that create the machine itself (Proxmox LXC / BinaryLane VM)
│   ├── proxmox/          # Preferred: Proxmox LXC + split-horizon DNS + Cloudflare Tunnel
│   └── binarylane/       # Cloud VM alternative, same DNS/tunnel pattern
├── playbooks/            # All automation playbooks
│   ├── *-apt-*.yml      # System updates/upgrades
│   ├── bootstrap.yml     # Bootstrap new machines
│   ├── site-baseline.yml # Shared SSH key and timezone
│   ├── onboard-linux.yml # Monitoring, updates, NTP, and SNMP
│   ├── onboard-docker-host.yml # Linux baseline plus Docker
│   ├── desktop-workstation.yml # Desktop packages and Flatpaks
│   ├── proxmox-update.yml # Safe sequential Proxmox updates
│   ├── docker.yml        # Docker setup
│   ├── lamp.yml          # LAMP stack
│   ├── jekyll.yml        # Jekyll setup
│   └── roles/            # Reusable roles
├── GETTING_STARTED.md    # Quick reference (START HERE!)
├── ANSIBLE_CHEATSHEET.md # Learning-oriented Ansible reference
├── REMOTE_CONTROL_NODE_RUNBOOK.md # Remote-node operations and troubleshooting
├── SETUP_ANSIBLE_HOST.md # Setting up Ansible control node
├── ARCHITECTURE.md       # Design and organization
├── PLAYBOOKS_REFERENCE.md # All playbooks documented
├── QUICK_COMMANDS.md     # 80+ one-liner examples
├── SSH_REFERENCE.md      # SSH configuration reference
└── README.md             # This file
```

---

## 🔧 Requirements

### Prerequisites
- Python 3.x on Ansible control machine
- SSH key at `~/.ssh/ansible` (or configured in ansible.cfg)
- Access to target machines (IP addresses or hostnames)

### Install Requirements
```bash
# Install Galaxy roles
ansible-galaxy install -r requirements.yml

# Or individual roles:
ansible-galaxy install geerlingguy.ntp
ansible-galaxy install geerlingguy.docker
```

---

## 🚦 Getting Started

### 1. First Time Setup
```bash
# Clone this repository
git clone https://github.com/nicksweb/ansible-homelab
cd ansible-homelab

# Install requirements
ansible-galaxy install -r requirements.yml

# Test connectivity
ansible -i inventory all -m ping
```

### 2. Add Your Machines
Edit the `inventory` file to add your machines to appropriate groups:
```ini
[proxmox]
my-proxmox-host ansible_user=root

[docker]
my-docker-server

[ubuntu]
203.0.113.100
```

### 3. Run Common Tasks
```bash
# Update all machines
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK

# Bootstrap new machine
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "setup"
```

**For detailed getting started guide, see [GETTING_STARTED.md](GETTING_STARTED.md)**

---

## Provisioning new infrastructure

Before a machine can be onboarded with Ansible, it has to exist. The
[`provisioning/`](provisioning/README.md) toolkits handle that step —
creating a Proxmox LXC container or a BinaryLane cloud VM, with split-horizon
DNS and an optional Cloudflare Tunnel for external access:

```bash
cd provisioning/proxmox      # or provisioning/binarylane for a cloud VM
cp config.example.env config.env
./bin/provision-container.sh --hostname host001   # or provision-server.sh --name ...
```

Once a machine is up, add it to the `[setup]` group in your local inventory
and continue with the normal onboarding flow below.

## Onboarding Debian and Ubuntu hosts

After manually installing the control node's public SSH key, add the friendly
host to your ignored local inventory. Restrict SNMP to the monitoring server or
network in that inventory:

```ini
[linux:vars]
onboarding_snmp_allowed_network=192.0.2.50/32
```

Onboard a standard Debian/Ubuntu host:

```bash
./onboard-linux --limit server01 --ask-become-pass
```

The command privately prompts for the SNMP community; enter your private
monitoring value at runtime. It installs `vnstat`, `bwm-ng`, `bashtop`,
`neofetch`, Chrony, SNMP, and unattended upgrades. Required reboots are
scheduled for 03:30, and Chrony uses the Australian NTP pools.

For a new Docker host, first add it to the `docker` inventory group, then run:

```bash
./onboard-docker-host --limit docker01 --ask-become-pass
```

This applies the same Linux baseline, creates `localadmin` when needed,
authorizes the control-node public key, configures validated passwordless sudo,
installs Docker Engine and Compose, adds `localadmin` to Docker access, and
creates `/home/localadmin/docker`.

The standard onboarding playbook excludes Proxmox hosts. Use the dedicated
Proxmox maintenance workflow for hypervisors.

---

## 📖 Usage Examples

### Update Operations
```bash
# Update all Linux machines (with auto-reboot)
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK

# Update specific group
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "docker"

# Just update package lists (no upgrade)
ansible-playbook playbooks/linux_apt-update.yml -i inventory -kK
```

### Updating Proxmox VE nodes

Use the dedicated wrapper instead of the generic Linux upgrade playbook. It
updates one Proxmox node at a time and does not reboot unless requested:

```bash
# Confirm inventory connectivity first
ansible proxmox -m ping -e ansible_become=false -o

# Preview changes without applying them
./update-proxmox --check --diff

# Update every reachable Proxmox node sequentially; do not reboot
./update-proxmox

# Update and reboot each node when /var/run/reboot-required exists
./update-proxmox --reboot

# Limit the operation to one node
./update-proxmox --limit hypervisor01
```

Before clustered-node maintenance, confirm quorum and migrate or shut down
important guests as appropriate. Automatic package removal is disabled by
default to avoid removing Proxmox kernel or metapackage dependencies.

### Bootstrap New Machine
```bash
# 1. Add machine to [setup] group in inventory
# 2. Run bootstrap
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "new_host"
# 3. Move to appropriate group
```

### Setup Services
```bash
# Docker host
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "new_docker_server"

# LAMP server
ansible-playbook playbooks/lamp.yml -i inventory -kK --limit "lampstack"

# NTP configuration
ansible-playbook playbooks/ntp.yml -i inventory -kK
```

### Network Diagnostics
```bash
# Ping all machines
ansible -i inventory all -m ping

# Check uptime everywhere
ansible -i inventory all -m command -a "uptime"

# Run speedtest on specific machine
ansible-playbook playbooks/speedtest.yml -i inventory -l "192.0.2.60" -kK
```

---

## 🎓 Documentation Index

| Document | Purpose |
|----------|---------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | Quick reference for common tasks (START HERE!) |
| [ANSIBLE_CHEATSHEET.md](ANSIBLE_CHEATSHEET.md) | Learning reference and operational cheat sheet |
| [REMOTE_CONTROL_NODE_RUNBOOK.md](REMOTE_CONTROL_NODE_RUNBOOK.md) | Operating the remote WireGuard Ansible control node and deploying its SSH key |
| [ADD_NEW_HOST.md](ADD_NEW_HOST.md) | Complete workflow for adding new machines to homelab |
| [SETUP_ANSIBLE_HOST.md](SETUP_ANSIBLE_HOST.md) | Setting up a new Ansible control node |
| [QUICK_COMMANDS.md](QUICK_COMMANDS.md) | 80+ copy-paste ready commands |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design, structure, and best practices |
| [PLAYBOOKS_REFERENCE.md](PLAYBOOKS_REFERENCE.md) | Detailed documentation for all playbooks |
| [SSH_REFERENCE.md](SSH_REFERENCE.md) | SSH configuration and key management |
| [inventory.example](inventory.example) | Safe template for creating a local inventory |

---

## 🔐 Security Notes

- SSH keys stored at `~/.ssh/ansible` (default) or per-host override
- Keep site-specific users and connection details in the ignored local inventory
- Most machines use `localadmin` user with sudo
- Password prompts supported with `-k` and `-K` flags
- Consider moving sensitive data (k3s passwords) to Ansible vault

---

## 🛠️ Troubleshooting

### "Host unreachable"
- Check SSH connectivity: `ssh -i ~/.ssh/ansible user@host`
- Verify IP address in inventory
- Check firewall allows SSH (port 22)

### "Permission denied"
- For password auth: add `-k` flag
- For sudo password: add `-K` flag
- Check user has appropriate permissions

### "No module named python3"
- Python3 interpreter should be set in inventory: `ansible_python_interpreter=/usr/bin/python3`
- Verify Python 3 is installed: `ansible -i inventory <host> -m command -a "python3 --version"`

**For more troubleshooting**, see [GETTING_STARTED.md](GETTING_STARTED.md#common-issues)

---

## 🔄 Maintenance & Updates

### Regular Tasks
- **Monthly**: Run `linux_apt-upgrade.yml` on all machines
- **Quarterly**: Review inventory and remove/update old entries
- **Annually**: Test disaster recovery and backup restoration

### When Returning After 2-6 Months
1. Read [GETTING_STARTED.md](GETTING_STARTED.md) for quick refresh
2. Run `ansible -i inventory all -m ping` to check status
3. Review the ignored local `inventory` for any changes
4. Run `ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK`

---

## 📝 Future Improvements

- [ ] Better surveillance system organization
- [ ] Implement Ansible vault for sensitive credentials
- [ ] Separate inventory by environment (prod/test)
- [ ] Add monitoring/alerting infrastructure
- [ ] Create backup orchestration playbook
- [ ] Document Proxmox cluster management
- [ ] Add NAS/storage group

---

## 📚 Resources

- [Ansible Documentation](https://docs.ansible.com/)
- [Geerlingguy Roles](https://galaxy.ansible.com/geerlingguy)
- [Proxmox Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [K3s Documentation](https://k3s.io/)

---

## 📄 License

Adapted from TiZuTech's ansible-homelab project.

---

## 🤝 Contributing

This is a personal homelab, but feel free to fork and adapt for your own needs!

**Last Updated**: June 2026

**Documentation Version**: 1.2

**Documentation Files**: 11

**Total Top-Level Playbooks**: 23

**Documented Commands**: 80+
