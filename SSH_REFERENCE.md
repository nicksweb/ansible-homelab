# SSH Configuration Reference

Keep site-specific hostnames, addresses, usernames, jump hosts, and identity
files in your local SSH configuration rather than this repository.

Example `~/.ssh/config` entries:

```sshconfig
Host app01
    HostName 192.0.2.10
    User localadmin
    IdentityFile ~/.ssh/ansible

Host internal-app
    HostName 192.0.2.20
    User localadmin
    ProxyJump jump-host
```

Prefer `ansible_host` in the ignored local `inventory` file when an Ansible
alias should connect directly to an address:

```ini
[application]
app01 ansible_host=192.0.2.10 ansible_user=localadmin
```

Use addresses reserved for documentation in committed examples. Never commit
private keys, passwords, live public addresses, or detailed network maps.
