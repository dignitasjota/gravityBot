# Despliegue con Portainer + Nginx Proxy Manager

Guía para auto-alojar GRVT Grid en un VPS que ya ejecuta **Portainer**
y **Nginx Proxy Manager (NPM)**. El stack upstream usa Caddy; esta
guía lo ignora por completo y enruta el TLS a través de NPM.

## Arquitectura

```
Internet --[443]--> Nginx Proxy Manager --(red docker compartida)--> bot:3848
                                                                      \-> notifier (opcional)
```

NPM termina el TLS y emite el certificado Let's Encrypt. El
contenedor del bot nunca se expone en un puerto del host — sólo NPM
puede alcanzarlo, a través de una red docker compartida.

## 1. Prerequisitos

En el VPS:
- Docker + plugin docker compose
- Portainer (versión reciente, idealmente 2.20+)
- Nginx Proxy Manager corriendo en docker
- Un (sub)dominio cuyo registro A apunte a la IP del VPS

Averigua el nombre exacto de la red docker a la que está conectado
NPM — la pasarás como `NPM_NETWORK` al stack:

```bash
docker ps --format '{{.Names}}' | grep -iE 'proxy|npm|nginx'
docker inspect <nombre-contenedor-npm> \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
```

Nombres típicos: `npm-net`, `npm-network`, `npm_default`, `proxy`.

## 2. Preparar el directorio de datos en el host

El bot escribe la base de datos SQLite, los logs y necesita la master
key. Estos artefactos viven en el **host**, no en el repo ni en el
contenedor. Por defecto el compose busca todo bajo `/opt/grvt-grid/`;
si quieres ponerlo en otra ruta (p.ej. `/opt/webs/gravity-bot/`),
define luego la variable `GRVT_DATA_DIR` en el stack.

Sustituye `$DATA_DIR` por tu ruta:

```bash
export DATA_DIR=/opt/webs/gravity-bot     # o la que prefieras

sudo mkdir -p $DATA_DIR/{data,logs/bot,logs/notifier,secrets}

# Master key: 32 bytes aleatorios, sólo legible por el dueño
sudo sh -c "head -c 32 /dev/urandom > $DATA_DIR/secrets/master.key"
sudo chmod 600 $DATA_DIR/secrets/master.key

# Propietario UID 10000 (el usuario 'grvtbot' dentro del contenedor)
sudo chown -R 10000:10000 $DATA_DIR/{data,logs,secrets}

# Verifica
ls -lan $DATA_DIR/
```

Esperado: las tres líneas con propietario `10000 10000`.

**Backup inmediato de la master key** — sin ella la BD queda
inservible. Cópiala a un sitio externo offline (USB cifrado, gestor
de contraseñas):

```bash
sudo base64 < $DATA_DIR/secrets/master.key
```

## 3. Generar los secretos JWT y DASHBOARD_API_KEY

Necesitas dos cadenas aleatorias largas. Las generarás ahora y las
pegarás en Portainer en el paso siguiente:

```bash
echo "JWT_SECRET=$(head -c 48 /dev/urandom | base64)"
echo "DASHBOARD_API_KEY=$(head -c 32 /dev/urandom | base64)"
```

## 4. Desplegar el stack desde Portainer

Portainer → *Stacks* → *Add stack* → *Build method*: **Repository**.

| Campo | Valor |
|---|---|
| Repository URL | `https://github.com/dignitasjota/gravityBot` |
| Repository reference | `refs/heads/main` |
| Compose path | `docker-compose.portainer.yml` |
| Additional paths | *(vacío)* |

En **Environment variables** añade cada par como una fila separada
(no pegues un `.env` entero como una sola variable):

### Variables obligatorias

| Variable | Valor | Origen |
|---|---|---|
| `GRVT_API_KEY` | tu API key | UI de GRVT → API Keys |
| `GRVT_API_SECRET` | `0x...` | UI de GRVT → API Keys (clave privada) |
| `GRVT_TRADING_ACCOUNT_ID` | número largo | UI de GRVT → Sub-account |
| `GRVT_TRADING_ADDRESS` | `0x...` | UI de GRVT → trading address |
| `JWT_SECRET` | la generada en el paso 3 | local |
| `DASHBOARD_API_KEY` | la generada en el paso 3 | local |
| `OWNER_EMAIL` | tu email (será admin) | local |
| `OWNER_INITIAL_PASSWORD` | password inicial | local — la borras tras el primer login |
| `ADMIN_EMAIL` | el mismo de `OWNER_EMAIL` | local |
| `APP_BASE_URL` | `https://grvt.tudominio.com` | tu dominio |
| `MASTER_KEY_PATH` | `/run/secrets/master.key` | ruta **dentro** del contenedor — no la cambies |

### Variables que dependen de tu entorno

