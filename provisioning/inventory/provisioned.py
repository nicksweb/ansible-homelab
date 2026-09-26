#!/usr/bin/env python3
"""Dynamic Ansible inventory of every live server the provisioning toolkits
created, read straight from their local state (provisioning/*/state/*.json)
and config (provisioning/*/config.env) — so there is nothing to keep in
sync by hand: a server appears here once provision-*.sh finishes and drops
out once destroy-*.sh marks it DESTROYED.

What each server should *serve* is declared separately, in
provisioning/inventory/host_vars/<name>/vhosts.yml (gitignored) — see
playbooks/provisioning/vhosts.yml.

Groups:  provisioned > binarylane, proxmox_lxc
Usage:   ansible-inventory -i provisioning/inventory --graph
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROVISIONING = os.path.dirname(HERE)

# Mirrors the built-in defaults in each toolkit's lib/common.sh.
DEFAULTS = {"ADMIN_USER": "localadmin", "PROVISIONING_SSH_KEY": "$HOME/.ssh/cipi", "LETSENCRYPT_EMAIL": ""}
TOOLKITS = {"binarylane": "binarylane", "proxmox": "proxmox_lxc"}


def read_config(path):
    values = dict(DEFAULTS)
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        value = m.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            value = re.sub(r"\s+#.*$", "", value)
        values[m.group(1)] = value
    return {k: os.path.expandvars(v) for k, v in values.items()}


def base_routes(toolkit, state):
    """Tunnel routes the provisioning scripts created — vhosts are added on top."""
    cf = state.get("cloudflare") or {}
    if state.get("role") == "docker-static":
        return [{"hostname": r["hostname"], "service": r["service"]} for r in cf.get("tunnel_routes") or []]
    names = [cf.get("public_hostname") or cf.get("tunnel_hostname") or ""]
    names += [a.get("hostname", "") for a in cf.get("additional_hostnames") or []]
    return [{"hostname": n, "service": "http://localhost:80"} for n in names if n]


def build():
    inventory = {
        "_meta": {"hostvars": {}},
        "all": {"children": ["provisioned"]},
        "provisioned": {"children": list(TOOLKITS.values())},
    }
    for toolkit, group in TOOLKITS.items():
        config = read_config(os.path.join(PROVISIONING, toolkit, "config.env"))
        inventory[group] = {"hosts": []}
        for path in sorted(glob.glob(os.path.join(PROVISIONING, toolkit, "state", "*.json"))):
            with open(path) as f:
                state = json.load(f)
            # Only finished builds: CREATING may be a half-built or long-gone
            # server, DESTROYED certainly is.
            if state.get("status") != "Completed" or not state.get("public_ipv4"):
                continue
            name = state.get("name") or os.path.basename(path)[:-5]
            cf = state.get("cloudflare") or {}
            tunnel_on = cf.get("tunnel_enabled") in (True, "true")
            inventory[group]["hosts"].append(name)
            inventory["_meta"]["hostvars"][name] = {
                "ansible_host": state["public_ipv4"],
                "ansible_user": config["ADMIN_USER"],
                "ansible_ssh_private_key_file": config["PROVISIONING_SSH_KEY"],
                "prov_platform": toolkit,
                "prov_role": state.get("role") or ("lamp" if toolkit == "binarylane" else "lxc"),
                "prov_fqdn": state.get("fqdn", ""),
                # binarylane: the public IPv4; proxmox: the LAN IP.
                "prov_ip": state["public_ipv4"],
                "prov_tunnel_id": (cf.get("tunnel_id") or "") if tunnel_on else "",
                "prov_tunnel_name": f"{name}-tunnel",
                "prov_base_routes": base_routes(toolkit, state),
                "prov_npm": bool((state.get("docker") or {}).get("npm_installed")),
                "prov_letsencrypt_email": config["LETSENCRYPT_EMAIL"],
                "prov_state_file": path,
            }
    return inventory


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        print("{}")
    else:
        print(json.dumps(build(), indent=2))
