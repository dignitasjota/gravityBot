# Deploying behind Portainer + Nginx Proxy Manager

This guide covers self-hosting GRVT Grid on a VPS that already runs
**Portainer** and **Nginx Proxy Manager (NPM)**. The upstream stack
uses Caddy; this guide ignores Caddy entirely and routes TLS through
NPM instead.

## Target architecture

```
Internet --[443]--> Nginx Proxy Manager --(shared docker network)--> bot:3848
                                                                      \-> notifier (optional)
```

NPM terminates TLS and issues the Let's Encrypt cert. The bot container
is never exposed on a host port — only NPM can reach it, over the
shared docker network.

## 1. Prerequisites

On the VPS:
- Docker + docker compose plugin
- Portainer (any recent version)
- Nginx Proxy Manager already running in docker
- A domain or subdomain whose A record points at the VPS IP
  (example: `grvt.example.com`)

Find the name of the docker network NPM is attached to:

```bash
docker network ls
docker inspect <npm-container-name> | grep -A2 Networks
```

Typical names: `npm-network`, `npm_default`, `proxy`. Note the exact
string — you will pass it as `NPM_NETWORK` to the compose stack.

## 2. Clone the repo

```bash
sudo mkdir -p /opt/grvt-grid
sudo chown $USER:$USER /opt/grvt-grid
cd /opt/grvt-grid
git clone https://github.com/dignitasjota/gravityBot.git .
```

The deploy assumes the project lives at `/opt/grvt-grid`. The compose
overlay (`docker-compose.npm.yml`) hard-codes that path in its bind
mounts. If you put the repo somewhere else, edit those paths.

## 3. Generate the master key

The master key encrypts every user's GRVT API credentials in SQLite.
Lose this file and the database becomes unreadable — back it up offline.

```bash
mkdir -p secrets data logs/bot logs/notifier
head -c 32 /dev/urandom > secrets/master.key
chmod 600 secrets/master.key
sudo chown -R 10000:10000 secrets data logs
```

The container runs as UID 10000 (non-root `grvtbot` user). The bind
mounts must be owned by that UID or the bot fails to start with
`EACCES`.

## 4. Create `.env`

```bash
cp packages/bot/.env.example .env
nano .env
```

Required values:

```env
# GRVT API credentials (from your GRVT account UI)
GRVT_API_KEY=...
GRVT_API_SECRET=0x...
GRVT_TRADING_ACCOUNT_ID=...
GRVT_TRADING_ADDRESS=0x...

# Master key location inside the container
MASTER_KEY_PATH=/run/secrets/master.key

# Secrets (generate with the commands below)
JWT_SECRET=
DASHBOARD_API_KEY=

# Owner bootstrap — remove OWNER_INITIAL_PASSWORD after first login
OWNER_EMAIL=you@example.com
OWNER_INITIAL_PASSWORD=ChangeMeOnFirstLogin
ADMIN_EMAIL=you@example.com

# Public URL served by NPM
APP_BASE_URL=https://grvt.example.com

NODE_ENV=production
LOG_LEVEL=info
MOCK_MODE=false
DRY_RUN=false
```

Generate the secrets:

```bash
echo "JWT_SECRET=$(head -c 48 /dev/urandom | base64)"
echo "DASHBOARD_API_KEY=$(head -c 32 /dev/urandom | base64)"
```

`GRVT_TRADING_ACCOUNT_ID` is **mandatory**. The dashboard server
throws on startup if it is missing. There is no fallback to the
upstream author's sub-account.

## 5. Configure the NPM network

If your NPM network is not named `npm-network`, export it once:

```bash
echo "NPM_NETWORK=npm_default" >> .env   # adjust to your real name
```

The overlay reads `${NPM_NETWORK:-npm-network}` for the external
network declaration.

## 6. First build and start

```bash
cd /opt/grvt-grid
docker compose -f docker-compose.yml -f docker-compose.npm.yml build
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d
docker compose -f docker-compose.yml -f docker-compose.npm.yml logs -f bot
```

Healthy startup looks like:

```
Inicializando servicios...
Owner user created: you@example.com (id=1)
REMOVE OWNER_INITIAL_PASSWORD from .env after first boot
Grid Engine iniciado automáticamente
Server: http://localhost:3848
```

Confirm the container is `(healthy)`:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml ps
```

## 7. Configure Nginx Proxy Manager

NPM UI → **Hosts → Proxy Hosts → Add Proxy Host**.

**Details tab**
- Domain Names: `grvt.example.com`
- Scheme: `http`
- Forward Hostname / IP: `grvt-grid-bot`
  (the `container_name` defined in the base compose)
- Forward Port: `3848`
- Enable: *Cache Assets*, *Block Common Exploits*, *Websockets Support*

The Websockets toggle is essential. The dashboard receives all
real-time updates (fills, equity curve, alerts) over WebSocket. Without
it the UI loads but never refreshes.

**SSL tab**
- SSL Certificate: *Request a new SSL Certificate* (Let's Encrypt)
- Force SSL, HTTP/2, HSTS Enabled

Save. Visit `https://grvt.example.com/dashboard/` and log in with
`OWNER_EMAIL` + `OWNER_INITIAL_PASSWORD`.

## 8. Lock down after first login

1. Change your password in the UI.
2. Remove `OWNER_INITIAL_PASSWORD` from `.env`.
3. Recreate the container:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d --force-recreate bot
```

The owner-bootstrap routine is idempotent: it skips silently when a
user already exists, so the password env is only ever read on the very
first start.

## 9. Optional — Telegram alerts

To enable the notifier sidecar, add to `.env`:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

Start the full profile:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml \
  --profile full up -d
```

The notifier reads the bot's SQLite database read-only and pushes
batched fill, drawdown, and liquidation-proximity alerts.

## 10. Using Portainer instead of the CLI

Two paths:

**A. Stack from Git (recommended for auto-update on push)**

1. Stacks → Add stack → Build method: *Repository*.
2. Repository URL: `https://github.com/dignitasjota/gravityBot`.
3. Reference: `refs/heads/main`.
4. Compose path: `docker-compose.yml`.
5. Additional paths: `docker-compose.npm.yml`.
6. Environment variables: paste the contents of `.env`, plus
   `NPM_NETWORK=<your network>`.
7. Deploy.

Portainer keeps the bind mounts working because the overlay uses
absolute paths (`/opt/grvt-grid/...`) instead of relative ones.

**B. External stack**

Deploy from the CLI as in step 6, then in Portainer the stack appears
under *Stacks → External*. You can use the UI for logs, restart, and
recreate without giving Portainer ownership of the lifecycle.

## 11. Backups

Two artefacts are critical:

- **`/opt/grvt-grid/secrets/master.key`** — back this up offline
  (encrypted USB, password manager). The database is useless without
  it.
- **`/opt/grvt-grid/data/grid_bot.db`** — use the SQLite-safe backup
  script in `scripts/backup.sh`. Schedule it via cron:

```cron
0 3 * * * /opt/grvt-grid/scripts/backup.sh >> /var/log/grvt-backup.log 2>&1
```

## 12. Upgrading

```bash
cd /opt/grvt-grid
git pull
docker compose -f docker-compose.yml -f docker-compose.npm.yml build --pull
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d
```

SIGTERM is forwarded by tini to the node process; the bot cancels its
monitoring loop gracefully and leaves all open GRVT orders untouched
during the restart.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Master key file not found at /etc/grvt-grid/master.key` | `MASTER_KEY_PATH` env not set, or bind mount missing |
| `EACCES` on `/app/data` at startup | `data/` not owned by uid 10000 |
| `GRVT_TRADING_ACCOUNT_ID env var is required` | Missing env value; this fork removed the upstream fallback |
| Dashboard loads but never updates | NPM proxy host missing the Websockets toggle |
| Password reset link points at `http://localhost` | `APP_BASE_URL` not set |
| NPM cannot reach `grvt-grid-bot` | Bot not on NPM network — check `NPM_NETWORK` matches `docker network ls` |
| Container restarts on healthcheck | Check `docker logs grvt-grid-bot` — usually a missing env var or auth error against GRVT |
