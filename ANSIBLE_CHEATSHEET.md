# Ansible Learning Cheat Sheet

This guide is a compact reference for operating and learning Ansible in this
repository. Run commands from the repository root unless noted otherwise.

## The mental model

- **Control node**: The machine where Ansible is installed and commands run.
- **Managed host**: A remote machine configured by Ansible.
- **Inventory**: Hosts, groups, connection users, and host-specific variables.
- **Module**: One idempotent unit of work, such as `apt`, `copy`, or `service`.
- **Task**: A named invocation of a module.
- **Play**: Maps tasks or roles to a host pattern.
- **Playbook**: One or more plays stored in YAML.
- **Role**: Reusable defaults, tasks, handlers, templates, and files.
- **Facts**: Information Ansible gathers from a managed host.
- **Idempotence**: Repeated runs converge on the requested state without
  repeatedly changing an already-correct system.

## Initial setup

```bash
cp inventory.example inventory
ansible-galaxy install -r requirements.yml
ansible-inventory --graph
```

The real `inventory` is ignored by Git. Keep live addresses, usernames, and
host-specific connection details there.

## Inventory essentials

Friendly names can connect directly to addresses:

```ini
[web]
web01 ansible_host=192.0.2.10 ansible_user=localadmin
web02 ansible_host=192.0.2.11 ansible_user=localadmin

[production:children]
web

[web:vars]
ansible_python_interpreter=/usr/bin/python3
```

Inspect inventory:

```bash
ansible-inventory --graph
ansible-inventory --list
ansible-inventory --host web01
ansible all --list-hosts
```

Useful host patterns:

```bash
ansible all --list-hosts
ansible web --list-hosts
ansible 'web:db' --list-hosts          # Union: web or db
ansible 'production:&web' --list-hosts # Intersection
ansible 'all:!proxmox' --list-hosts    # Exclusion
ansible 'web01:web02' --list-hosts     # Explicit hosts
```

Quote patterns containing `:`, `!`, or `&` so the shell does not interpret
them.

## Ad-hoc commands

Ad-hoc commands are useful for inspection and one-off operations:

```bash
# Verify SSH, Python, and module execution
ansible all -m ansible.builtin.ping

# Gather facts
ansible web01 -m ansible.builtin.setup
ansible web01 -m ansible.builtin.setup -a 'filter=ansible_distribution*'

# Run a command without shell features
ansible all -m ansible.builtin.command -a 'uptime'

# Use shell syntax only when pipes, redirects, or expansion are required
ansible all -m ansible.builtin.shell -a 'df -h | sort -k5'

# Copy a file
ansible web -b -m ansible.builtin.copy \
  -a 'src=files/example.conf dest=/etc/example.conf mode=0644'

# Manage a service
ansible web -b -m ansible.builtin.service \
  -a 'name=nginx state=restarted enabled=true'
```

Common flags:

| Flag | Meaning |
|---|---|
| `-i inventory` | Select inventory file; already configured in `ansible.cfg` |
| `-m MODULE` | Module to execute |
| `-a 'ARGS'` | Module arguments |
| `-b` / `--become` | Use privilege escalation |
| `-K` / `--ask-become-pass` | Prompt for sudo password |
| `-k` / `--ask-pass` | Prompt for SSH password |
| `-l PATTERN` / `--limit PATTERN` | Restrict selected hosts |
| `-e KEY=VALUE` | Add an extra variable |
| `-f NUMBER` / `--forks NUMBER` | Set concurrency |
| `-v` through `-vvvv` | Increase diagnostic output |
| `-o` | One-line ad-hoc output |

## Running playbooks

```bash
ansible-playbook playbooks/site-baseline.yml
ansible-playbook playbooks/site-baseline.yml --limit web01
ansible-playbook playbooks/site-baseline.yml --check --diff
ansible-playbook playbooks/site-baseline.yml --syntax-check
ansible-playbook playbooks/site-baseline.yml --list-hosts
ansible-playbook playbooks/site-baseline.yml --list-tasks
ansible-playbook playbooks/site-baseline.yml -e common_timezone=UTC
```

Check mode predicts changes but cannot perfectly simulate every module or
external command. Review the diff and still limit the first real run to one
host.

## Minimal playbook anatomy

```yaml
---
- name: Configure web servers
  hosts: web
  gather_facts: true
  become: true

  vars:
    package_name: nginx

  tasks:
    - name: Install web package
      ansible.builtin.apt:
        name: "{{ package_name }}"
        state: present
        update_cache: true
      notify: Restart web service

    - name: Write configuration
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        owner: root
        group: root
        mode: '0644'

  handlers:
    - name: Restart web service
      ansible.builtin.service:
        name: nginx
        state: restarted
```

Prefer fully qualified module names such as `ansible.builtin.apt` and
`ansible.posix.authorized_key`. They make module ownership unambiguous.

## Variables

Common variable locations:

```text
role/defaults/main.yml       Lowest role precedence; reusable defaults
inventory group variables   Shared values for a group
inventory host variables    Values for one host
play vars                    Values scoped to a play
-e / --extra-vars           Highest common precedence
```

Examples:

```yaml
timezone_name: Australia/Brisbane
packages:
  - htop
  - tmux
service_enabled: true
```

```yaml
- name: Install packages
  ansible.builtin.apt:
    name: "{{ packages }}"
    state: present

- name: Enable optional service
  ansible.builtin.service:
    name: example
    enabled: true
  when: service_enabled | bool
```

Show variable resolution:

```bash
ansible-inventory --host web01
ansible web01 -m ansible.builtin.debug -a 'var=hostvars[inventory_hostname]'
```

## Loops, results, and conditions

```yaml
- name: Create directories
  ansible.builtin.file:
    path: "/srv/{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - application
    - backups

- name: Check application version
  ansible.builtin.command: application --version
  register: application_version
  changed_when: false

- name: Display version
  ansible.builtin.debug:
    var: application_version.stdout
  when: application_version.rc == 0
```

## Tags

Tasks and roles can be tagged for selective execution:

```yaml
- name: Install monitoring packages
  ansible.builtin.apt:
    name: htop
    state: present
  tags:
    - packages
    - monitoring
```

```bash
ansible-playbook playbooks/example.yml --list-tags
ansible-playbook playbooks/example.yml --tags packages
ansible-playbook playbooks/example.yml --skip-tags reboot
```

## SSH keys and sudo

```bash
# First-time public-key deployment using the current SSH password
./deploy-ansible-key --bootstrap --limit web01

# Configure passwordless sudo using the current sudo password
./enable-passwordless-sudo --limit web01 --ask-become-pass

# Verify ordinary Ansible access
ansible web01 -m ansible.builtin.ping -e ansible_become=false

# Verify privilege escalation
ansible web01 -b -m ansible.builtin.command -a 'whoami'
```

Never copy the control node's private key to managed hosts. Only distribute
`~/.ssh/ansible.pub`.

## Ansible Vault

Create and edit encrypted variables:

```bash
ansible-vault create group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml
ansible-vault encrypt_string --name vault_example_password
```

Run a playbook using Vault:

```bash
ansible-playbook playbooks/example.yml --ask-vault-pass
```

Reference encrypted variables without exposing their values:

```yaml
database_password: "{{ vault_database_password }}"
```

Do not put plaintext passwords, tokens, private keys, or live inventory data in
Git—even briefly. Removing a secret in a later commit does not remove it from
Git history.

## Repository workflows

```bash
# Onboard a standard Debian/Ubuntu host
./onboard-linux --limit server01 --ask-become-pass

# Onboard a Docker host with the same baseline
./onboard-docker-host --limit docker01 --ask-become-pass

# Shared public key and Australia/Brisbane timezone
ansible-playbook playbooks/site-baseline.yml

# Desktop provisioning
ansible-playbook playbooks/desktop-workstation.yml --limit desktop01

# Proxmox updates, one node at a time
./update-proxmox --check --diff
./update-proxmox
./update-proxmox --reboot

# Network speed tests
./run-speedtest
./run-speedtest --sequential
```

## Troubleshooting sequence

Work from the bottom of the stack upward:

```bash
# 1. Confirm inventory selection and connection variables
ansible-inventory --host web01

# 2. Confirm network reachability
ping -c 2 192.0.2.10

# 3. Inspect raw SSH authentication
ssh -vvv localadmin@192.0.2.10

# 4. Test Ansible without sudo
ansible web01 -m ansible.builtin.ping -e ansible_become=false -vvvv

# 5. Test sudo independently
ansible web01 -b -m ansible.builtin.command -a 'id'

# 6. Validate playbook parsing and host selection
ansible-playbook playbooks/example.yml --syntax-check
ansible-playbook playbooks/example.yml --list-hosts
```

Common errors:

| Error | Likely cause |
|---|---|
| `Could not resolve hostname` | Missing or incorrect `ansible_host` |
| `Permission denied` | Wrong user/key or public key not installed |
| `Missing sudo password` | Passwordless sudo not configured; use `-K` |
| `No route to host` | Routing, host, VLAN, or firewall problem |
| `Connection timed out` | Host offline, SSH unavailable, or filtered port 22 |
| `Python interpreter not found` | Install Python or set `ansible_python_interpreter` |
| `role was not found` | Run `ansible-galaxy install -r requirements.yml` |

## Safe operating habits

1. Confirm the selected hosts with `--list-hosts`.
2. Start with one host using `--limit`.
3. Use `--check --diff` when modules support it.
4. Read the recap: distinguish `failed` from `unreachable`.
5. Avoid simultaneous reboots of clustered systems.
6. Use `serial: 1` for maintenance that must proceed host by host.
7. Keep inventories and secrets out of Git.
8. Commit automation only after syntax, documentation, and privacy checks.

## Useful documentation commands

```bash
ansible --version
ansible-config dump --only-changed
ansible-doc ansible.builtin.apt
ansible-doc ansible.posix.authorized_key
ansible-doc -l | less
ansible-galaxy role list
ansible-galaxy collection list
```
