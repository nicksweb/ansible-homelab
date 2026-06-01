# Setting Up an Ansible Control Host

Guide for setting up a new machine to manage your homelab infrastructure.

## Quick Setup Summary

This guide covers:
1. Installing Ansible and requirements
2. Setting up SSH key-based authentication
3. Pushing public keys to managed hosts
4. Verifying your control host setup

---

## Step 1: Install Ansible & Dependencies

### On Ubuntu/Debian
```bash
# Update package lists
sudo apt update

# Install Python3, pip, and Ansible
sudo apt install -y python3 python3-pip python3-venv git

# Install Ansible via pip (recommended for latest version)
pip3 install --user ansible

# Verify installation
ansible --version
```

### On macOS
```bash
# Using Homebrew
brew install ansible

# Or using pip
pip3 install ansible

# Verify installation
ansible --version
```

---

## Step 2: SSH Key Setup

### SSH Key Strategy: One Key for All Systems

For simplicity and security, we use a **single SSH key** (`~/.ssh/ansible`) to manage all systems. This is stored in `ansible.cfg`:

```ini
[defaults]
private_key_file = ~/.ssh/ansible
```

**Exception**: One workstation (172.16.0.60) uses a user-specific key - see "Per-Host Keys" below.

### Generate SSH Key (if needed)

```bash
# Generate new SSH key for Ansible
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@homelab" -N ""

# Or RSA if Ed25519 not available
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ansible -C "ansible@homelab" -N ""

# Set secure permissions
chmod 600 ~/.ssh/ansible
chmod 644 ~/.ssh/ansible.pub
```

### SSH Config for Ansible Host

Add this to `~/.ssh/config` on your Ansible control host:

```ssh-config
Host *
  IdentityFile ~/.ssh/ansible
  IdentitiesOnly yes
  ForwardAgent no
  StrictHostKeyChecking accept-new
  Port 22
```

---

## Step 3: Clone Ansible Homelab Repository

```bash
# Clone the repository
git clone https://github.com/nicksweb/ansible-homelab.git
cd ansible-homelab

# Install Galaxy roles
ansible-galaxy install -r requirements.yml
```

---

## Step 4: Push Public Key to Managed Hosts

### Method 1: Using ssh-copy-id (Manual per host)

```bash
# For machines with password auth (temporary)
ssh-copy-id -i ~/.ssh/ansible.pub localadmin@172.16.0.23

# For Proxmox hosts (root user)
ssh-copy-id -i ~/.ssh/ansible.pub root@sapve01
```

### Method 2: Automated via Ansible (Recommended)

Create a playbook to push keys to multiple hosts at once:

```bash
# For machines using password auth on first setup:
ansible -i inventory all -m authorized_key \
  -a "user=localadmin key='{{ lookup(\"file\", \"~/.ssh/ansible.pub\") }}' state=present" \
  -k  # Prompts for SSH password
```

For root users:
```bash
ansible -i inventory proxmox -m authorized_key \
  -a "user=root key='{{ lookup(\"file\", \"~/.ssh/ansible.pub\") }}' state=present" \
  -k
```

### Method 3: Script for Bulk Setup

Create a file `push-keys.sh`:

```bash
#!/bin/bash

ANSIBLE_KEY="$HOME/.ssh/ansible.pub"
INVENTORY="$1"

if [ ! -f "$ANSIBLE_KEY" ]; then
  echo "ERROR: SSH key not found at $ANSIBLE_KEY"
  exit 1
fi

# Get all hosts from inventory
HOSTS=$(ansible -i "$INVENTORY" all --list-hosts | grep -v "^  ")

echo "Pushing SSH key to ${#HOSTS[@]} hosts..."

for host in $HOSTS; do
  echo "Setting up $host..."
  
  # Try as localadmin first
  ssh-copy-id -i "$ANSIBLE_KEY" -o ConnectTimeout=5 "localadmin@$host" 2>/dev/null && \
  echo "✓ $host (localadmin)" && continue
  
  # Try as root if localadmin fails
  ssh-copy-id -i "$ANSIBLE_KEY" -o ConnectTimeout=5 "root@$host" 2>/dev/null && \
  echo "✓ $host (root)" && continue
  
  # Try hostname without user
  ssh-copy-id -i "$ANSIBLE_KEY" -o ConnectTimeout=5 "$host" 2>/dev/null && \
  echo "✓ $host" && continue
  
  echo "✗ $host (failed)"
done

echo "Done!"
```

Usage:
```bash
chmod +x push-keys.sh
./push-keys.sh inventory
```

---

## Step 5: Verify Control Host Setup

```bash
# Test connectivity to all machines
ansible -i inventory all -m ping

# Expected output: All machines should respond with "pong"

# Test as specific group
ansible -i inventory proxmox -m ping
```

---

## SSH Key Reference

### Key Usage by Host Type

| Host Type | User | SSH Key | Notes |
|-----------|------|---------|-------|
| Proxmox | root | `~/.ssh/ansible` | Direct root access |
| Ubuntu Servers | localadmin | `~/.ssh/ansible` | Sudo access |
| Debian Servers | localadmin | `~/.ssh/ansible` | Sudo access |
| Raspberry Pi | localadmin / pi | `~/.ssh/ansible` | Depends on OS |
| Docker Hosts | localadmin | `~/.ssh/ansible` | Sudo access |
| Workstations | localadmin | `~/.ssh/ansible` | Sudo access |

### Exception: User-Specific Keys

One host uses a user-specific key:
```ini
172.16.0.60 ansible_user=nicholaso private_key_file=~/.ssh/nicholaso.corsair3900x
```

