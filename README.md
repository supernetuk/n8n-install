# n8n-install

One-command installer for self-hosted [n8n](https://n8n.io) on AlmaLinux / RHEL 9–10 with a public IP.

Installs **n8n + Postgres + Caddy** in Docker. Caddy gets and renews a Let's Encrypt HTTPS certificate automatically; n8n itself is never exposed directly.

## Before you run it

1. The VM needs a **public IPv4**.
2. Create a DNS **A record** for your domain pointing at that IP (Cloudflare: **DNS only / grey cloud**).
3. Ports **80** and **443** must be reachable.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/supernetuk/n8n-install/main/install-n8n.sh | sudo bash -s -- n8n.example.com you@example.com
```

Arguments: `<domain> <email for Let's Encrypt>`.

Takes about 3 minutes. When it finishes, open `https://<domain>` and **create the owner account straight away** — the first visitor becomes the owner. Then turn on 2FA (Settings → Personal).

## What it creates

| Path | Purpose |
|---|---|
| `/opt/n8n/.env` | Domain, Postgres password, **n8n encryption key** (mode 600) |
| `/opt/n8n/docker-compose.yml` | n8n, Postgres 16, Caddy 2 |
| `/opt/n8n/Caddyfile` | HTTPS reverse proxy to n8n |

Re-running the script is safe: an existing `.env` (and its secrets) is kept.

> **Back up `/opt/n8n/.env`.** Losing the encryption key makes every saved n8n credential unreadable.

## Day-to-day

```bash
cd /opt/n8n
docker compose ps                 # status
docker compose logs -f n8n        # n8n logs
docker compose logs caddy         # HTTPS / certificate problems
docker compose pull && docker compose up -d   # update (do this regularly)
```

Back up the database:

```bash
cd /opt/n8n && docker compose exec -T postgres pg_dump -U n8n n8n | gzip > n8n-$(date +%F).sql.gz
```

## Licence note

n8n is licensed under the [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/): free to self-host for your own business use, but not to resell n8n itself as a hosted service.
