# Quick Commands - Copy & Paste Reference

One-liner commands for common tasks. Copy and paste directly into your terminal!

## Status Checks

### Check all machines are reachable
```bash
ansible -i inventory all -m ping
```

### Check specific group
```bash
ansible -i inventory proxmox -m ping
```

### Get uptime of all machines
```bash
ansible -i inventory all -m command -a "uptime"
```

### Check free disk space
```bash
ansible -i inventory all -m shell -a "df -h / | tail -1"
```

### Check free memory
```bash
ansible -i inventory all -m shell -a "free -h | head -2"
```

## System Information Gathering

### Get all facts/info on all machines
```bash
ansible -i inventory all -m setup > homelab_facts.json
```

### Get facts on specific group
```bash
ansible -i inventory docker -m setup | less
```

### Get only CPU info
```bash
ansible -i inventory all -m setup -a "filter=ansible_processor*"
```

### Get OS info only
```bash
ansible -i inventory all -m setup -a "filter=ansible_os_family"
```

### Get IP addresses
```bash
ansible -i inventory all -m setup -a "filter=ansible_default_ipv4"
```

## System Updates

### Update ALL Linux machines
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK
```

### Update specific group (e.g., docker servers)
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "docker"
```

### Update just one machine by IP
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "172.16.0.23"
```

### Just update package cache (no upgrade)
```bash
ansible-playbook playbooks/linux_apt-update.yml -i inventory -kK
```

### Update specific machines (comma-separated)
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "172.16.0.23,172.16.0.27"
```

## Common Administration Tasks

### Reboot all machines
```bash
ansible -i inventory all -m reboot
```

### Reboot specific group
```bash
ansible -i inventory proxmox -m reboot
```

### Shutdown all machines (use with caution!)
```bash
ansible-playbook playbooks/shutdown.yml -i inventory -k
```

### Run a command on all machines
```bash
ansible -i inventory all -m command -a "systemctl status docker"
```

### Run a shell command on specific group
```bash
ansible -i inventory docker -m shell -a "docker ps -a"
```

### Check if a service is running
```bash
ansible -i inventory all -m service -a "name=ssh state=started enabled=yes"
```

### Install a package on all machines
```bash
ansible -i inventory all -m apt -a "name=htop state=present" -k
```

### Install package on specific group
```bash
ansible -i inventory ubuntu -m apt -a "name=curl state=present" -k
```

## Network Diagnostics

### Ping all machines from homelab
```bash
ansible -i inventory all -m ping
```

### Check connectivity to specific host
```bash
ansible -i inventory 172.16.0.23 -m ping
```

### Run speedtest on specific machine (if installed)
```bash
ansible-playbook playbooks/speedtest.yml -i inventory --limit "172.16.0.60" -kK
```

### Check DNS resolution
```bash
ansible -i inventory all -m shell -a "nslookup google.com"
```

### Get network interfaces
```bash
ansible -i inventory all -m setup -a "filter=ansible_interfaces"
```

## Docker Operations

### List Docker containers on all docker hosts
```bash
ansible -i inventory docker -m shell -a "docker ps -a"
```

### Check docker version
```bash
ansible -i inventory docker -m shell -a "docker --version"
```

### Stop container on specific host
```bash
ansible -i inventory 172.16.1.243 -m shell -a "docker stop container_name"
```

### Setup new Docker host
```bash
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "new_docker_host_name"
```

## SSH & Security

### Copy SSH key to all machines
```bash
ansible -i inventory all -m authorized_key -a "user=localadmin key='{{ lookup(\"file\", \"~/.ssh/id_rsa.pub\") }}' state=present"
```

### Check SSH connectivity
```bash
ansible -i inventory all -m ping
```

### Update SSH config on all machines
```bash
ansible -i inventory all -m copy -a "src=files/sshd.conf dest=/etc/ssh/sshd_config.d/custom.conf"
```

## Proxmox Operations

### Check all Proxmox hosts
```bash
ansible -i inventory proxmox -m ping
```

### Get hostname of all Proxmox hosts
```bash
ansible -i inventory proxmox -m shell -a "hostname"
```

