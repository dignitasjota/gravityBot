# Despliegue detrás de Portainer + Nginx Proxy Manager

Esta guía cubre cómo auto-alojar GRVT Grid en un VPS que ya ejecuta
**Portainer** y **Nginx Proxy Manager (NPM)**. El stack upstream usa
Caddy; esta guía ignora Caddy por completo y enruta el TLS a través
de NPM.

## Arquitectura objetivo

```
Internet --[443]--> Nginx Proxy Manager --(red docker compartida)--> bot:3848
                                                                      \-> notifier (opcional)
```

NPM termina el TLS y emite el certificado Let's Encrypt. El contenedor
del bot nunca se expone en un puerto del host — sólo NPM puede
alcanzarlo, a través de la red docker compartida.

## 1. Prerequisitos

En el VPS:
- Docker + plugin docker compose
- Portainer (cualquier versión reciente)
- Nginx Proxy Manager ya corriendo en docker
- Un dominio o subdominio cuyo registro A apunte a la IP del VPS
  (ejemplo: `grvt.example.com`)

Averigua el nombre de la red docker a la que está conectado NPM:

```bash
docker network ls
docker inspect <nombre-contenedor-npm> | grep -A2 Networks
```

Nombres típicos: `npm-network`, `npm_default`, `proxy`. Anota la
cadena exacta — la pasarás como `NPM_NETWORK` al stack de compose.

## 2. Clonar el repo

```bash
sudo mkdir -p /opt/grvt-grid
sudo chown $USER:$USER /opt/grvt-grid
cd /opt/grvt-grid
git clone https://github.com/dignitasjota/gravityBot.git .
```

El despliegue asume que el proyecto vive en `/opt/grvt-grid`. El
overlay de compose (`docker-compose.npm.yml`) tiene esa ruta
hardcodeada en sus bind mounts. Si pones el repo en otro sitio,
edita esas rutas.

## 3. Generar la master key

La master key cifra las credenciales API de GRVT de cada usuario en
SQLite. Si pierdes este archivo, la base de datos queda ilegible —
haz copia de seguridad offline.

```bash
mkdir -p secrets data logs/bot logs/notifier
head -c 32 /dev/urandom > secrets/master.key
chmod 600 secrets/master.key
sudo chown -R 10000:10000 secrets data logs
```

El contenedor corre como UID 10000 (usuario no-root `grvtbot`). Los
bind mounts deben ser propiedad de ese UID o el bot falla al arrancar
con `EACCES`.

## 4. Crear el `.env`

```bash
cp packages/bot/.env.example .env
nano .env
```

Valores obligatorios:

```env
# Credenciales GRVT API (desde la UI de tu cuenta GRVT)
GRVT_API_KEY=...
GRVT_API_SECRET=0x...
GRVT_TRADING_ACCOUNT_ID=...
GRVT_TRADING_ADDRESS=0x...

# Ubicación de la master key dentro del contenedor
MASTER_KEY_PATH=/run/secrets/master.key

# Secretos (genéralos con los comandos de abajo)
JWT_SECRET=
DASHBOARD_API_KEY=

# Bootstrap del owner — borra OWNER_INITIAL_PASSWORD tras el primer login
OWNER_EMAIL=tu@example.com
OWNER_INITIAL_PASSWORD=CambiameEnPrimerLogin
ADMIN_EMAIL=tu@example.com

# URL pública servida por NPM
APP_BASE_URL=https://grvt.example.com

NODE_ENV=production
LOG_LEVEL=info
MOCK_MODE=false
DRY_RUN=false
```

Genera los secretos:

```bash
echo "JWT_SECRET=$(head -c 48 /dev/urandom | base64)"
echo "DASHBOARD_API_KEY=$(head -c 32 /dev/urandom | base64)"
```

`GRVT_TRADING_ACCOUNT_ID` es **obligatorio**. El servidor del
dashboard lanza una excepción al arrancar si falta. No existe
fallback a la sub-account del autor upstream.

## 5. Configurar la red de NPM

Si tu red NPM no se llama `npm-network`, exporta el nombre real:

```bash
echo "NPM_NETWORK=npm_default" >> .env   # ajusta al nombre real
```

El overlay lee `${NPM_NETWORK:-npm-network}` para la declaración de
la red externa.

## 6. Primer build y arranque

```bash
cd /opt/grvt-grid
docker compose -f docker-compose.yml -f docker-compose.npm.yml build
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d
docker compose -f docker-compose.yml -f docker-compose.npm.yml logs -f bot
```

Un arranque correcto se ve así:

```
Inicializando servicios...
Owner user created: tu@example.com (id=1)
REMOVE OWNER_INITIAL_PASSWORD from .env after first boot
Grid Engine iniciado automáticamente
Server: http://localhost:3848
```

