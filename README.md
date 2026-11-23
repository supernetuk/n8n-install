# n8n-install

One-command installer for self-hosted [n8n](https://n8n.io) on AlmaLinux / RHEL 9–10 with a public IP.

**Native install — no Docker.** Everything runs directly on the VM as systemd services:

| Service | What it does |
|---|---|
| `n8n` | n8n (installed with npm on Node.js 24 from nodejs.org), listening on `127.0.0.1:5678` only |
| `postgresql` | n8n's database (local only) |
| `caddy` | Public HTTPS on ports 80/443 with automatic Let's Encrypt certificates, proxying to n8n |

## Before you run it

1. The VM needs a **public IPv4**.
2. Create a DNS **A record** for your domain pointing at that IP (Cloudflare: **DNS only / grey cloud**). No Cloudflare Tunnel is used.
3. Ports **80** and **443** must be reachable.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/supernetuk/n8n-install/main/install-n8n.sh | sudo bash -s -- n8n.example.com you@example.com
```

Arguments: `<domain> <email for Let's Encrypt>`.

Takes about 5 minutes. When it finishes, open `https://<domain>` and **create the owner account straight away** — the first visitor becomes the owner. Then turn on 2FA (Settings → Personal).

## What it creates

| Path | Purpose |
|---|---|
| `/etc/n8n/n8n.env` | n8n settings, Postgres password, **n8n encryption key** (mode 600) |
| `/var/lib/n8n` | n8n user folder |
| `/etc/caddy/Caddyfile` | HTTPS reverse proxy config |
| `/etc/systemd/system/n8n.service`, `caddy.service` | Service units |

Re-running the script is safe: an existing `/etc/n8n/n8n.env` (and its secrets) is kept.

> **Back up `/etc/n8n/n8n.env`.** Losing the encryption key makes every saved n8n credential unreadable.

## Day-to-day

```bash
systemctl status n8n caddy postgresql   # status
journalctl -u n8n -f                    # n8n logs
journalctl -u caddy -n 50               # HTTPS / certificate problems
npm install -g n8n@latest && systemctl restart n8n   # update n8n (do this regularly)
```

Back up the database:

```bash
sudo -u postgres pg_dump n8n | gzip > n8n-$(date +%F).sql.gz
```

## Licence note

n8n is licensed under the [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/): free to self-host for your own business use, but not to resell n8n itself as a hosted service.
