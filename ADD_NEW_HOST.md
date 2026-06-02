# Adding a New Host to Ansible Homelab

Complete step-by-step guide for bringing new infrastructure into your homelab management.

---

## Quick Overview

The process has 5 main stages:

1. **Prepare**: Initial access & SSH key setup
2. **Inventory**: Add host to inventory file with proper categorization
3. **Bootstrap**: Run base bootstrap playbook
4. **Onboard**: Run comprehensive onboarding (hardening, monitoring, Proxmox setup)
5. **Verify**: Test and move to production group

---

## Stage 1: Prepare the New Host

### Step 1.1: Verify Initial Access

Ensure you can SSH to the new machine:

```bash
# For fresh VMs (may have default user/password)
ssh root@192.168.x.x
# or
ssh ubuntu@192.168.x.x

# For physical machines, verify SSH is running
ssh admin@hostname.local
```

**If SSH doesn't work:**
- Check machine is on network and reachable: `ping 192.168.x.x`
- Check SSH service is running on the host
- Verify firewall allows port 22

### Step 1.2: Create Initial User (if needed)

If the machine only has `root` access:

```bash
# SSH as root
ssh root@192.168.x.x

# Create ansible user
sudo adduser localadmin

# Add to sudoers
sudo usermod -aG sudo localadmin

# Or manually add to sudoers file (DANGEROUS - use visudo):
sudo visudo
# Add line: localadmin ALL=(ALL) NOPASSWD:ALL
```

---

## Stage 2: Add to Inventory

### Step 2.1: Determine Host Category

Identify what category your new host belongs to:

| Category | Purpose | Group Name | User | Notes |
|----------|---------|-----------|------|-------|
| Proxmox | Hypervisor | `[proxmox]` | root | Direct root access for management |
| Docker Server | Container host | `[docker]` | localadmin | Also add to `[ubuntu]` or `[debian]` |
| LAMP Server | Web + DB | `[lampstack]` | localadmin | Add to `[ubuntu]` |
| Surveillance | Video system | `[surveillance]` | localadmin | Add to `[ubuntu]` |
| Workstation | Desktop/laptop | `[workstations]` | localadmin | Per-user SSH key may be needed |
| Service | DNS/NTP/etc | `[service_servers]` | localadmin | Add to `[ubuntu]` or `[debian]` |
| Testing | Test/staging | `[test]` | localadmin | Temporary, for testing |
| Raspberry Pi | ARM/SBC | `[raspberrypi]` | pi or localadmin | Depends on OS |

### Step 2.2: Edit Inventory File

Edit `inventory` or `inventory.organized`:

```bash
nano inventory
# or
vim inventory
```

Add the host to the appropriate `[group]` section:

```ini
# Example: Adding a Docker server
[docker]
172.16.1.100          # New Docker host

# Example: Adding a Proxmox host
[proxmox]
proxmox-node-01 ansible_user=root

# Example: Adding to multiple groups
[ubuntu]
docker-01

[docker]
docker-01

[service_servers]
docker-01
```

**Best Practices:**
- Use hostnames where possible (easier to remember): `docker-01` instead of `172.16.1.100`
- If using IPs, pick a group that clearly indicates its role
- A host can be in multiple groups (Ubuntu + Docker, etc.)

### Step 2.3: Add to [setup] Group (Temporary)

While onboarding, add the host to the `[setup]` group:

```ini
[setup]
192.168.x.x
# or
docker-01

# Or with specific user if not default:
docker-01 ansible_user=ubuntu

# Or if using specific SSH key:
docker-01 ansible_user=ubuntu private_key_file=~/.ssh/ubuntu_key
```

---

## Stage 3: Add SSH Public Key to Host

You have two options for SSH authentication during onboarding:

### Option A: Copy SSH Key (Recommended for multiple hosts)

