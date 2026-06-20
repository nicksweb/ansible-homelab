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

### SSH Key Strategy: Per-Control-Node Keys

Each control node (MacBook, desktop, Raspberry Pi, etc.) has its own SSH key pair. All managed hosts have the public keys from all control nodes in their `authorized_keys`. This provides:

- **Security**: Each control node has its own private key (never shared)
- **Flexibility**: Easy to add new control nodes
- **Scalability**: Works with multiple control nodes managing the same infrastructure

### Generate SSH Key (if needed)

Run this on **each control node**:

```bash
# Generate new SSH key for Ansible on this control node
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@homelab" -N ""

# Or RSA if Ed25519 not available
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ansible -C "ansible@homelab" -N ""

# Set secure permissions
chmod 600 ~/.ssh/ansible
chmod 644 ~/.ssh/ansible.pub

# Show the public key (you'll need this for managed hosts)
cat ~/.ssh/ansible.pub
```

### Configure ansible.cfg on Each Control Node

On each control node, ensure `ansible.cfg` has:

```ini
[defaults]
private_key_file = ~/.ssh/ansible
```

Each control node looks for its own `~/.ssh/ansible` key.

### SSH Config for Ansible Host

Add this to `~/.ssh/config` on **each control node**:

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
ssh-copy-id -i ~/.ssh/ansible.pub localadmin@192.0.2.23

# For Proxmox hosts (root user)
ssh-copy-id -i ~/.ssh/ansible.pub root@hypervisor01
```

### Method 2: Automated via Ansible (Recommended)

#### For a Single Control Node

When you have one control node set up and need to distribute its public key:

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

#### For Multiple Control Nodes

When adding a **second control node** (e.g., desktop after using MacBook), you need to add its public key to all managed hosts:

```bash
# On the NEW control node:
# 1. Generate key (see Step 2 above)
# 2. Get the public key
cat ~/.ssh/ansible.pub

# 3. Add it to all managed hosts from the NEW control node:
ansible -i inventory all -m authorized_key \
  -a "user=localadmin key='<paste your public key here>' state=present" \
  -k

# For root users:
ansible -i inventory proxmox -m authorized_key \
  -a "user=root key='<paste your public key here>' state=present" \
  -k
```

Now **both** control nodes can manage all hosts!

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
workstation01 ansible_host=192.0.2.60 ansible_user=localadmin
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

When setting up an additional Ansible control node (e.g., desktop after MacBook, or new workstation):

### Step 1: Set Up on New Control Node

```bash
# Follow the setup steps above:
# 1. Install Ansible
# 2. Generate its own SSH key
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C "ansible@homelab-$(hostname)" -N ""

# 3. Clone repository
git clone https://github.com/nicksweb/ansible-homelab.git
cd ansible-homelab
ansible-galaxy install -r requirements.yml

# 4. Configure ansible.cfg (already set up in repo)
```

### Step 2: Add New Control Node's Public Key to All Managed Hosts

On the **new control node**, add its public key to all managed hosts:

```bash
# Get this control node's public key
cat ~/.ssh/ansible.pub

# Add it to all managed hosts
ansible -i inventory all -m authorized_key \
  -a "user=localadmin key='{{ lookup(\"file\", \"~/.ssh/ansible.pub\") }}' state=present" \
  -k  # Prompts for SSH password

# For Proxmox and root users:
ansible -i inventory proxmox -m authorized_key \
  -a "user=root key='{{ lookup(\"file\", \"~/.ssh/ansible.pub\") }}' state=present" \
  -k
```

**Alternative: Manual distribution**

If the new control node can't reach managed hosts yet:

1. Get the new key's public key content:
   ```bash
   cat ~/.ssh/ansible.pub
   ```

2. From an existing control node, add it manually:
   ```bash
   # On existing control node
   NEWKEY=\"paste_the_public_key_here\"
   ansible -i inventory all -m authorized_key \
     -a \"user=localadmin key='$NEWKEY' state=present\"
   
   ansible -i inventory proxmox -m authorized_key \
     -a \"user=root key='$NEWKEY' state=present\"
   ```

### Step 3: Test New Control Node

```bash
# From the new control node
ansible -i inventory all -m ping
```

### Step 4: Add Control Node to Inventory (Optional)

If you want to manage the control node itself:

```ini
[control_nodes]
macbook.local ansible_user=localadmin
desktop.local ansible_user=localadmin
```

**Each control node now has:**
- Its own `~/.ssh/ansible` private key
- Permission to manage all hosts (public key in their authorized_keys)
- Independent setup (losing one doesn't break others)

---

## Security Best Practices

1. **Per-Control-Node SSH Keys** ✅ (current setup)
   - Each control node has its own private key
   - Never share private keys between machines
   - Easier to revoke access from a single control node if needed
   - Better auditability (track which machine made changes)

2. **Multiple Control Nodes**:
   - All managed hosts have public keys from ALL control nodes in `authorized_keys`
   - Each control node operates independently
   - Losing one control node doesn't affect others
   - Adding new control nodes just requires adding its public key to managed hosts

3. **SSH Key Permissions**:
   ```bash
   chmod 600 ~/.ssh/ansible          # Private key
   chmod 644 ~/.ssh/ansible.pub      # Public key
   chmod 700 ~/.ssh                  # .ssh directory
   chmod 600 ~/.ssh/authorized_keys  # On remote hosts
   ```

4. **SSH Agent** (optional, for frequently-used keys):
   ```bash
   ssh-add ~/.ssh/ansible
   # Now SSH uses the key without typing passphrase
   ```

5. **Consider SSH Key Passphrase**:
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
