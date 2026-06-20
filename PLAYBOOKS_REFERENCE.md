# Playbooks Reference Guide

Complete documentation of all available playbooks in this homelab.

## System Maintenance

### linux_apt-upgrade.yml
**Purpose**: Update and upgrade all Linux machines, with automatic reboot handling
**Usage**:
```bash
# All Linux machines
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK

# Specific group
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "docker"

# With sudo password prompt
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -K --limit "ubuntu"
```
**What it does**:
- Updates apt cache
- Runs full distribution upgrade
- Removes unused packages (autoremove/autoclean)
- Checks for reboot requirement
- Automatically reboots if kernel updated
- Waits for machine to come back online

**When to use**: Regular maintenance, patch management

---

### linux_apt-update.yml
**Purpose**: Just update apt cache (no upgrades)
**Usage**:
```bash
ansible-playbook playbooks/linux_apt-update.yml -i inventory -kK
```
**What it does**: Refreshes apt package cache only (dry-run for upgrades)

---

### shutdown.yml
**Purpose**: Gracefully shutdown specified hosts
**Usage**:
```bash
ansible-playbook playbooks/shutdown.yml -i inventory -k --limit "hosts_to_shutdown"
```
**Warning**: This shuts down machines! Be careful with the limit parameter.

**When to use**: Power management, maintenance windows

---

## Machine Bootstrap & Setup

### setup-onboard.yml
**Purpose**: Comprehensive onboarding of new machines with SSH hardening, networking, timezone, NTP, and monitoring
**Hosts**: `setup` group (or any new machine)
**Usage**:
```bash
# Basic onboarding (SSH key already configured)
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "new_host"

# With hostname and IP configuration
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "new_host" \
  -e "host_hostname=docker-01 host_ipaddr=198.51.100.100 host_netmask=24 host_gateway=192.0.2.1"

# On test machine before production
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "test"
```

**What it does**:
- Updates system and all packages
- **Sets timezone to Australia/Brisbane**
- **Configures Chrony NTP with Australian pool** (au.pool.ntp.org servers)
- Installs monitoring tools: bwm-ng, vnstat, htop
- Hardens SSH (key-based auth only, disables password auth, disables root login)
- Enables **passwordless sudo** for ansible user (use `sudo -n command`)
- **Auto-detects Proxmox VMs** and installs/enables qemu-guest-agent
- Configures hostname (if specified)
- Configures static IP and DNS (optional, if variables provided)
- Generates SSH key pair on host (ed25519)
- Provides detailed summary with Proxmox, timezone, and NTP status

**Key Features**:
- **Timezone & NTP**: Australia/Brisbane timezone with Chrony syncing to au.pool.ntp.org
- **Passwordless Sudo**: Ansible user can run `sudo` without password prompts
- **Proxmox Detection**: Automatically checks if running on Proxmox and installs qemu-guest-agent
- **Monitoring Stack**: bwm-ng for bandwidth, vnstat for network stats, htop for processes
- **SSH Hardening**: No passwords, no root login, public key only

**Variables** (optional - pass with `-e`):
```yaml
host_hostname: docker-01              # Set system hostname
host_ipaddr: 198.51.100.100            # Static IP address
host_netmask: 24                       # Network mask (CIDR or dotted)
host_gateway: 192.0.2.1              # Default gateway
host_dns_servers:                      # DNS servers
  - 8.8.8.8
  - 1.1.1.1
host_interface: eth0                  # Network interface (auto-detected if not set)
generate_ssh_key: true                 # Generate SSH key on host
sshd_port: 22                          # SSH port
ntp_timezone: Australia/Brisbane       # Timezone
ntp_servers:                           # NTP servers list
  - 0.au.pool.ntp.org
  - 1.au.pool.ntp.org
  - 2.au.pool.ntp.org
  - 3.au.pool.ntp.org
```

**When to use**: Initial setup of new machines you're adding to the homelab