```bash
# Copy Ansible control node's public key to new host
# (Requires password - you'll be prompted)
ssh-copy-id -i ~/.ssh/ansible.pub -p 22 localadmin@192.168.x.x

# Or for root access
ssh-copy-id -i ~/.ssh/ansible.pub -p 22 root@192.168.x.x

# For specific hosts that need it
ssh-copy-id -i ~/.ssh/ansible.pub -p 22 ubuntu@192.168.x.x
```

**Output should show:**
```
Number of key(s) added: 1
```

### Option B: Manual SSH Key Copy

If `ssh-copy-id` doesn't work:

```bash
# On the NEW host, add key manually
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add the public key content (from ~/.ssh/ansible.pub on control node)
echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Step 3.1: Verify SSH Key Works

```bash
# Should NOT ask for password if key is set up correctly
ssh -i ~/.ssh/ansible localadmin@192.168.x.x "echo 'SSH key working!'"

# or
ansible -i inventory 192.168.x.x -m ping
```

---

## Stage 4: Run Bootstrap Playbook

Once SSH key is in place and host is in inventory, run bootstrap:

### Step 4.1: Test Connectivity First

```bash
ansible -i inventory 192.168.x.x -m ping
```

Should output: `192.168.x.x | SUCCESS => ...`

### Step 4.2: Run Bootstrap

```bash
# For single host
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "192.168.x.x"

# Or by hostname if you used one
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "docker-01"

# For multiple new hosts in setup group
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "setup"
```

**What bootstrap does:**
- Creates/configures user account
- Sets up SSH hardening basics
- Installs build tools and utilities
- Updates system

---

## Stage 5: Run Onboarding Playbook

The onboarding playbook handles hardening, monitoring, and Proxmox setup:

### Step 5.1: Basic Onboarding

```bash
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "docker-01"
```

**What it does:**
- Updates and upgrades system packages
- Installs monitoring: bwm-ng, vnstat, htop
- Hardens SSH (key-only, no passwords, no root login)
- Enables passwordless sudo for ansible user
- **Auto-detects Proxmox VMs and installs qemu-guest-agent**
- Generates SSH keys on the host
- Provides detailed summary

### Step 5.2: Onboarding with Network Configuration

If you need to set hostname and IP:

```bash
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "docker-01" \
  -e "host_hostname=docker-prod-01 host_ipaddr=172.16.1.100 host_netmask=24 host_gateway=172.16.0.1"
```

### Step 5.3: Test Before Production (Recommended)

Test the playbook on your [test] group first:

```bash
# Add test machine to [test] group in inventory, then:
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "test" --check

# Review output, then run for real
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "test"
```

---

## Stage 6: Verify & Finalize

### Step 6.1: Verify Machine Status

```bash
# Check it responds to ping
ansible -i inventory docker-01 -m ping

# Verify monitoring tools installed
ansible -i inventory docker-01 -m shell -a "which htop bwm-ng vnstat"

# Check passwordless sudo works
ansible -i inventory docker-01 -m shell -a "sudo -n whoami"
# Should output: root

# Check SSH hardening applied
ansible -i inventory docker-01 -m shell -a "sshd -T | grep -E 'passwordauthentication|permitemptypasswords|permitrootlogin'"
# Should show: no, no, no
```

### Step 6.2: For Proxmox VMs - Verify QEMU Agent

```bash
# Check if qemu-guest-agent is running
ansible -i inventory docker-01 -m systemd -a "name=qemu-guest-agent state=started enabled=yes"

# Verify it's installed
ansible -i inventory docker-01 -m shell -a "systemctl status qemu-guest-agent"
```

### Step 6.3: Move to Production Group

Now move the host from `[setup]` to its permanent group:

Edit inventory and:

```ini
# REMOVE from setup
[setup]
# docker-01 REMOVED FROM HERE

# ADD to production group
[docker]
docker-01

