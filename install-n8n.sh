#!/usr/bin/env bash
# One-command n8n installer for AlmaLinux / RHEL 9-10 with a public IP.
# Native install (no Docker): Node.js + n8n + PostgreSQL + Caddy (automatic
# Let's Encrypt HTTPS), each running as a systemd service.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/supernetuk/n8n-install/main/install-n8n.sh | sudo bash -s -- n8n.example.com you@example.com
#
# Before running: DNS A record for the domain must point at this VM's public IP
# (Cloudflare: grey cloud / DNS only), and ports 80 + 443 must be reachable.

set -euo pipefail

N8N_DOMAIN="${1:-}"
ACME_EMAIL="${2:-}"
ENV_DIR="/etc/n8n"
ENV_FILE="$ENV_DIR/n8n.env"
DATA_DIR="/var/lib/n8n"

if [[ -z "$N8N_DOMAIN" || -z "$ACME_EMAIL" ]]; then
  echo "Usage: $0 <domain> <email>   e.g. $0 n8n.supernet.uk you@supernet.uk" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

# sudo on RHEL drops /usr/local/bin from PATH; Node.js and Caddy live there.
export PATH="/usr/local/bin:$PATH"
NODE_LINE="24"   # n8n 2.x requires Node.js >= 24

# ---------------------------------------------------------------- packages
log "Installing base packages and PostgreSQL"
dnf -y install openssl curl bind-utils gcc-c++ make python3 tar xz \
  postgresql-server postgresql

# ---------------------------------------------------------------- swap
# n8n's native module builds are memory-hungry; add 2 GB swap on small VMs.
if [[ -z "$(swapon --show --noheadings)" ]]; then
  log "No swap found - creating a 2 GB swap file"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# ---------------------------------------------------------------- Node.js
# Distro Node.js is too old for current n8n, so install the official
# Node.js $NODE_LINE LTS build from nodejs.org into /usr/local.
CUR_MAJOR="$( [[ -x /usr/local/bin/node ]] && /usr/local/bin/node -p 'process.versions.node.split(".")[0]' || echo 0 )"
if (( CUR_MAJOR < NODE_LINE )); then
  log "Installing Node.js $NODE_LINE from nodejs.org"
  case "$(uname -m)" in x86_64) NARCH=x64;; aarch64) NARCH=arm64;; *) echo "Unsupported CPU $(uname -m)" >&2; exit 1;; esac
  NODE_DIST="https://nodejs.org/dist/latest-v${NODE_LINE}.x"
  TMP="$(mktemp -d)"
  curl -fsSL "$NODE_DIST/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"
  NODE_TAR="$(grep -oE "node-v[0-9.]+-linux-${NARCH}\.tar\.xz" "$TMP/SHASUMS256.txt" | head -n1)"
  curl -fsSL "$NODE_DIST/$NODE_TAR" -o "$TMP/$NODE_TAR"
  (cd "$TMP" && grep " $NODE_TAR\$" SHASUMS256.txt | sha256sum -c -)
  tar -xJf "$TMP/$NODE_TAR" -C /usr/local --strip-components=1 --no-same-owner
  rm -rf "$TMP"
  # Any n8n built against an older Node must be rebuilt.
  rm -rf /usr/local/lib/node_modules/n8n /usr/local/bin/n8n
fi
hash -r
echo "Node.js $(node -v), npm $(npm -v) at $(command -v node)"

# ---------------------------------------------------------------- firewall
log "Opening ports 80 and 443"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https
  firewall-cmd --reload
else
  echo "firewalld not running - skipping."
fi

# ---------------------------------------------------------------- DNS check
log "Checking DNS for $N8N_DOMAIN"
MY_IP="$(curl -4 -fsS https://api.ipify.org || true)"
DNS_IP="$(dig +short A "$N8N_DOMAIN" | tail -n1 || true)"
echo "This VM's public IP: ${MY_IP:-unknown}   DNS says: ${DNS_IP:-nothing}"
if [[ -n "$MY_IP" && "$MY_IP" != "$DNS_IP" ]]; then
  echo "WARNING: DNS does not point here yet. HTTPS certificate will fail until it does."
fi

# ---------------------------------------------------------------- secrets
log "Preparing configuration in $ENV_DIR"
mkdir -p "$ENV_DIR"
if [[ -f "$ENV_FILE" ]]; then
  echo "$ENV_FILE already exists - keeping existing secrets."
  # shellcheck disable=SC1090
  PG_PASS="$(grep '^DB_POSTGRESDB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
else
  PG_PASS="$(openssl rand -hex 24)"
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=127.0.0.1
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$PG_PASS
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
N8N_HOST=$N8N_DOMAIN
N8N_PROTOCOL=https
N8N_PORT=5678
N8N_LISTEN_ADDRESS=127.0.0.1
WEBHOOK_URL=https://$N8N_DOMAIN/
N8N_PROXY_HOPS=1
N8N_USER_FOLDER=$DATA_DIR
GENERIC_TIMEZONE=Europe/London
TZ=Europe/London
EOF
fi
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------- PostgreSQL
log "Setting up PostgreSQL"
if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
  postgresql-setup --initdb
fi
# Allow password (scram) logins from localhost instead of ident.
sed -E -i '/^host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)/ s/ident[[:space:]]*$/scram-sha-256/' \
  /var/lib/pgsql/data/pg_hba.conf
systemctl enable postgresql
systemctl restart postgresql

cd /tmp
# Password goes in via stdin, so it never shows up in `ps` output.
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q 1; then
  ROLE_SQL="ALTER ROLE n8n WITH LOGIN PASSWORD '$PG_PASS';"
else
  ROLE_SQL="CREATE ROLE n8n WITH LOGIN PASSWORD '$PG_PASS';"
fi
printf '%s\n' "$ROLE_SQL" | sudo -u postgres psql -q -v ON_ERROR_STOP=1
unset ROLE_SQL
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='n8n'" | grep -q 1; then
  sudo -u postgres createdb -O n8n n8n
fi

# ---------------------------------------------------------------- n8n
log "Installing n8n (this can take a few minutes)"
npm install -g n8n@latest --no-fund --no-audit --loglevel=error
N8N_BIN="/usr/local/bin/n8n"
[[ -x "$N8N_BIN" ]] || { echo "n8n install failed - see npm output above." >&2; exit 1; }
echo "n8n $("$N8N_BIN" --version) installed at $N8N_BIN"

id n8n >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --create-home --shell /sbin/nologin n8n
mkdir -p "$DATA_DIR"
chown -R n8n:n8n "$DATA_DIR"

cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n workflow automation
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=n8n
Group=n8n
WorkingDirectory=$DATA_DIR
Environment=HOME=$DATA_DIR
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$ENV_FILE
ExecStart=$N8N_BIN start
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- Caddy
log "Installing Caddy (HTTPS reverse proxy)"
if ! command -v caddy >/dev/null 2>&1; then
  ARCH="$(uname -m)"; case "$ARCH" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; esac
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$ARCH" -o /tmp/caddy.download
  # Normally a raw binary; unpack it if a tar.gz ever comes back instead.
  if [[ "$(head -c2 /tmp/caddy.download | od -An -tx1 | tr -d ' ')" == "1f8b" ]]; then
    tar -xzf /tmp/caddy.download -C /usr/local/bin caddy
  else
    mv /tmp/caddy.download /usr/local/bin/caddy
  fi
  rm -f /tmp/caddy.download
  chmod 755 /usr/local/bin/caddy
  command -v restorecon >/dev/null 2>&1 && restorecon -v /usr/local/bin/caddy || true
fi
echo "Caddy $(/usr/local/bin/caddy version | cut -d' ' -f1)"

id caddy >/dev/null 2>&1 || useradd --system --home-dir /var/lib/caddy --create-home --shell /sbin/nologin caddy
mkdir -p /etc/caddy /var/lib/caddy
chown -R caddy:caddy /var/lib/caddy

cat > /etc/caddy/Caddyfile <<EOF
{
  email $ACME_EMAIL
}
$N8N_DOMAIN {
  reverse_proxy 127.0.0.1:5678
}
EOF

cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy web server
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- start
log "Starting n8n and Caddy"
systemctl daemon-reload
systemctl enable n8n caddy
systemctl restart n8n
systemctl restart caddy

log "Waiting for n8n to come up"
code=""
for i in $(seq 1 36); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://$N8N_DOMAIN/healthz" || true)"
  [[ "$code" == "200" ]] && break
  sleep 5
done
systemctl --no-pager --lines=0 status postgresql n8n caddy || true

if [[ "$code" == "200" ]]; then
  log "Done! Open https://$N8N_DOMAIN and create your owner account NOW (first visitor becomes owner)."
else
  log "Services are installed but https://$N8N_DOMAIN is not answering yet (code: ${code:-none})."
  echo "Check:  journalctl -u n8n -n 50   and   journalctl -u caddy -n 50"
  echo "Usually DNS not pointing here yet, ports 80/443 blocked, or n8n still starting."
fi
echo
echo "IMPORTANT: back up $ENV_FILE - it holds the encryption key for all saved n8n credentials."
echo "Update later with: npm install -g n8n@latest && systemctl restart n8n"