**See also**: [ADD_NEW_HOST.md](../ADD_NEW_HOST.md) for complete workflow

---

### bootstrap.yml
**Purpose**: Initial setup of new machines (users, SSH, sudo, build tools, timezone, NTP)
**Hosts**: `setup` group
**Usage**:
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK
```
**What it does**:
- Prompts for password to set on new user
- Runs bootstrap role (users, SSH hardening, packages)
- **Sets timezone to Australia/Brisbane**
- **Installs and configures Chrony NTP daemon** with Australian pool (au.pool.ntp.org)
- Installs build tools

**NTP Configuration**:
- Uses Chrony daemon (more robust than ntpd)
- Configured with Australian NTP pool:
  - 0.au.pool.ntp.org
  - 1.au.pool.ntp.org
  - 2.au.pool.ntp.org
  - 3.au.pool.ntp.org

**When to use**: First time setting up a new machine from scratch

**Prerequisites**:
- Machine must be reachable via SSH
- Must be in the `setup` group in inventory
- Need default credentials to access initially

---

### nbc-bootstrap.yml
**Purpose**: NBC-specific bootstrap (customized for specific infrastructure)
**Usage**:
```bash
ansible-playbook playbooks/nbc-bootstrap.yml -i inventory -kK --limit "nbc_hosts"
```
**Note**: Check what this does for your specific setup

---

### setup.yml
**Purpose**: Generic setup tasks (alternative to bootstrap)
**Usage**:
```bash
ansible-playbook playbooks/setup.yml -i inventory -kK
```

---

## Application & Service Setup

### docker.yml
**Purpose**: Install Docker and configure Docker hosts
**Hosts**: `docker` group
**Usage**:
```bash
# Setup Docker on all docker group hosts
ansible-playbook playbooks/docker.yml -i inventory -kK

# Single host by IP
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "198.51.100.243"
```
**What it does**:
- Installs Docker and docker-compose
- Configures Docker daemon
- Sets up user permissions
- Potentially pulls/starts containers

**When to use**: Setting up new Docker hosts

---

### copy_docker.yml
**Purpose**: Copy Docker-related files/configs to hosts
**Usage**:
```bash
ansible-playbook playbooks/copy_docker.yml -i inventory -k --limit "docker"
```
**What it does**: Synchronizes Docker configs/files to target machines

---

### docker.yml (appears to use geerlingguy role)
**Purpose**: Docker installation/configuration using Galaxy role
**Usage**: Same as docker.yml above

---

### lamp.yml
**Purpose**: Install LAMP stack (Linux, Apache, MySQL/MariaDB, PHP)
**Hosts**: `lampstack` group (e.g., `web01`)
**Usage**:
```bash
ansible-playbook playbooks/lamp.yml -i inventory -kK --limit "lampstack"
```
**What it does**:
- Installs Apache web server
- Installs MariaDB/MySQL database
- Installs PHP and extensions
- Configures services

**When to use**: Setting up web servers with database backends

---

### jekyll.yml
**Purpose**: Install and configure Jekyll for static site generation
**Usage**:
```bash
ansible-playbook playbooks/jekyll.yml -i inventory -kK --limit "jekyll_hosts"
```
**What it does**:
- Installs Ruby, bundler
- Installs Jekyll
- Configures for site building

**When to use**: Setting up Jekyll blog or static site servers

---

### ansible-role-bitwarden.yml
**Purpose**: Install Bitwarden password manager
**Hosts**: `bitwarden` group (198.51.100.93)
**Usage**:
```bash
ansible-playbook playbooks/ansible-role-bitwarden.yml -i inventory -kK
```
**What it does**: Sets up Bitwarden server (self-hosted password manager)

**When to use**: Initial Bitwarden setup or reconfiguration

---

### ntp.yml
**Purpose**: Configure NTP (Network Time Protocol) and timezone using Chrony daemon
**Usage**:
```bash
# Configure all hosts
ansible-playbook playbooks/ntp.yml -i inventory -kK