# Also add to OS group if not already
[ubuntu]
docker-01
```

---

## Complete Workflow Example

Adding **docker-prod-01** (Docker server) to the homelab:

### Step 1: Prepare
```bash
ssh ubuntu@192.168.1.100
sudo adduser localadmin
sudo usermod -aG sudo localadmin
# Create password, then logout
```

### Step 2: Add to Inventory
```bash
# Edit inventory file:
[setup]
docker-prod-01 ansible_user=ubuntu
```

### Step 3: Copy SSH Key
```bash
ssh-copy-id -i ~/.ssh/ansible.pub ubuntu@docker-prod-01
# Enter ubuntu password when prompted
```

### Step 4: Run Bootstrap
```bash
ansible-playbook playbooks/bootstrap.yml -i inventory -kK --limit "docker-prod-01"
```

### Step 5: Run Onboarding
```bash
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "docker-prod-01" \
  -e "host_hostname=docker-prod-01"
```

### Step 6: Verify
```bash
# Check all services
ansible -i inventory docker-prod-01 -m ping
ansible -i inventory docker-prod-01 -m shell -a "sudo -n whoami"
ansible -i inventory docker-prod-01 -m shell -a "systemctl status qemu-guest-agent"
```

### Step 7: Update Inventory for Production
```bash
# Move from setup to production groups
[ubuntu]
docker-prod-01

[docker]
docker-prod-01

[service_servers]
docker-prod-01
```

### Step 8: Test Docker Installation (Optional)
```bash
# Now install Docker if needed
ansible-playbook playbooks/docker.yml -i inventory -kK --limit "docker-prod-01"
```

---

## Proxmox-Specific Notes

### Detecting Proxmox VMs Automatically

The `setup-onboard.yml` playbook automatically:
1. Detects if running on Proxmox (checks for `/sys/class/dmi/id/system_manufacturer` contains "Proxmox")
2. Installs `qemu-guest-agent` if on Proxmox
3. Enables and starts the service

You don't need to do anything special - the playbook handles it!

### Manual Proxmox Host Setup

If adding a Proxmox **hypervisor** (not VM):

```ini
[proxmox]
proxmox-node-01 ansible_user=root
```

Proxmox hosts require `root` user and don't need qemu-guest-agent (they run VMs, not run as VMs).

---

## Troubleshooting

### "Host unreachable"
```bash
# Check network connectivity
ping 192.168.x.x

# Check SSH is running
ssh -v -i ~/.ssh/ansible localadmin@192.168.x.x

# Check firewall
nmap -p 22 192.168.x.x
```

### "Permission denied (publickey)"
```bash
# Copy SSH key again
ssh-copy-id -i ~/.ssh/ansible.pub localadmin@192.168.x.x

# Or verify it's there
ssh localadmin@192.168.x.x "cat ~/.ssh/authorized_keys"
```

### "sudo: unable to resolve host"
```bash
# Fix hostname/DNS on the host
ssh localadmin@host "sudo nano /etc/hosts"
# Ensure hostname resolves to 127.0.1.1
```

### Playbook fails on certain steps
```bash
# Run with verbose output
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "docker-01" -vv

# Run specific module
ansible -i inventory docker-01 -m shell -a "apt update" -K
```

---

## Workflow Checklist

```
[ ] Verify SSH access to new host
[ ] Create localadmin user if needed
[ ] Add host to [setup] group in inventory
[ ] Copy SSH public key (ssh-copy-id)
[ ] Verify key works (ansible ping)
[ ] Run bootstrap playbook
[ ] Run onboarding playbook
[ ] Verify all services:
    [ ] htop, bwm-ng, vnstat installed
    [ ] SSH hardening applied
    [ ] Passwordless sudo working
    [ ] qemu-guest-agent running (if Proxmox VM)
[ ] Move host from [setup] to production groups
[ ] Test with role-specific playbooks
[ ] Monitor in production
```

---

**New Host Onboarding Guide Version**: 1.0  
**Last Updated**: June 2026  
**Estimated Time**: 10-15 minutes per host
