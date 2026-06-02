# Ansible Homelab Architecture

## Overview

This Ansible project is designed to manage a home laboratory with multiple categories of infrastructure:

- **Proxmox Hypervisors** - 10 nodes running Proxmox VE for VM/LXC hosting
- **Servers** - Ubuntu 24.04 LTS servers with various roles (Docker, LAMP, LibreNMS, Bitwarden, etc.)
- **Workstations/Desktops** - Ubuntu 24.04, PopOS, Debian desktop machines
- **Raspberry Pi/ARM** - Pi and ARM-based SBCs for services like DNS
- **Surveillance System** - Dedicated surveillance infrastructure (Frigate)

## SSH Key Strategy

**Per-Control-Node SSH Keys** ✅

Each Ansible control node has its own SSH key pair. All managed hosts have the public keys from all control nodes in their `authorized_keys`. This approach provides:

- **Multi-control support**: MacBook, desktop, etc. each have their own key
- **Security**: No private key sharing between machines
- **Flexibility**: Easy to add new control nodes
- **Auditability**: Track which control node made changes
- **Consistency**: Same authentication model across all managed hosts

### Key Configuration

**Per Control Node**:
```
MacBook:    ~/.ssh/ansible (private) + ~/.ssh/ansible.pub (public)
Desktop:    ~/.ssh/ansible (private) + ~/.ssh/ansible.pub (public)
Raspberry:  ~/.ssh/ansible (private) + ~/.ssh/ansible.pub (public)
```

**On Managed Hosts**:
- All public keys from all control nodes are in `~/.ssh/authorized_keys`
- Example:
```bash
echo "<MacBook public key>" >> ~/.ssh/authorized_keys
echo "<Desktop public key>" >> ~/.ssh/authorized_keys
echo "<Raspberry public key>" >> ~/.ssh/authorized_keys
```

**Exceptions**: 
- One workstation (172.16.0.60) uses a user-specific key:
```ini
172.16.0.60 ansible_user=nicholaso private_key_file=~/.ssh/nicholaso.corsair3900x
```
- This is for non-standard user on one specific machine

### Ansible Configuration

**In ansible.cfg** on each control node:
```ini
[defaults]
private_key_file = ~/.ssh/ansible
```

Each control node looks for its own `~/.ssh/ansible` key.

### Setting Up SSH Keys

See [SETUP_ANSIBLE_HOST.md](SETUP_ANSIBLE_HOST.md) for comprehensive instructions on:
- Generating SSH keys on each control node
- Pushing public keys from all control nodes to managed hosts
- Managing key permissions
- Troubleshooting SSH connectivity with multiple control nodes

---

1. **Host Groups** - Logical groupings for easy targeting
2. **Host Variables** - Per-host configuration (SSH user, private keys, etc.)
3. **Group Variables** - Defaults for an entire group (Python interpreter, connection type, etc.)

### Group Hierarchy

```
[linux]                          # Parent group for all Linux
├── [ubuntu]                     # Ubuntu-based
│   ├── 172.16.0.23             # IP-based hosts
│   ├── unifi                    # Named hosts
│   └── 172.16.1.249
├── [debian]                     # Debian machines
│   └── 172.16.0.93
├── [raspberrypi]                # ARM/Pi devices
│   ├── pidns26
│   ├── pidns23
│   ├── sapi4a02
│   └── 172.16.0.24
├── [proxmox]                    # Hypervisors (root access)
│   ├── sapve01 (ansible_user=root)
│   ├── sapve02-05
│   ├── sapve07-09
│   ├── sapvethebeast
│   └── pve
├── [docker]                     # Docker-capable hosts
│   ├── 172.16.1.243
│   ├── 172.16.1.225
│   └── (9 hosts total)
├── [lampstack]                  # LAMP servers
│   └── cipi
├── [bitwarden]                  # Bitwarden servers
│   └── 172.16.1.93
├── [surveillance]               # Frigate video surveillance
│   └── 172.16.0.93
├── [master]                     # Ansible control node
│   └── 172.16.0.60
└── [setup]                      # New machines awaiting bootstrap
    └── (5+ hosts)
```

### Design Patterns

#### Multi-role Hosts
- A single host can be in multiple groups (e.g., a Docker server is in both `docker` and `ubuntu`)
- This allows targeting by OS, role, or specific service

#### Test/Staging Group
- Use the `[test]` group to test new playbooks and configurations
- Test group machines are isolated from production
- Perfect for validating changes before rolling out to all machines
- Example: Test a Docker playbook on one machine before running on all docker hosts

#### IP vs DNS Names
- IP addresses: Used for infrastructure not yet with DNS names
- Hostnames: Preferred for persistent infrastructure
- Mix of both is acceptable

#### User/Key Management
- Most hosts use `localadmin` (sudo access)
- Proxmox hosts use `root` directly
- Some hosts may have unique SSH keys specified per-host