Confirma que el contenedor está `(healthy)`:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml ps
```

## 7. Configurar Nginx Proxy Manager

UI de NPM → **Hosts → Proxy Hosts → Add Proxy Host**.

**Pestaña Details**
- Domain Names: `grvt.example.com`
- Scheme: `http`
- Forward Hostname / IP: `grvt-grid-bot`
  (el `container_name` definido en el compose base)
- Forward Port: `3848`
- Activa: *Cache Assets*, *Block Common Exploits*, *Websockets Support*

El toggle de Websockets es **imprescindible**. El dashboard recibe
todas las actualizaciones en tiempo real (fills, equity curve,
alertas) por WebSocket. Sin él la UI carga pero nunca se refresca.

**Pestaña SSL**
- SSL Certificate: *Request a new SSL Certificate* (Let's Encrypt)
- Force SSL, HTTP/2, HSTS Enabled

Guarda. Visita `https://grvt.example.com/dashboard/` y entra con
`OWNER_EMAIL` + `OWNER_INITIAL_PASSWORD`.

## 8. Asegurar tras el primer login

1. Cambia tu contraseña en la UI.
2. Borra `OWNER_INITIAL_PASSWORD` de `.env`.
3. Recrea el contenedor:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d --force-recreate bot
```

La rutina de bootstrap del owner es idempotente: hace skip silencioso
si ya existe algún usuario, así que la env del password sólo se lee
en el primer arranque.

## 9. Opcional — Alertas Telegram

Para habilitar el sidecar del notifier, añade al `.env`:

```env
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

Arranca con el perfil `full`:

```bash
docker compose -f docker-compose.yml -f docker-compose.npm.yml \
  --profile full up -d
```

El notifier lee la SQLite del bot en read-only y empuja alertas
batched de fills, drawdown y proximidad a liquidación.

## 10. Usar Portainer en vez de la CLI

Dos caminos:

**A. Stack desde Git (recomendado para auto-update en cada push)**

1. Stacks → Add stack → Build method: *Repository*.
2. Repository URL: `https://github.com/dignitasjota/gravityBot`.
3. Reference: `refs/heads/main`.
4. Compose path: `docker-compose.yml`.
5. Additional paths: `docker-compose.npm.yml`.
6. Environment variables: pega el contenido de `.env`, más
   `NPM_NETWORK=<tu red>`.
7. Deploy.

Portainer mantiene los bind mounts funcionando porque el overlay usa
rutas absolutas (`/opt/grvt-grid/...`) en vez de relativas.

**B. Stack externo**

Despliega desde la CLI como en el paso 6, y en Portainer el stack
aparecerá bajo *Stacks → External*. Puedes usar la UI para ver logs,
reiniciar y recrear sin ceder a Portainer el control del ciclo de
vida.

## 11. Backups

Dos artefactos son críticos:

- **`/opt/grvt-grid/secrets/master.key`** — copia de seguridad
  offline (USB cifrado, gestor de contraseñas). La base de datos es
  inservible sin él.
- **`/opt/grvt-grid/data/grid_bot.db`** — usa el script SQLite-safe
  en `scripts/backup.sh`. Prográmalo con cron:

```cron
0 3 * * * /opt/grvt-grid/scripts/backup.sh >> /var/log/grvt-backup.log 2>&1
```

## 12. Actualizar a una nueva versión

```bash
cd /opt/grvt-grid
git pull
docker compose -f docker-compose.yml -f docker-compose.npm.yml build --pull
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d
```

tini reenvía SIGTERM al proceso node; el bot cancela su loop de
monitorización de forma graceful y deja intactas todas las órdenes
abiertas en GRVT durante el reinicio.

## Troubleshooting

| Síntoma | Causa probable |
|---|---|
| `Master key file not found at /etc/grvt-grid/master.key` | Falta la env `MASTER_KEY_PATH` o el bind mount |
| `EACCES` sobre `/app/data` al arrancar | El directorio `data/` no pertenece al uid 10000 |
| `GRVT_TRADING_ACCOUNT_ID env var is required` | Falta el valor; este fork eliminó el fallback upstream |
| El dashboard carga pero no se refresca | Falta el toggle Websockets en el proxy host de NPM |
| El enlace de password reset apunta a `http://localhost` | `APP_BASE_URL` no está configurado |
| NPM no puede alcanzar `grvt-grid-bot` | El bot no está en la red de NPM — revisa que `NPM_NETWORK` coincida con `docker network ls` |
| El contenedor se reinicia por el healthcheck | Mira `docker logs grvt-grid-bot` — habitualmente falta una env o falla la auth contra GRVT |