### Check Proxmox versions
```bash
ansible -i inventory proxmox -m shell -a "pveversion"
```

### List VMs on all Proxmox hosts
```bash
ansible -i inventory proxmox -m shell -a "qm list"
```

### Check Proxmox node status
```bash
ansible -i inventory proxmox -m shell -a "pvecm status"
```

## Playbook Execution

### Run with dry-run (check mode)
```bash
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --check
```

### Test playbook on test group first
```bash
# Before running on production, test on test group
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "test" --check
# If check passes, run on test machine
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "test"
# Then run on production group
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "docker"
```

### Run with verbose output
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK -vv
```

### Run with extra verbose (very detailed)
```bash
ansible-playbook playbooks/docker.yml -i inventory -kK -vvv
```

### Check playbook syntax only
```bash
ansible-playbook playbooks/bootstrap.yml --syntax-check
```

### Run playbook with specific tags
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK -t "users,ssh"
```

### Run playbook skipping specific tags
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --skip-tags "reboot"
```

## Bootstrap New Machines

### Add machine to setup group, then bootstrap
```bash
# First edit inventory file to add machine to [setup] group
# Then run:
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "new_machine_ip"
```

### Bootstrap all setup group machines
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "setup"
```

### Onboard new machine (complete setup with SSH hardening & monitoring)
```bash
# Minimal onboarding
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "new_host"
```

### Onboard with hostname and IP configuration
```bash
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "new_host" \
  -e "host_hostname=docker-01 host_ipaddr=172.16.1.100 host_netmask=24 host_gateway=172.16.0.1"
```

### Onboard on test machine first (safe testing)
```bash
# Add test machine to [test] group in inventory, then:
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "test"
```

### Bootstrap and install Docker
```bash
# First bootstrap
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "new_host"
# Then install Docker
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "new_host"
```

## Inventory Management

### List all hosts in inventory
```bash
ansible -i inventory all --list-hosts
```

### List hosts in specific group
```bash
ansible -i inventory proxmox --list-hosts
```

### List all groups
```bash
ansible -i inventory all --list
```

### Show inventory as tree
```bash
ansible -i inventory all -i inventory --graph
```

## Performance & Facts Gathering

### Gather facts and save to file (for reference)
```bash
ansible -i inventory all -m setup --tree /tmp/homelab_facts
```

### Show facts for specific group
```bash
ansible -i inventory docker -m setup | grep -A 5 "ansible_hostname"
```

### Check Ansible gathering settings
```bash
ansible -i inventory all -m setup -a "filter=*gathering*"
```

## Maintenance & Cleanup

### Remove old packages
```bash
ansible -i inventory all -m shell -a "apt autoremove -y && apt autoclean -y" -K
```

### Check package updates available
```bash
ansible -i inventory all -m shell -a "apt list --upgradable"
```

### Check system logs
```bash
ansible -i inventory all -m shell -a "journalctl -xe | tail -20"
```

## Troubleshooting

### Test SSH connection to specific host
```bash
ansible -i inventory 172.16.0.23 -m ping -vvv
```

### Check Python availability
```bash
ansible -i inventory all -m shell -a "python3 --version"
```

### See what variables are available
```bash
ansible -i inventory 172.16.0.23 -m debug -a "var=hostvars[inventory_hostname]"
```

### Check if host is in inventory
```bash
ansible -i inventory hostname_or_ip --list-hosts
```

### Run command with sudo
```bash
ansible -i inventory all -m shell -a "whoami" -K
```

---

## Frequently Used Combination

### "Prepare for extended maintenance" workflow
```bash
# 1. Check all machines
ansible -i inventory all -m ping

# 2. Gather current facts
ansible -i inventory all -m setup --tree /tmp/facts_before

# 3. Update everything
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK

# 4. Verify after update
ansible -i inventory all -m shell -a "uptime"

# 5. Check for issues
ansible -i inventory all -m command -a "systemctl status"
```

---

**Quick Commands Reference Version**: 1.0
**Last Updated**: June 2026
**Total Commands**: 80+

**Tip**: Bookmark this file! Save it locally for quick access when working offline.
