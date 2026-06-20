# Getting Started with Ansible Homelab

## Quick Reference - Return after 2-6 months?

Welcome back! This guide helps you quickly get up to speed.

### Prerequisites
- Ensure you have the SSH key configured: `~/.ssh/ansible`
- This single key manages all systems in your homelab
- Create your private inventory once: `cp inventory.example inventory`
- Keep the resulting `inventory` local; it is intentionally ignored by Git
- Run `ansible-galaxy install -r requirements.yml` to install required roles
- For detailed control node setup, see [SETUP_ANSIBLE_HOST.md](SETUP_ANSIBLE_HOST.md)

### Most Common Tasks

#### 1. Update all Linux machines
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "linux"
```
This updates and upgrades all Linux hosts in your inventory, with automatic reboot if kernel was updated.

#### 2. Gather facts/info from all machines
```bash
ansible -i inventory all -m gather_facts > homelab_facts.json
```

#### 3. Run commands on specific groups
```bash
# On all Docker servers
ansible -i inventory docker -m command -a "docker ps"

# On all Proxmox hosts
ansible -i inventory proxmox -m command -a "hostname"

# On all Ubuntu machines
ansible -i inventory ubuntu -m command -a "lsb_release -a"
```

#### 4. Bootstrap new machines
First add the machine to the `setup` group in the inventory file, then:
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "setup"
```

#### 5. Get status of all machines
```bash
ansible -i inventory all -m ping
```

#### 6. Apply the common SSH key and timezone baseline
```bash
ansible-playbook playbooks/site-baseline.yml --limit "hostname" --ask-pass --ask-become-pass
```

#### 7. Configure a desktop workstation
```bash
ansible-playbook playbooks/desktop-workstation.yml --limit "desktop01" --ask-pass --ask-become-pass
```

### Directory Structure

```
ansible-homelab/
├── inventory              # Machine definitions (EDIT THIS to add/remove hosts)
├── inventory.example      # Public template for creating the local inventory
├── ansible.cfg           # Ansible configuration
├── deploy-ansible-key    # Install this control node's public key
├── enable-passwordless-sudo # Configure sudo automation
├── run-speedtest         # Concurrent/sequential speed testing
├── playbooks/            # All playbooks for various tasks
│   ├── linux_apt-upgrade.yml     # Update/upgrade all Linux
│   ├── bootstrap.yml             # Bootstrap new machines
│   ├── docker.yml                # Docker setup
│   ├── lamp.yml                  # LAMP stack setup
│   ├── jekyll.yml                # Jekyll setup
│   ├── create-k3s-cluster.yml    # Generic Proxmox K3s VM creation
│   ├── site-baseline.yml          # Shared SSH key and timezone baseline
│   ├── desktop-workstation.yml    # Desktop packages and Flatpaks
│   └── roles/            # Reusable roles
├── GETTING_STARTED.md    # This file!
├── ARCHITECTURE.md       # How it's organized
├── PLAYBOOKS_REFERENCE.md # Details on all playbooks
├── QUICK_COMMANDS.md     # Common one-liners
└── REMOTE_CONTROL_NODE_RUNBOOK.md # Remote-node operations
```

### Key Concepts

**Inventory Groups** - All your machines are organized into groups in the `inventory` file:
- `proxmox` - All Proxmox hypervisors
- `servers` - Server-class machines (Docker, LAMP, LibreNMS, etc.)
- `workstations` - Desktop/workstation machines
- `ubuntu` / `debian` - By OS
- `docker` - Machines running Docker
- `raspberrypi` / ARM machines
- `linux` - Parent group containing all Linux machines

**Playbooks** - YAML files that define what to do:
- Use them with: `ansible-playbook <playbook> -i inventory [options]`
- Add `-l <group>` to limit to specific machines
- Add `-k` to prompt for SSH password
- Add `-K` to prompt for sudo password

### Typical Workflow When You Return

1. **Check machine status**: `ansible -i inventory all -m ping`
2. **See what needs updating**: Review the inventory file to see what's there
3. **Run updates if needed**: `ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK`
4. **Add new machines**: See [ADD_NEW_HOST.md](ADD_NEW_HOST.md) for complete step-by-step workflow
5. **Gather information**: Run specific playbooks or ad-hoc commands

## Testing Workflow Before Production Changes

When you want to test a playbook before running it on production:

1. **Add test machine to `[test]` group** in inventory
2. **Run with `--check` first** (dry-run):
   ```bash
   ansible-playbook playbooks/docker.yml -i inventory -kK --limit "test" --check
   ```
3. **Run on test machine**:
   ```bash
   ansible-playbook playbooks/docker.yml -i inventory -kK --limit "test"
   ```
4. **Verify test results**, then run on production group:
   ```bash
   ansible-playbook playbooks/docker.yml -i inventory -kK --limit "docker"
   ```

### Help & More Info

- See [ADD_NEW_HOST.md](ADD_NEW_HOST.md) for complete step-by-step guide to adding new machines
- See [SETUP_ANSIBLE_HOST.md](SETUP_ANSIBLE_HOST.md) for setting up a new control node
- See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design explanation
- See [PLAYBOOKS_REFERENCE.md](PLAYBOOKS_REFERENCE.md) for all playbooks
- See [QUICK_COMMANDS.md](QUICK_COMMANDS.md) for one-liner examples

### Common Issues

**"Host unreachable"**
- Check SSH key is correct: `ssh -i ~/.ssh/ansible user@host`
- Check firewall allows SSH (port 22)
- Verify host is online and IP is correct

**"Permission denied"**
- If using password auth: add `-k` flag
- If sudo password needed: add `-K` flag

**"No module named python3"**
- The `ansible_python_interpreter=/usr/bin/python3` setting in inventory handles this
- If you get errors, check Python is installed: `ansible -i inventory <host> -m command -a "python3 --version"`

---

**Last updated**: June 2026
**Next review**: Check if all hosts still exist and update as needed
