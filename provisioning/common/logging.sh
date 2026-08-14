#!/usr/bin/env bash
# Shared logging helpers — sourced by every script under provisioning/.
# Never log secrets. Callers must pass already-redacted strings.
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }
