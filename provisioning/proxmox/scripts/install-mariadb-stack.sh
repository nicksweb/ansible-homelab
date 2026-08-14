#!/usr/bin/env bash
# Runs ON THE REMOTE CONTAINER via ssh+sudo, orchestrated by
# bin/deploy-mariadb-stack.sh. Deploys a Docker Compose stack — MariaDB +
# phpMyAdmin + Traefik — and a native (non-Docker) nginx in front of it for
# TLS termination on the container's own trusted cert. Idempotent: safe to
# re-run; preserves existing DB credentials rather than rotating them.
#
# Architecture (all on this one container):
#   LAN client --HTTPS(trusted cert)--> nginx :443 --http--> Traefik :8080 (127.0.0.1 only)
#                                                                  |
#                                                             phpMyAdmin (Docker network)
#                                                                  |
#                                                              MariaDB (Docker network)
#
#   Any host on 172.16.0.0/16 --3306/tcp--> MariaDB directly (not via nginx/Traefik —
#     MySQL wire protocol isn't HTTP, so it's a straight Docker-published port,
#     restricted at the firewall — see below)
#
# MariaDB's published port 3306 is NOT filtered by ufw, even though ufw is
# enabled on this container: Docker manipulates iptables directly and
# inserts its own ACCEPT rules for published ports into the FORWARD chain
# ahead of where ufw's own forward-filtering rules take effect, so ufw rules
# are simply never consulted for Docker-forwarded traffic — a well-known,
# frequently-surprising Docker+ufw interaction, not a bug in either tool.
# The actual, Docker-documented mechanism for this is the DOCKER-USER chain,
# which Docker creates specifically so operators can insert rules that DO
# get evaluated before Docker's own permissive ones. That's what
# mariadb-fw-rules.sh + its systemd unit below do: accept 172.16.0.0/16 on
# 3306, drop everything else, applied fresh on every boot (after
# docker.service, since the DOCKER-USER chain doesn't exist until dockerd
# creates it) so a reboot can never silently revert to "open to everyone".
#
# Usage: install-mariadb-stack.sh <fqdn>
set -euo pipefail

FQDN="${1:?usage: install-mariadb-stack.sh <fqdn>}"
STACK_DIR="$HOME/docker/mariadb-stack"
ALLOWED_CIDR="172.16.0.0/16"
DB_PORT=3306

log() { echo "[mariadb-stack] $*"; }

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Credentials + config — .env is read back if it already exists so re-runs
# never rotate passwords out from under an app that's already using them.
# ---------------------------------------------------------------------------
mkdir -p "$STACK_DIR/data/mariadb"
cd "$STACK_DIR"

if [ -f .env ]; then
  log "Existing .env found — preserving current DB credentials (delete .env manually first to rotate them)"
  # shellcheck disable=SC1091
  source .env
fi
gen_secret() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9'; }
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_secret)}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_secret)}"
MYSQL_DATABASE="${MYSQL_DATABASE:-appdb}"
MYSQL_USER="${MYSQL_USER:-appuser}"

cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
PMA_ABSOLUTE_URI=https://$FQDN/
EOF
chmod 600 .env
unset MYSQL_ROOT_PASSWORD MYSQL_PASSWORD  # don't linger in this script's env longer than needed

log "Writing docker-compose.yml"
cat > docker-compose.yml <<EOF
services:
  mariadb:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - ./data/mariadb:/var/lib/mysql
    ports:
      - "${DB_PORT}:${DB_PORT}"
    networks:
      - backend
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12

  phpmyadmin:
    image: phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_HOST: mariadb
      PMA_ABSOLUTE_URI: \${PMA_ABSOLUTE_URI}
      UPLOAD_LIMIT: 64M
    networks:
      - backend
    depends_on:
      mariadb:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.phpmyadmin.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.phpmyadmin.entrypoints=web"
      - "traefik.http.services.phpmyadmin.loadbalancer.server.port=80"

  traefik:
    # Pinned to a version confirmed (via traefik/traefik#12256 and Traefik's
    # own changelog) to auto-negotiate the Docker API version rather than
    # hardcoding an old one. Confirmed via direct testing that this is a
    # real, documented breaking change, not something specific to this
    # setup: Docker Engine 29.x (installed via get.docker.com) raised its
    # minimum supported API version to 1.44 and rejects anything older;
    # every Traefik release before v3.6.1 hardcodes a stale 1.24 in its
    # Docker provider client and fails every single request with "client
    # version 1.24 is too old" — which silently means it discovers zero
    # containers, so phpMyAdmin's labels are never picked up and every
    # request 404s. Tried the documented pre-3.6.1 workaround first
    # (DOCKER_API_VERSION env var) — did not resolve it on v3.1, so
    # upgrading is the actual fix here, not a workaround.
    image: traefik:v3.6.1
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:8080"
    ports:
      # Bound to loopback only — reachable from nginx on this same host,
      # never directly from the LAN. nginx is the one and only entry point.
      - "127.0.0.1:8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - backend

