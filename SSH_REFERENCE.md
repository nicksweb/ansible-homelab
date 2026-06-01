# SSH Configuration Reference

This file documents SSH configuration related to the Ansible homelab.

## SSH Config File: exampleservers.yaml

Located in the root of the workspace, this is an SSH client configuration file that defines connection parameters for various hosts.

### Key Hosts Defined

#### Infrastructure/Jump Hosts
- **jump-253**: Jump host at 192.168.3.57 (pi user)
  - Used as ProxyJump for accessing remote infrastructure

#### Proxmox & Services
- **172.16.1.100**: Infrastructure server (root user)
- **nodered**: Node-RED server (root user)
- **rmm**: Remote management at 3.26.197.110 (admin user)

#### Surveillance
- **frigate**: 172.16.0.93 (localadmin user)
  - Video surveillance system

#### Development/Control
- **172.16.0.60**: Primary workstation/control node
- **172.16.0.64**: Secondary workstation (nicholaso user)

#### Services
- **172.16.0.21**: Service machine (localadmin user)
- **172.16.0.28**: Service machine (localadmin user)
- **172.16.1.101**: Docker host (localadmin user)
- **172.16.1.224**: Service machine (localadmin user)

#### GitHub
- **github.com**: Git SSH key configuration (nicksweb user)

### Usage

To use these SSH config aliases:
```bash
# Direct SSH connection
ssh 172.16.1.100

# Using hostname alias
ssh frigate
ssh jump-253

# Git operations (if needed)
ssh -T git@github.com
```

### Integration with Ansible

For Ansible, the inventory takes precedence, but you can reference this SSH config for:
- Understanding available host names and aliases
- Finding jump host configurations if needed
- Cross-referencing IP addresses and hostnames

---

**Last Updated**: June 2026