| Variable | Cuándo establecerla | Valor por defecto |
|---|---|---|
| `NPM_NETWORK` | siempre que tu red NPM no se llame `npm-network` | `npm-network` |
| `GRVT_DATA_DIR` | siempre que `$DATA_DIR` del paso 2 no sea `/opt/grvt-grid` | `/opt/grvt-grid` |
| `LOG_LEVEL` | si quieres `debug` o `warn` | `info` |
| `MOCK_MODE` | a `true` para probar la UI sin credenciales reales | `false` |

### Variables opcionales

| Variable | Para qué |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | alertas del notifier |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` | reset de password por email |
| `METRICS_TOKEN` | abrir `/api/v2/metrics` a un scraper Prometheus externo |
| `ENABLE_CSP` | `1` para activar Content-Security-Policy estricto |

Marca **Deploy the stack** y espera a que Portainer haga `git clone`
+ `docker compose build` + `up -d`. El primer build tarda 2-5 min
porque compila `sqlite3` y `better-sqlite3` desde fuente.

## 5. Configurar el Proxy Host en NPM

UI de NPM → **Hosts → Proxy Hosts → Add Proxy Host**.

**Pestaña Details**

| Campo | Valor |
|---|---|
| Domain Names | `grvt.tudominio.com` |
| Scheme | `http` |
| Forward Hostname / IP | `grvt-grid-bot` (el `container_name` exacto) |
| Forward Port | `3848` |
| Cache Assets | activado |
| Block Common Exploits | activado |
| **Websockets Support** | **activado** — sin esto la UI carga pero nunca se refresca |

**Pestaña SSL**
- SSL Certificate → *Request a new SSL Certificate* (Let's Encrypt)
- Force SSL + HTTP/2 + HSTS Enabled

Guarda. Abre `https://grvt.tudominio.com/dashboard/` y entra con
`OWNER_EMAIL` + `OWNER_INITIAL_PASSWORD`.

## 6. Asegurar tras el primer login

1. Cambia tu contraseña desde la UI (menú de usuario → Settings).
2. Portainer → stack → *Editor* → **borra la fila
   `OWNER_INITIAL_PASSWORD`** de Environment variables.
3. *Update the stack* (recreará el contenedor; no hace falta rebuild).
4. Verifica en `docker logs grvt-grid-bot --tail 20` que el warning
   `REMOVE OWNER_INITIAL_PASSWORD...` ya no aparece.

El bootstrap del owner es idempotente: hace skip silencioso cuando
ya existe algún usuario, así que la env del password sólo se lee en
el primer arranque.

## 7. Actualizar a una nueva versión

Cada vez que hagas `git push` a `main`:

Portainer → stack → *Update the stack*. **Importante** marcar:

- ✅ *Re-build image* (Portainer reconstruirá la imagen tras `git pull`)
- ❌ NO *Re-pull image* (la imagen es local — un pull intentaría
  buscarla en un registry y fallará con `pull access denied`)
- ✅ *Prune services* (opcional)

Tras el update, verifica que el bot sigue conectado a la red de NPM
(Portainer a veces lo desengancha al recrear):

```bash
docker inspect grvt-grid-bot \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'
```

Debe aparecer la red NPM. Si no, reengánchalo sin recrear:

```bash
docker network connect <NPM_NETWORK> grvt-grid-bot
```

Los datos persisten porque viven en bind-mounts al host (`$DATA_DIR`),
no en el filesystem del contenedor. tini reenvía SIGTERM al proceso
node, que cancela su loop de monitorización de forma graceful y deja
intactas las órdenes abiertas en GRVT durante el reinicio.

## 8. Opcional — Auto-update desde GitHub

Portainer → stack → *Editor* → sección *GitOps updates*:

- *Automatic updates*: ON
- *Polling* (cada N minutos) o *Webhook* (URL que GitHub llama al
  hacer push)
- *Re-build image*: ON

Con esto cada `git push origin main` despliega solo. Sólo úsalo si
tienes buenos backups y confías en tus tests; un push roto se
despliega automáticamente.

## 9. Opcional — Alertas Telegram

Activa el sidecar `notifier`. En las env del stack añade:

```
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
```

El servicio `notifier` está en el perfil `full` del compose. En
Portainer abre *Editor* y en el campo *Compose path* mantén
`docker-compose.portainer.yml`, pero al desplegar marca el perfil
`full` (o desde CLI: `--profile full`).

El notifier lee la SQLite del bot en read-only y empuja alertas
batched de fills, drawdown y proximidad a liquidación.

## 10. Backups del SQLite

El script `scripts/backup.sh` hace un backup WAL-safe del SQLite (no
un `cp` plano, que puede producir un archivo corrupto si el bot está
escribiendo). Honra `GRVT_DATA_DIR`.

Descárgalo al host:

```bash
sudo curl -fsSL \
  https://raw.githubusercontent.com/dignitasjota/gravityBot/main/scripts/backup.sh \
  -o $DATA_DIR/scripts/backup.sh
sudo chmod +x $DATA_DIR/scripts/backup.sh
sudo apt-get install -y sqlite3   # para el .backup oficial
```

Prueba manual:

```bash
sudo GRVT_DATA_DIR=$DATA_DIR $DATA_DIR/scripts/backup.sh
```