networks:
  backend:
    driver: bridge
EOF

# ---------------------------------------------------------------------------
# Firewall: restrict 3306 to $ALLOWED_CIDR via DOCKER-USER (see header note)
# ---------------------------------------------------------------------------
log "Installing MariaDB firewall rules (3306 restricted to $ALLOWED_CIDR)"
sudo tee /usr/local/sbin/mariadb-fw-rules.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
# net.bridge.bridge-nf-call-iptables=1 (Docker's default) means
# container-to-container traffic on the SAME Docker network ALSO traverses
# the iptables FORWARD chain, including DOCKER-USER — not just externally
# -sourced traffic to the published port. Confirmed the hard way: without
# also allowing the compose stack's own bridge subnet here, phpMyAdmin's
# own connection to MariaDB was silently dropped by the exact rule meant to
# keep OTHER hosts out, since phpMyAdmin's container IP isn't in
# ${ALLOWED_CIDR} — logins hung forever (DROP rule's packet counter
# incremented in lockstep with each retry, phpMyAdmin's own fsockopen
# reported "Connection timed out").
DOCKER_SUBNET=""
for i in \$(seq 1 10); do
  DOCKER_SUBNET="\$(docker network inspect mariadb-stack_backend --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  [ -n "\$DOCKER_SUBNET" ] && break
  sleep 2
done

iptables -C DOCKER-USER -p tcp --dport ${DB_PORT} -s ${ALLOWED_CIDR} -j ACCEPT 2>/dev/null || \\
  iptables -I DOCKER-USER 1 -p tcp --dport ${DB_PORT} -s ${ALLOWED_CIDR} -j ACCEPT

if [ -n "\$DOCKER_SUBNET" ]; then
  iptables -C DOCKER-USER -p tcp --dport ${DB_PORT} -s "\$DOCKER_SUBNET" -j ACCEPT 2>/dev/null || \\
    iptables -I DOCKER-USER 1 -p tcp --dport ${DB_PORT} -s "\$DOCKER_SUBNET" -j ACCEPT
fi

iptables -C DOCKER-USER -p tcp --dport ${DB_PORT} -j DROP 2>/dev/null || \\
  iptables -A DOCKER-USER -p tcp --dport ${DB_PORT} -j DROP
EOF
sudo chmod 755 /usr/local/sbin/mariadb-fw-rules.sh

sudo tee /etc/systemd/system/mariadb-fw-rules.service >/dev/null <<'EOF'
[Unit]
Description=Restrict MariaDB's Docker-published port to the internal LAN (DOCKER-USER chain)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mariadb-fw-rules.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable mariadb-fw-rules.service >/dev/null

# ---------------------------------------------------------------------------
# nginx — native, not Docker: TLS termination on the trusted cert already
# issued for $FQDN, reverse-proxying to Traefik on 127.0.0.1:8080.
# ---------------------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
  log "Installing nginx"
  sudo apt-get update -qq
  sudo apt-get install -y -qq nginx >/dev/null
fi

log "Opening ufw for HTTP/HTTPS (nginx runs natively on the host, so ufw does apply here — unlike Docker's published ports above)"
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null

CERT_DIR="/etc/letsencrypt/live/${FQDN}"
sudo test -f "${CERT_DIR}/fullchain.pem" || { echo "No certificate found at ${CERT_DIR} — run provision-container.sh with --enable-tls first" >&2; exit 1; }

sudo tee /etc/nginx/sites-available/mariadb-stack.conf >/dev/null <<EOF
server {
    listen 80;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${FQDN};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/mariadb-stack.conf /etc/nginx/sites-enabled/mariadb-stack.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx >/dev/null
sudo systemctl reload nginx

# ---------------------------------------------------------------------------
# Bring the stack up
# ---------------------------------------------------------------------------
log "Applying firewall rules now (not just at next boot)"
sudo /usr/local/sbin/mariadb-fw-rules.sh

log "Starting the Docker Compose stack..."
sudo docker compose up -d

log "Waiting for MariaDB to report healthy..."
HEALTHY=false
for i in $(seq 1 30); do
  STATUS="$(sudo docker inspect --format '{{.State.Health.Status}}' mariadb-stack-mariadb-1 2>/dev/null || echo unknown)"
  [ "$STATUS" = "healthy" ] && { HEALTHY=true; break; }
  sleep 5
done
$HEALTHY && log "MariaDB healthy." || echo "MariaDB did not report healthy within 150s — check 'docker compose logs mariadb'" >&2

log "Stack status:"
sudo docker compose ps