# Configure specific group
ansible-playbook playbooks/ntp.yml -i inventory -kK --limit "ubuntu"

# Configure single host
ansible-playbook playbooks/ntp.yml -i inventory -kK --limit "198.51.100.100"
```

**What it does**:
- Sets timezone to Australia/Brisbane
- Installs Chrony NTP daemon
- Configures Chrony with Australian NTP pool (au.pool.ntp.org)
- Enables and starts Chrony service
- Verifies time synchronization status

**NTP Servers**:
- 0.au.pool.ntp.org
- 1.au.pool.ntp.org
- 2.au.pool.ntp.org
- 3.au.pool.ntp.org

**Chrony Benefits**:
- Better handling of unstable networks
- Faster synchronization
- Works with both server and embedded systems
- More robust than traditional ntpd

**Verification**:
```bash
# Check timezone
ansible -i inventory all -m command -a "timedatectl show --property=Timezone --value"

# Check NTP status
ansible -i inventory all -m command -a "chronyc tracking"
```

**When to use**: Setting up time synchronization for all machines in the homelab

---

## Kubernetes & Container Orchestration

*Note: Kubernetes/K3s not currently in use for this homelab.*

## Utilities & Monitoring

### speedtest.yml
**Purpose**: Run speedtest-cli on target machines
**Usage**:
```bash
ansible-playbook playbooks/speedtest.yml -i inventory --limit "192.0.2.60" -kK
```
**What it does**: Executes speedtest if installed (requires speedtest-cli package)

**When to use**: Testing network performance from various locations

---

### ansible.yml
**Purpose**: Install Ansible on control nodes
**Hosts**: `master` group (192.0.2.60)
**Usage**:
```bash
ansible-playbook playbooks/ansible.yml -i inventory -kK
```
**What it does**: Installs Ansible using geerlingguy.ansible Galaxy role

**When to use**: Setting up backup Ansible control nodes

---

## Utility Files

### vars.yml
**Purpose**: Variable definitions file (usually sourced by other playbooks)
**Not typically run directly** - included by other playbooks via `vars_files`

---

## Extended Examples from README

### From the repository examples:

```bash
# Docker specific host
ansible-playbook playbooks/docker.yml -l docker01 -kK -i inventory

# Bootstrap setup hosts
ansible-playbook playbooks/bootstrap.yml -l 198.51.100.223 -kK -i inventory

# Run speedtest on specific machine
speedtest.yml -i ../inventory -k -l 192.0.2.60
```

---

## Common Usage Patterns

### Test before running (dry-run)
```bash
ansible-playbook <playbook> --check -i inventory
```

### Run with specific tag
```bash
ansible-playbook <playbook> -i inventory -t tag_name
```

### Increase verbosity for debugging
```bash
ansible-playbook <playbook> -i inventory -vv  # -vvv for more verbosity
```

### Run without prompts (use defaults)
```bash
ansible-playbook <playbook> -i inventory --extra-vars "some_var=value"
```

### Syntax check (no execution)
```bash
ansible-playbook <playbook> --syntax-check
```

---

## Quick Cheat Sheet

| Task | Command |
|------|---------|
| Update all Linux | `ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK` |
| Check connectivity | `ansible -i inventory all -m ping` |
| Bootstrap new machine | Add to `setup` group, then run `bootstrap.yml` |
| Setup Docker | Add to `docker` group, then run `docker.yml` |
| Run NTP config | `ansible-playbook playbooks/ntp.yml -i inventory -kK` |
| Gather facts | `ansible -i inventory all -m setup` |
| Run command on group | `ansible -i inventory <group> -m command -a "your_command"` |

---

**Reference Version**: 1.0
**Last Updated**: June 2026
**Playbook Count**: 16 main playbooks
