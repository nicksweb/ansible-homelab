#!/usr/bin/env bash
# Shared SSH helpers — sourced by every script under provisioning/.
# Requires common/logging.sh to already be sourced (uses log()).

SSH_CONTROL_DIR="$HOME/.ssh/controlmasters"
mkdir -p "$SSH_CONTROL_DIR"
chmod 700 "$SSH_CONTROL_DIR"

# Reuse one persistent connection per host across a run instead of opening a
# fresh TCP+SSH handshake for every command — cuts connection churn, which
# also mitigates (though doesn't explain) the intermittent SSH reachability
# issues observed during the BinaryLane work.
SSH_MULTIPLEX_OPTS=(-o "ControlMaster=auto" -o "ControlPersist=15m" -o "ControlPath=$SSH_CONTROL_DIR/%r@%h:%p")

ssh_opts() {
  # ssh_opts <key_path> — sets the global SSH_OPTS array, ready to use with
  # ssh/scp: ssh_opts "$KEY"; ssh "${SSH_OPTS[@]}" user@host ...
  SSH_OPTS=(-i "$1" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SSH_MULTIPLEX_OPTS[@]}")
}

ssh_close_multiplexed() {
  local user="$1" host="$2"
  ssh -o "ControlPath=$SSH_CONTROL_DIR/%r@%h:%p" -O exit "${user}@${host}" >/dev/null 2>&1 || true
}

# clear_stale_host_key <ip> — this toolkit reuses fixed reservation IPs by
# design (destroy a container, provision a new one, it can land on the same
# address), and each fresh container gets its own newly-generated SSH host
# key. StrictHostKeyChecking=accept-new only auto-trusts a host with NO
# existing known_hosts entry — a CHANGED key for an address already in
# known_hosts is rejected outright (correctly, in general — that's the
# MITM protection working as intended). Confirmed directly: this caused
# `wait_for_ssh` to fail every single attempt for the full timeout window
# against a legitimately new container, reported as a generic "could not
# establish SSH" with zero indication of the real cause, since
# wait_for_ssh redirects stderr to /dev/null. Since we always call this
# right after we ourselves just created the container now sitting at this
# IP, clearing the old entry first is safe — we're not blindly trusting an
# unknown host, we're discarding a key we know is stale.
clear_stale_host_key() {
  local ip="$1"
  ssh-keygen -q -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true
}

wait_for_ssh() {
  # wait_for_ssh <key_path> <user> <host> <max_attempts> <sleep_secs>
  local key="$1" user="$2" host="$3" attempts="${4:-20}" sleep_secs="${5:-10}"
  local i
  clear_stale_host_key "$host"
  for i in $(seq 1 "$attempts"); do
    if ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -o BatchMode=yes \
        "${SSH_MULTIPLEX_OPTS[@]}" "${user}@${host}" 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_secs"
  done
  return 1
}
