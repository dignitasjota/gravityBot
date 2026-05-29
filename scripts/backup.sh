#!/usr/bin/env bash
# G.3 — Automated SQLite backup.
# Run nightly via cron, e.g.:
#   0 3 * * * GRVT_DATA_DIR=/opt/webs/gravity-bot /opt/webs/gravity-bot/scripts/backup.sh
#
# Creates a timestamped copy of the SQLite database using the safe
# .backup command (handles WAL mode correctly — a raw cp can produce
# a corrupt copy if the bot is writing). Keeps the last 7 days of
# backups and deletes older ones.
#
# Env overrides (all optional):
#   GRVT_DATA_DIR        host dir holding {data,logs,secrets}.
#                        Default: /opt/grvt-grid (matches the compose
#                        default). Used to derive DB_PATH if GRID_BOT_DB
#                        is not set.
#   GRID_BOT_DB          full path to grid_bot.db. Overrides the path
#                        derived from GRVT_DATA_DIR.
#   BACKUP_DIR           where to write the .db.gz files.
#                        Default: /var/backups/grvt-grid-bot
#   BACKUP_RETAIN_DAYS   retention window. Default: 7

set -euo pipefail

GRVT_DATA_DIR="${GRVT_DATA_DIR:-/opt/grvt-grid}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/grvt-grid-bot}"
DB_PATH="${GRID_BOT_DB:-${GRVT_DATA_DIR}/data/grid_bot.db}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-7}"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/grid_bot_${TIMESTAMP}.db"

mkdir -p "$BACKUP_DIR"

# Use SQLite's .backup command for WAL-safe copy
if command -v sqlite3 &>/dev/null; then
  sqlite3 "$DB_PATH" ".backup '$BACKUP_FILE'"
else
  # Fallback: copy + checkpoint (less safe during writes)
  cp "$DB_PATH" "$BACKUP_FILE"
  cp "${DB_PATH}-wal" "${BACKUP_FILE}-wal" 2>/dev/null || true
fi

# Compress
gzip "$BACKUP_FILE" 2>/dev/null || true

# Prune old backups
find "$BACKUP_DIR" -name "grid_bot_*.db*" -mtime +"$RETAIN_DAYS" -delete 2>/dev/null || true

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] backup: ${BACKUP_FILE}.gz ($(du -sh "${BACKUP_FILE}.gz" 2>/dev/null | cut -f1 || echo 'unknown'))"
