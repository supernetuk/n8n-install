#!/usr/bin/env bash
# One-command n8n installer for AlmaLinux / RHEL 9-10 with a public IP.
# n8n + Postgres + Caddy (automatic Let's Encrypt HTTPS), all in Docker.
#
# Usage:
#   curl -fsSL <raw-url>/install-n8n.sh | sudo bash -s -- n8n.example.com you@example.com
#
# Before running: DNS A record for the domain must point at this VM's public IP
# (Cloudflare: grey cloud / DNS only), and ports 80 + 443 must be reachable.

set -euo pipefail

N8N_DOMAIN="${1:-}"
ACME_EMAIL="${2:-}"
INSTALL_DIR="/opt/n8n"

if [[ -z "$N8N_DOMAIN" || -z "$ACME_EMAIL" ]]; then
  echo "Usage: $0 <domain> <email>   e.g. $0 n8n.supernet.uk you@supernet.uk" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

log "Installing Docker"
dnf -y install dnf-plugins-core openssl curl bind-utils
if ! command -v docker >/dev/null 2>&1; then
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker

log "Opening ports 80 and 443"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https
  firewall-cmd --reload
else
  echo "firewalld not running - skipping."
fi

log "Checking DNS for $N8N_DOMAIN"
MY_IP="$(curl -4 -fsS https://api.ipify.org || true)"
DNS_IP="$(dig +short A "$N8N_DOMAIN" | tail -n1 || true)"
echo "This VM's public IP: ${MY_IP:-unknown}   DNS says: ${DNS_IP:-nothing}"
if [[ -n "$MY_IP" && "$MY_IP" != "$DNS_IP" ]]; then
  echo "WARNING: DNS does not point here yet. HTTPS certificate will fail until it does."
fi

log "Writing config to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [[ ! -f .env ]]; then
  cat > .env <<EOF
N8N_DOMAIN=$N8N_DOMAIN
ACME_EMAIL=$ACME_EMAIL
POSTGRES_PASSWORD=$(openssl rand -hex 24)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
EOF
  chmod 600 .env
else
  echo ".env already exists - keeping existing secrets."
fi

cat > Caddyfile <<'EOF'
{
  email {$ACME_EMAIL}
}
{$N8N_DOMAIN} {
  reverse_proxy n8n:5678
}
EOF

cat > docker-compose.yml <<'EOF'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      N8N_DOMAIN: ${N8N_DOMAIN}
      ACME_EMAIL: ${ACME_EMAIL}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro,Z
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n

  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      retries: 10

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_PROXY_HOPS: 1
      GENERIC_TIMEZONE: Europe/London
      TZ: Europe/London
    volumes:
      - n8ndata:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  caddy_data:
  caddy_config:
  pgdata:
  n8ndata:
EOF

log "Starting n8n, Postgres and Caddy"
docker compose pull
docker compose up -d

log "Waiting for n8n to come up"
for i in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://$N8N_DOMAIN/healthz" || true)"
  if [[ "$code" == "200" ]]; then break; fi
  sleep 5
done
docker compose ps

if [[ "${code:-}" == "200" ]]; then
  log "Done! Open https://$N8N_DOMAIN and create your owner account NOW (first visitor becomes owner)."
else
  log "Containers are up but https://$N8N_DOMAIN is not answering yet (code: ${code:-none})."
  echo "Usually DNS not pointing here yet, or ports 80/443 blocked. Check: cd $INSTALL_DIR && docker compose logs caddy"
fi
echo
echo "IMPORTANT: back up $INSTALL_DIR/.env - it holds the encryption key for all saved n8n credentials."
echo "Update later with: cd $INSTALL_DIR && docker compose pull && docker compose up -d"