Debes ver una línea tipo
`[2026-05-29T03:00:00Z] backup: /var/backups/grvt-grid-bot/grid_bot_20260529_030000.db.gz (XXk)`.

Programa el cron:

```bash
sudo crontab -e
```

Añade (sustituye la ruta por tu `$DATA_DIR` real):

```cron
0 3 * * * GRVT_DATA_DIR=/opt/webs/gravity-bot /opt/webs/gravity-bot/scripts/backup.sh >> /var/log/grvt-backup.log 2>&1
```

Por defecto guarda 7 días en `/var/backups/grvt-grid-bot/`. Override
con `BACKUP_DIR` y `BACKUP_RETAIN_DAYS` si lo necesitas. Plantéate
sincronizar `/var/backups/grvt-grid-bot/` a un sitio externo (S3,
Backblaze B2, otro VPS por `rsync`) — si el VPS se incendia, los
backups locales arden con él.

## 11. Despliegue alternativo desde CLI (sin Portainer)

Si prefieres gestionar con `docker compose` directamente:

```bash
sudo mkdir -p /opt/grvt-grid && sudo chown $USER:$USER /opt/grvt-grid
cd /opt/grvt-grid
git clone https://github.com/dignitasjota/gravityBot.git .

cp packages/bot/.env.example .env
# Edita .env con todas las variables de la tabla del paso 4

# Si tus datos no están en /opt/grvt-grid, exporta también:
export GRVT_DATA_DIR=/opt/webs/gravity-bot
export NPM_NETWORK=npm-net

docker compose -f docker-compose.yml -f docker-compose.npm.yml build
docker compose -f docker-compose.yml -f docker-compose.npm.yml up -d
docker compose -f docker-compose.yml -f docker-compose.npm.yml logs -f bot
```

La diferencia con la opción Portainer es que aquí sí hay un `.env`
en el filesystem y el compose base se mezcla con `docker-compose.npm.yml`
como overlay. El overlay sólo funciona bien con docker compose ≥ 2.20.

## Troubleshooting

| Síntoma | Causa / arreglo |
|---|---|
| `Failed to deploy a stack: failed to load the compose file` | El campo *Compose path* en Portainer no coincide con el nombre del archivo. Debe ser `docker-compose.portainer.yml` (con punto, no guión). |
| `env file /data/compose/<id>/.env not found` | Estás usando el compose base + overlay en lugar de `docker-compose.portainer.yml`. Cambia al autocontenido. |
| `service "bot" has neither an image nor a build context specified` | *Compose path* apunta al overlay (`docker-compose.npm.yml`) sin el base. Usa `docker-compose.portainer.yml` solo. |
| `network npm-network declared as external, but could not be found` | `NPM_NETWORK` no está o no coincide con `docker network ls`. Verifica el nombre real y añádelo a las env del stack. |
| `pull access denied for grvt-grid/bot` | Marcaste *Re-pull image*. La imagen es local — desmárcala y usa *Re-build image*. |
| `GRVT_TRADING_ACCOUNT_ID no encontrado en .env` | Falta esa env en el stack (o las otras GRVT). Añade todas las del paso 4. |
| `GLIBC_2.38 not found` al cargar `node_sqlite3.node` | Fix del repo: la imagen ya compila las nativas desde fuente. Si lo ves, asegúrate de **rebuild** (no pull) tras actualizar. |
| `SQLITE_CANTOPEN: unable to open database file` | El bind-mount apunta a un directorio que no existe o no es del UID 10000. Revisa `$DATA_DIR/data` y `chown 10000:10000`. |
| `Master key file not found at /run/secrets/master.key` | `master.key` no está creada en `$DATA_DIR/secrets/`, o `MASTER_KEY_PATH` está mal. La env debe ser `/run/secrets/master.key`. |
| `EACCES` sobre `/app/data` | El directorio `data/` no pertenece al uid 10000. `chown -R 10000:10000 $DATA_DIR/data`. |
| Error TS al hacer build del dashboard | Fix del repo: añade `vite-env.d.ts`. Si lo ves en versiones nuevas, abre issue. |
| 502 Bad Gateway en el dominio | NPM no alcanza al bot. Revisa: (a) bot está en `NPM_NETWORK` (`docker inspect grvt-grid-bot`), (b) `Forward Hostname` exacto a `grvt-grid-bot`, puerto 3848, (c) Websockets activado. |
| Dashboard carga pero no se refresca | Falta el toggle *Websockets Support* en el Proxy Host de NPM. |
| Enlace de password reset apunta a `http://localhost` | `APP_BASE_URL` no configurado o mal escrito. |
| El contenedor reinicia en bucle | `docker logs grvt-grid-bot --tail 50` — habitualmente una env obligatoria que falta o auth fallida contra GRVT. |
| Mensajes raros `◇ injected env (0) from .env // tip:...` | Ruido de `dotenv` v17+. No es un error, sólo publicidad del paquete. Se puede silenciar con `DOTENV_CONFIG_QUIET=true` como env del stack. |
