#!/usr/bin/env bash
# Runs ON THE REMOTE CONTAINER via ssh+sudo, orchestrated by
# bin/deploy-mariadb-stack.sh (and reusable by any future docker-based
# deploy script). Installs Docker Engine + the Compose plugin via the
# official get.docker.com convenience script — not Ubuntu's own repo
# package, which lags behind new releases the same way pkg.cloudflare.com
# did for cloudflared (confirmed pattern this session: 26.04 is new enough
# that codename-pinned third-party repos routinely don't have it yet).
# get.docker.com detects the distro/codename itself and has historically
# been quick to add new Ubuntu releases.
#
# Requires the container to have been created with Proxmox's `nesting=1`
# LXC feature (every container this toolkit creates has it) — that's what
# makes running Docker inside an unprivileged LXC container possible at
# all. Verifies this for real with `docker run hello-world` rather than
# just assuming the feature flag is sufficient.
#
# Usage: install-docker.sh
set -euo pipefail

log() { echo "[install-docker] $*"; }

if command -v docker >/dev/null 2>&1; then
  log "Docker already installed ($(docker --version))"
else
  log "Installing Docker via get.docker.com"
  curl -fsSL https://get.docker.com | sudo sh
fi

log "Adding $(whoami) to the docker group (so docker/compose work without sudo)"
sudo usermod -aG docker "$(whoami)"

log "Enabling docker service"
sudo systemctl enable --now docker >/dev/null

log "Verifying Docker actually works inside this LXC container (nesting=1) with a real container run..."
if sudo docker run --rm hello-world 2>&1 | grep -q "Hello from Docker"; then
  log "Docker confirmed working."
else
  echo "Docker did not run a test container successfully — check 'docker run --rm hello-world' output and the container's nesting feature (pct config <vmid> | grep features)." >&2
  exit 1
fi

log "Docker Compose: $(sudo docker compose version)"
