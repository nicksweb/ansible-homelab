# Remote Ansible Control Node Runbook

This runbook covers a remote Ansible control node, its WireGuard path
into the home network, friendly inventory names, SSH-key deployment, and
connectivity troubleshooting.

## Control node layout

| Item | Location or value |
|---|---|
| Administrative account | `localadmin` |
| Repository | `~/ansible-homelab` |
| Ansible private key | `~/.ssh/ansible` |
| Ansible public key | `~/.ssh/ansible.pub` |
| Inventory | `~/ansible-homelab/inventory` |
| Ansible configuration | `~/ansible-homelab/ansible.cfg` |
| Repeatable server bootstrap | `~/bootstrap-server.sh` |
| WireGuard interface | Site-specific, such as `wg-home` |

Never copy `ansible` (the private key) to managed machines. Only install
`ansible.pub` in the target account's `~/.ssh/authorized_keys` file.

## WireGuard

The control node routes the required private networks through WireGuard. Keep
the real interface name, endpoint, keys, and network ranges outside Git.

The interface starts at boot, uses a persistent keepalive, and has a watchdog
timer that restarts it when handshakes become stale.

Check the tunnel and routes:

```bash
sudo systemctl status wg-quick@wg-home
sudo systemctl status wireguard-watchdog.timer
sudo wg show wg-home
ip route show
```

## Friendly inventory names with direct IP connections

Use the first field as the readable Ansible name and `ansible_host` as the
actual SSH destination:

```ini
[hypervisors]
hypervisor01 ansible_user=root ansible_host=192.0.2.10

[docker]
docker01 ansible_user=localadmin ansible_host=192.0.2.20
```

Commands continue to use the friendly name:

```bash
ansible hypervisor01 -m ping -e ansible_become=false
ansible-playbook playbooks/example.yml --limit docker01
```

Every remote hostname must either have an `ansible_host` address or be
resolvable through DNS. Validate the inventory after editing it:

```bash
ansible-inventory --graph
ansible-inventory --host docker01
```

## First-time SSH key deployment

An SSH key cannot install itself until the control node has some existing way
to log in. The `--bootstrap` option asks for the target account's current SSH
password and then installs `ansible.pub`.

Bootstrap one host first:

```bash
cd ~/ansible-homelab
./deploy-ansible-key --bootstrap --limit app01
```

Verify that key authentication works without another password prompt:

```bash
ansible app01 -m ping -e ansible_become=false
```

Hosts that share the same SSH username and password can be processed together:

```bash
./deploy-ansible-key --bootstrap \
  --limit 'app01:app02:app03'
```

Process hosts separately when their usernames or passwords differ. For a host
already accessible with an older private key:

```bash
./deploy-ansible-key --limit hostname --private-key ~/.ssh/old-key
```

If SSH reports `Permission denied (publickey)` without offering password
authentication, use an already-authorized private key or add
`ansible.pub` through the machine's console.

The rollout is idempotent. Running it again does not duplicate the key.
The deployment wrapper also disables the inventory-wide `ansible_become=yes`
setting because an account does not need sudo to update its own authorized keys.

## Enabling passwordless sudo

After key authentication works, provide the account's existing sudo password
once to install a validated policy in `/etc/sudoers.d`:

```bash
./enable-passwordless-sudo --limit app01 --ask-become-pass
```

Hosts sharing the same login account and sudo password can be processed as a
batch:

```bash
./enable-passwordless-sudo \
  --limit 'host1:host2:host3' \
  --ask-become-pass
```

Process hosts separately when their sudo passwords differ. Hosts configured
with `ansible_user=root` are safely skipped because root does not need sudo.
The playbook writes `/etc/sudoers.d/90-ansible-<user>` with mode `0440` and
validates it with `visudo` before replacing the destination.

Verify passwordless privilege escalation:

```bash
ansible app01 -b -m command -a 'whoami'
```

The expected result is `root` without a password prompt.

## Applying the shared host baseline

The common baseline installs the control node's public key for `ansible_user`
and sets the host timezone to `Australia/Brisbane`:

```bash
ansible-playbook playbooks/site-baseline.yml \
  --limit hostname --ask-pass --ask-become-pass
```

After initial access is configured, apply it to all reachable hosts with:

```bash
ansible-playbook playbooks/site-baseline.yml
```

## Connectivity checks

### Internet speed tests

Install and run `speedtest-cli` across non-root-managed hosts:

```bash
./run-speedtest
```

The playbook excludes the `proxmox` group directly and uses up to 50 Ansible
forks so all selected hosts test concurrently. Its output therefore contains
only hosts that are actually selected for testing. These results measure
performance while the shared internet connection is under simultaneous load.
Limit it to a host or group when required:

```bash
./run-speedtest --limit app01
./run-speedtest --limit docker
```

Concurrent testing is the default. For individual, uncontended measurements,
run one host at a time with the same playbook:

```bash
./run-speedtest --sequential
./run-speedtest --sequential --limit docker
```

### Full Ansible check

Ansible's `ping` module verifies routing, SSH authentication, and remote Python.
The inventory currently enables sudo globally, so disable it for this read-only
test:

```bash
ansible all -m ansible.builtin.ping -e ansible_become=false -o
```

Test a group or selected hosts:

```bash
ansible proxmox -m ping -e ansible_become=false -o
ansible 'app01:app02:app03' -m ping -e ansible_become=false -o
```

### Network and SSH-port check without logging in

`ansible_connection=ssh` is set in the inventory. Override it with an extra
variable (higher precedence) so this check runs locally on the control node:

```bash
ansible all \
  -e ansible_connection=local \
  -m ansible.builtin.wait_for \
  -a 'host={{ ansible_host | default(inventory_hostname) }} port=22 timeout=3' \
  -o
```

You can also test one address directly:

```bash
ping -c 3 192.0.2.10
timeout 3 bash -c '</dev/tcp/192.0.2.10/22' && echo 'SSH port open'
```

## Understanding common failures

| Error | Meaning | Action |
|---|---|---|
| `pong` | Routing, SSH key, and Python all work | Host is ready |
| `Could not resolve hostname` | No `ansible_host` and remote DNS cannot resolve the alias | Add `ansible_host=<IP>` |
| `Permission denied (publickey,password)` | Network and SSH work, but the key is not authorized | Run `deploy-ansible-key --bootstrap --limit <host>` |
| `Permission denied (publickey)` | Password login is disabled and no accepted key is available | Use an old key or console access |
| `Missing sudo password` | Inventory enabled become for an account without passwordless sudo | Add `-e ansible_become=false` for checks, or use `--ask-become-pass` when sudo is required |
| `No route to host` | Host/router rejected traffic or host is unavailable | Check host power, IP, firewall, VLAN, and return route |
| `Connection timed out` | The route exists but TCP/22 did not answer | Check SSH service and firewall |
| `Connection timed out during banner exchange` | TCP connected but SSH did not complete its greeting | Check host load, sshd health, firewall inspection, or connection limits |
| `Host key verification failed` | New/changed server identity was not trusted | Verify the fingerprint; never bypass a changed-key warning blindly |

## Security practices

- Do not store SSH or sudo passwords in the inventory or Git history.
- Use Ansible Vault if persistent per-host credentials are unavoidable.
- Bootstrap hosts in groups only when they share the same credentials.
- Verify unexpected SSH host-key changes before reconnecting.
- Remove old public keys after confirming the replacement key works.
