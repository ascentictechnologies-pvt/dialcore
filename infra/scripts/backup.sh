#!/usr/bin/env bash
# ============================================================
#  DialCore — PostgreSQL Database Backup
#  Usage: sudo bash backup.sh [--dir /path/to/backups]
#  Default backup dir: /opt/Ascentic/Dialer/backups
#  Retains backups for 30 days, then auto-prunes.
# ============================================================
set -euo pipefail

readonly APP_DIR="/opt/Ascentic/Dialer"
readonly BACKEND_DIR="${APP_DIR}/BackEnd"
readonly APPSETTINGS="${BACKEND_DIR}/appsettings.Production.json"

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }
die()     { err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash backup.sh"

BACKUP_DIR="${APP_DIR}/backups"
[[ "${1:-}" == "--dir" && -n "${2:-}" ]] && BACKUP_DIR="$2"
mkdir -p "${BACKUP_DIR}"

# ── Read DB password from appsettings.Production.json ────────────────────────
[[ -f "${APPSETTINGS}" ]] || die "appsettings.Production.json not found at ${APPSETTINGS}"

# Extract password from connection string: Password=<value>;
PG_PASS=$(grep -o '"Default"[[:space:]]*:[[:space:]]*"[^"]*"' "${APPSETTINGS}" \
  | grep -o 'Password=[^;]*' | cut -d= -f2-)

[[ -n "${PG_PASS}" ]] || die "Could not read DB password from ${APPSETTINGS}"

PG_HOST="localhost"
PG_PORT="5432"
PG_USER="dialcore"
PG_DB="dialcore"

command -v pg_dump &>/dev/null || die "pg_dump not found. Install: apt-get install postgresql-client"

header "DialCore — Database Backup"
info "Database: ${PG_DB} @ ${PG_HOST}:${PG_PORT}"
info "Output:   ${BACKUP_DIR}"

BACKUP_FILE="${BACKUP_DIR}/dialcore_$(date +%Y%m%d_%H%M%S).sql.gz"

PGPASSWORD="${PG_PASS}" pg_dump \
  -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" \
  --format=plain --no-owner --no-privileges "${PG_DB}" \
  | gzip -9 > "${BACKUP_FILE}"

SIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
ok "Backup saved: ${BACKUP_FILE} (${SIZE})"

# Prune backups older than 30 days
PRUNED=$(find "${BACKUP_DIR}" -name "dialcore_*.sql.gz" -mtime +30 -print -delete | wc -l)
[[ "${PRUNED}" -gt 0 ]] && info "Pruned ${PRUNED} backup(s) older than 30 days"

echo ""
ok "Done."