#### SSH Configuration
- Default: `~/.ssh/ansible` key
- Per-host override: `ansible_user=name private_key_file=~/.ssh/specific_key`

## Playbooks

Playbooks are organized by function:

### System Administration
- **linux_apt-upgrade.yml** - Update/upgrade all Linux boxes, with reboot handling
- **linux_apt-update.yml** - Just update package lists
- **shutdown.yml** - Graceful shutdown of machines

### Machine Initialization
- **bootstrap.yml** - Initial setup: users, SSH, sudo, build tools
- **setup.yml** - Generic setup tasks
- **nbc-bootstrap.yml** - NBC-specific bootstrap

### Application Setup
- **docker.yml** - Install and configure Docker
- **lamp.yml** - LAMP stack (Apache, MySQL/MariaDB, PHP)
- **jekyll.yml** - Jekyll static site generator
- **ansible-role-bitwarden.yml** - Bitwarden password manager
- **ntp.yml** - NTP time synchronization

### Specialized
- **speedtest.yml** - Run speedtest-cli if available
- **ansible.yml** - Install Ansible on control nodes

### Utilities
- **vars.yml** - Variable definitions (usually included by other playbooks)
- **copy_docker.yml** - Copy Docker-related files

## Roles

Reusable roles in `playbooks/roles/`:

- **bootstrap** - User setup, SSH hardening, build tools, system updates
- **apache** - Apache web server configuration
- **jekyll** - Jekyll blog platform
- **mariadb** - MariaDB database server
- **mysql** - MySQL database server
- **ntp** - Network Time Protocol configuration

Roles use `defaults/main.yml` for variables and `tasks/main.yml` for implementation.

## Common Workflows

## Adding a New Machine

See [ADD_NEW_HOST.md](../ADD_NEW_HOST.md) for the complete step-by-step workflow, which includes:

1. **Prepare**: Initial access and user setup
2. **Inventory**: Add host to appropriate groups
3. **SSH Key**: Copy control node's public key
4. **Bootstrap**: Run base bootstrap playbook
5. **Onboarding**: Run comprehensive setup-onboard.yml
6. **Verify**: Test and move to production group

**Key features of the onboarding process:**
- SSH hardening (key-only, no passwords, no root login)
- Passwordless sudo for ansible user
- Monitoring tools: bwm-ng, vnstat, htop
- **Auto-detection of Proxmox VMs** with qemu-guest-agent installation
- Optional hostname/IP configuration
- SSH key generation on managed host

---

### Batch Updates

All Linux machines at once:
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK
```

Specific group:
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "docker"
```

### Gathering Information

From specific group:
```bash
ansible -i inventory proxmox -m setup
```

All facts as JSON:
```bash
ansible -i inventory all -m setup --tree /tmp/facts
```

CPU info only:
```bash
ansible -i inventory all -m setup -a "filter=ansible_processor*"
```

### Organizing by Machine Category

**For Proxmox Hosts**: Already in `[proxmox]` group
- Edit inventory to add new ones
- Run host-specific plays targeting the proxmox group

**For Servers**: Create sub-groups as needed
```ini
[servers]
docker-01
lamp-server
librenms-server
```

**For Workstations**: Group by OS/purpose
```ini
[workstations]
desktop-01
laptop-01
```

**For Surveillance**: Create dedicated group
```ini
[surveillance]
nvr-01
camera-gateway
```

## Variables and Configuration

### Global Variables (in inventory)
```ini
[linux:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_connection=ssh
ansible_user=localadmin
ansible_become=yes
ansible_become_method=sudo
```

### Group-specific Variables
```ini
[k3s-sapve01:vars]
sapve01_host=https://172.16.0.70:8006
sapve01_user=root@pam
```

### Per-host Variables
```ini
172.16.0.60 ansible_user=nicholaso private_key_file=~/.ssh/nicholaso.corsair3900x
```

## Best Practices

1. **Always test on small groups first**: Use `--limit` before running on `all`
2. **Use meaningful names**: Mix IPs and hostnames - names are easier to remember
3. **Keep inventory organized**: Comments and clear sections
4. **Version control**: Everything is in git, commit regularly
5. **Document changes**: Update inventory comments when adding machines
6. **Dry-run before executing**: Use `--check` to preview changes
7. **Limit scope appropriately**: Use tags and limits to target what you need

## Future Improvements

1. **Surveillance Group**: Better organization of surveillance machines
2. **Environment Separation**: Separate production vs. test groups
3. **Monitoring**: Add monitoring/alerting infrastructure group
4. **Backup Group**: Centralize backup storage hosts
5. **Nested Groups**: Further organize servers by function or location
6. **Host Variables Files**: Move large host-specific configs to separate files

---

**Architecture Version**: 1.0
**Last Updated**: June 2026
**Next Review**: When adding Surveillance system or major infrastructure changes
