#!/usr/bin/env bash
# Runs ON THE REMOTE HOST (VM or LXC, any backend) via ssh+sudo. Installs the
# Beszel monitoring agent using the official get.beszel.dev installer and
# registers it with the existing Beszel hub via a universal token — the
# agent connects outbound to the hub, so no inbound port needs opening on
# this container and no per-system pre-registration is needed on the hub
# side first.
#
# Usage: install-beszel-agent.sh <hub_url> <hub_key> [port]
# <hub_key> is the hub's own SSH public key (from the hub's Settings/Add
# System page) — NOT secret, safe as a plain argument. Passing an empty
# string here (`-k ""`) looks like it should be valid for "token-only"
# registration but isn't: confirmed directly against a real hub that the
# agent binary hard-requires a key to even start ("Failed to load public
# keys: no key provided"), regardless of an otherwise-valid token — an
# under-documented gap, also reported upstream
# (henrygd/beszel#1435). The universal token IS read from stdin — never
# passed as an argument or written to shell history, same discipline as
# every other credential in this toolkit. Beszel's own installer writes it
# into its systemd unit's Environment= line in plaintext on the remote host
# regardless (that's upstream's design, not something this script
# controls) — what this script does control is that it never touches
# the control host's disk or logs on the way there.
set -euo pipefail

HUB_URL="${1:?usage: install-beszel-agent.sh <hub_url> <hub_key> [port]  (token via stdin)}"
HUB_KEY="${2:?usage: install-beszel-agent.sh <hub_url> <hub_key> [port]  (token via stdin)}"
PORT="${3:-45876}"

log() { echo "[beszel-agent] $*"; }

TOKEN="$(cat -)"
[ -n "$TOKEN" ] || { echo "No token received on stdin" >&2; exit 1; }

log "Installing Beszel agent (hub: $HUB_URL, port: $PORT)"
# Deliberately NOT /tmp/install-beszel-agent.sh — this wrapper script is
# itself uploaded to the container at that exact path and is still running
# while this line executes. Downloading Beszel's own installer to the same
# filename overwrites the running script's file mid-execution, which
# corrupts bash's read of the remaining lines (confirmed directly: caused a
# bogus "syntax error near unexpected token '('" at a line number that only
# existed in the downloaded file, not this one — bash doesn't necessarily
# have the whole script buffered in memory for a straight invocation like
# this). Any name that doesn't collide with this file's own path works.
curl -sL https://get.beszel.dev -o /tmp/beszel-official-install.sh
chmod +x /tmp/beszel-official-install.sh
# `</dev/null`: the installer has two interactive prompts (SSH key, daily
# auto-update) if their values aren't supplied explicitly. `-k`/`-t`/`-url`
# and `--auto-update=true` supply everything up front, but redirecting
# stdin from /dev/null too makes this deterministic rather than relying on
# "stdin happens to already be at EOF from the token pipe" — confirmed
# during testing that both prompts flashed by and were silently skipped
# only because of that pipe behavior, which isn't something to depend on.
sudo /tmp/beszel-official-install.sh -p "$PORT" -k "$HUB_KEY" -t "$TOKEN" -url "$HUB_URL" --auto-update=true </dev/null
rm -f /tmp/beszel-official-install.sh
unset TOKEN

# A single is-active check right after start isn't reliable — confirmed
# directly during testing that it can catch the service mid-crash-loop, in
# the few-second window before systemd's restart backoff registers the
# failure, giving a false "active" reading. Poll for the log line that
# proves a genuinely successful hub connection instead of trusting process
# status alone.
log "Verifying the agent actually connected to the hub (not just that the process started)..."
CONNECTED=false
for i in $(seq 1 15); do
  sudo journalctl -u beszel-agent --no-pager -n 5 2>/dev/null | grep -q "WebSocket connected" && { CONNECTED=true; break; }
  sleep 2
done
if $CONNECTED; then
  log "Confirmed: agent connected to $HUB_URL."
else
  echo "Agent did not confirm a WebSocket connection to $HUB_URL within 30s — check 'journalctl -u beszel-agent' on the container. Common causes: wrong hub key, hub unreachable, or (seen during development) the hub's own reverse proxy missing WebSocket support." >&2
  exit 1
fi
