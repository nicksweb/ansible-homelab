#!/usr/bin/env bash
# Shared helper for invoking the Ansible roles under playbooks/roles/provisioning/
# from a bash orchestrator. Requires common/logging.sh already sourced.
#
# Deliberately uses the system temp dir (mktemp's default) for its short-
# lived inventory/extra-vars files rather than each toolkit's own $STATE_DIR
# — this file is sometimes sourced by scripts (like
# common/install-cloudflare-tunnel.sh) that run as a separate process via
# command substitution, where a caller's own unexported shell variables
# (STATE_DIR included) don't cross the process boundary. The system temp
# dir needs no such inheritance and every file written here is deleted
# before this function returns either way.
#
# The orchestrators (provision-server.sh, provision-container.sh, destroy-*.sh)
# keep doing all cloud/DNS/state-tracking API work directly in bash — only the
# "SSH to the target and configure it" steps hand off to Ansible, via this
# function.

ANSIBLE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ansible_run_playbook <playbook_relpath> <target_ip> <ssh_user> <ssh_key> [extra_vars_json]
#
# <playbook_relpath> is relative to the repo root, e.g.
# "playbooks/provisioning/tailscale_join.yml".
#
# <extra_vars_json>, if given, is written to a mode-600 temp file and passed
# as `--extra-vars @file` rather than literal `-e key=value` — the latter is
# visible in `ps` for the life of the ansible-playbook process; a file that's
# deleted the moment the process returns isn't. This is the closest
# available equivalent to this toolkit's stdin-secret-piping discipline for
# values (like a freshly-minted Tailscale authkey or Cloudflare connector
# token) that only ever exist in this script's own shell variables — never
# on the control host's disk otherwise.
ansible_run_playbook() {
  local playbook_relpath="$1" target_ip="$2" ssh_user="$3" ssh_key="$4" extra_vars_json="${5:-}"
  local inv_file vars_file rc=0

  inv_file="$(mktemp -t ansible-inventory.XXXXXX)"
  cat > "$inv_file" <<INV
[target]
${target_ip} ansible_user=${ssh_user} ansible_ssh_private_key_file=${ssh_key} ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
INV

  local args=(-i "$inv_file" "$ANSIBLE_REPO_ROOT/$playbook_relpath")

  if [ -n "$extra_vars_json" ]; then
    vars_file="$(mktemp -t ansible-vars.XXXXXX.json)"
    chmod 600 "$vars_file"
    printf '%s' "$extra_vars_json" > "$vars_file"
    args+=(--extra-vars "@$vars_file")
  fi

  log "Running ansible-playbook $playbook_relpath against $target_ip..."
  # ansible.cfg is only auto-discovered from the CURRENT WORKING DIRECTORY —
  # it does NOT search upward through parent directories. The bash
  # orchestrators run from provisioning/<toolkit>/, not the repo root, so
  # without this, ansible-playbook silently falls back to built-in defaults
  # (wrong roles_path, no inventory=, no private_key_file=) — confirmed
  # directly: "role not found" on a real run despite working fine when
  # invoked manually from the repo root.
  #
  # Output goes to stderr: some callers run inside $(...) to capture their
  # own KEY=value results from stdout, which would otherwise swallow the
  # playbook's output — including the reason it failed.
  ANSIBLE_CONFIG="$ANSIBLE_REPO_ROOT/ansible.cfg" ansible-playbook "${args[@]}" >&2 || rc=$?

  rm -f "$inv_file"
  [ -n "${vars_file:-}" ] && rm -f "$vars_file"
  return $rc
}

# ansible_run_playbook_root <playbook_relpath> <target_ip> <extra_vars_json>
# Same as above, but connects as root (no ssh key override — used only for
# container_bootstrap.yml against a stock LXC template, which has no other
# account yet and is reached with the same provisioning key already
# implied by the caller's own ssh-agent/known key, passed in explicitly).
ansible_run_playbook_root() {
  local playbook_relpath="$1" target_ip="$2" ssh_key="$3" extra_vars_json="${4:-}"
  ansible_run_playbook "$playbook_relpath" "$target_ip" "root" "$ssh_key" "$extra_vars_json"
}

# ansible_vhosts_teardown <name> — for destroy-*.sh: deletes the Cloudflare
# CNAMEs and UDM records of every vhost declared for <name> in
# provisioning/inventory (plus a cloud server's UDM host record), via the
# vhosts playbook in teardown mode, which never touches the server itself.
# Then archives its host_vars so a future server reusing the name starts
# with no vhosts. Must run while <name>'s state is still live (the dynamic
# inventory skips DESTROYED servers).
ansible_vhosts_teardown() {
  local name="$1" inv="$ANSIBLE_REPO_ROOT/provisioning/inventory" rc=0
  local hv="$inv/host_vars/$name"
  if ! ANSIBLE_CONFIG="$ANSIBLE_REPO_ROOT/ansible.cfg" ansible-inventory -i "$inv" --host "$name" >/dev/null 2>&1; then
    log "$name isn't in the provisioned inventory (status not Completed) — no vhost records to remove."
    return 0
  fi
  log "Removing $name's vhost DNS records (Cloudflare + UDM) via Ansible..."
  ANSIBLE_CONFIG="$ANSIBLE_REPO_ROOT/ansible.cfg" ansible-playbook -i "$inv" \
    "$ANSIBLE_REPO_ROOT/playbooks/provisioning/vhosts.yml" -l "$name" -e vhosts_teardown=true >&2 || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$hv" ]; then
    mv "$hv" "$hv.destroyed-$(date +%Y%m%d-%H%M%S)"
    log "Archived $hv"
  fi
  return $rc
}

# ansible_declared_vhosts <name> — prints the hostnames declared in
# provisioning/inventory/host_vars/<name>/vhosts.yml, one per line.
ansible_declared_vhosts() {
  local f="$ANSIBLE_REPO_ROOT/provisioning/inventory/host_vars/$1/vhosts.yml"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY'
import sys, yaml
for v in (yaml.safe_load(open(sys.argv[1])) or {}).get("vhosts") or []:
    print(v if isinstance(v, str) else v.get("hostname", ""))
PY
}

# ansible_vhost_add <name> <hostname> — records <hostname> in <name>'s
# host_vars and converges it (vhost_add.yml). <name> must already be in the
# provisioned inventory, i.e. its state written with status Completed.
ansible_vhost_add() {
  ANSIBLE_CONFIG="$ANSIBLE_REPO_ROOT/ansible.cfg" ansible-playbook -i "$ANSIBLE_REPO_ROOT/provisioning/inventory" \
    "$ANSIBLE_REPO_ROOT/playbooks/provisioning/vhost_add.yml" -l "$1" -e "vhost=$2" >&2
}