For new user-specific keys:
1. Generate the key: `ssh-keygen -t ed25519 -f ~/.ssh/username`
2. Add to inventory: `hostname ansible_user=username private_key_file=~/.ssh/username`
3. Push the public key to the host

---

## Ansible Config File (ansible.cfg)

Key settings for your control host:

```ini
[ssh_connection]
pipelining = True
# Enables faster execution by reducing SSH overhead

[defaults]
inventory = inventory
# Use local inventory file as default

private_key_file = ~/.ssh/ansible
# Default SSH key for all connections

interpreter_python = /usr/bin/python3
# Use Python 3 for remote execution
```

---

## Troubleshooting Control Host Setup

### "Permission denied (publickey)"
- Verify public key is on remote host: `ssh -v -i ~/.ssh/ansible user@host`
- Check key permissions: `ls -la ~/.ssh/ansible*` (should be 600 for private key)
- Ensure `~/.ssh/authorized_keys` exists on remote: `ls -la ~/.ssh/`

### "Failed to connect to host via ssh"
- Check SSH service is running on remote: `systemctl status ssh`
- Verify firewall allows port 22
- Check IP/hostname in inventory is correct

### "Python3 not found on remote host"
- Install Python3: `ansible -i inventory all -m raw -a "apt install -y python3" -k`
- Update inventory to specify Python path if needed

### "SSH key not being used"
- Check `IdentitiesOnly yes` in `~/.ssh/config`
- Verify key is in `~/.ssh/` directory
- Try explicit key in command: `ssh -i ~/.ssh/ansible user@host`

---

## Adding a New Control Node

When setting up an additional Ansible control node:

1. **Generate new SSH key** (or copy existing if shared):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@homelab-backup" -N ""
   ```

2. **Push key to all managed hosts**:
   ```bash
   # From new control host
   cd ansible-homelab
   ansible-playbook playbooks/setup-ssh-keys.yml -k
   # (Use script or manual ssh-copy-id as shown above)
   ```

3. **Test connectivity**:
   ```bash
   ansible -i inventory all -m ping
   ```

4. **Add control node to inventory** (optional, if you want to manage the control node itself):
   ```ini
   [control_nodes]
   172.16.0.60 ansible_user=nicholaso
   ```

---

## Security Best Practices

1. **Use one SSH key for all systems** ✅ (current setup)
   - Simpler to manage
   - Easier to rotate all at once
   - Store securely with restricted permissions

2. **SSH Key Permissions**:
   ```bash
   chmod 600 ~/.ssh/ansible          # Private key
   chmod 644 ~/.ssh/ansible.pub      # Public key
   chmod 700 ~/.ssh                  # .ssh directory
   chmod 600 ~/.ssh/authorized_keys  # On remote hosts
   ```

3. **SSH Agent** (optional, for frequently-used keys):
   ```bash
   ssh-add ~/.ssh/ansible
   # Now SSH uses the key without typing passphrase
   ```

4. **Consider SSH Key Passphrase**:
   ```bash
   # If you want to add passphrase to existing key:
   ssh-keygen -p -f ~/.ssh/ansible -N "newpassphrase"
   
   # Use with ssh-agent to avoid repeated prompts:
   ssh-add ~/.ssh/ansible
   # Enter passphrase once, then use without prompts
   ```

5. **Rotate SSH Keys Periodically**:
   - Generate new key with different name
   - Push to all hosts
   - Remove old key from `authorized_keys` on all hosts
   - Delete old key from `~/.ssh/`

---

## SSH Key Generation on Managed Hosts

When onboarding new machines, the `setup-onboard.yml` playbook can automatically generate SSH key pairs on managed hosts.

### Automatic Key Generation

The `setup-onboard.yml` playbook generates ed25519 SSH keys on new hosts:

```bash
ansible-playbook playbooks/setup-onboard.yml -i inventory -kK --limit "new_host"
```

Keys are generated at:
- **Private**: `~/.ssh/id_ed25519`
- **Public**: `~/.ssh/id_ed25519.pub`

### Retrieve Host Public Keys

To get the public key from a host (for cross-host SSH setup):

```bash
# Display on screen
ssh localadmin@hostname cat ~/.ssh/id_ed25519.pub

# Or save to file
ssh localadmin@hostname cat ~/.ssh/id_ed25519.pub >> /tmp/hosts_keys.pub
```

### Add Host Key to Another Host

To allow host A to SSH to host B without a password:

```bash
# Retrieve B's public key
ssh localadmin@hostB cat ~/.ssh/id_ed25519.pub > /tmp/hostB_key.pub

# Add to A's authorized_keys (from A)
ansible -i inventory hostA -m authorized_key \
  -a "user=localadmin key='{{ lookup(\"file\", \"/tmp/hostB_key.pub\") }}' state=present"
```

---

## Quick Reference: First-Time Control Host Setup

```bash
# 1. Install Ansible
sudo apt update && sudo apt install -y ansible

# 2. Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@homelab" -N ""

# 3. Clone repository
git clone https://github.com/nicksweb/ansible-homelab.git
cd ansible-homelab

# 4. Install Galaxy requirements
ansible-galaxy install -r requirements.yml

# 5. Push SSH key to hosts (using script or ssh-copy-id)
./push-keys.sh inventory

# 6. Verify setup
ansible -i inventory all -m ping

# 7. Run your first playbook
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory --limit "1 host" --check
```

---

**Control Host Setup Version**: 1.0  
**Last Updated**: June 2026  
**Recommended OS**: Ubuntu 24.04 LTS / Debian 13
