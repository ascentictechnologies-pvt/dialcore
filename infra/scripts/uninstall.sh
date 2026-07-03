#!/usr/bin/env bash
# ============================================================
#  DialCore — Ubuntu Server Uninstaller
#  Reverses infra/scripts/install.sh
#
#  Usage:
#    sudo bash uninstall.sh [OPTIONS]
#
#  Options:
#    --keep-packages   Stop/disable PostgreSQL, Redis, Coturn, Asterisk, and the
#                       .NET runtime instead of apt-purging them (use this on a
#                       shared host where those services predate/outlive DialCore).
#    --keep-data       Do not drop the 'dialcore' database or delete recordings/
#                       logs — everything else is still removed.
#    --no-backup       Skip the pre-removal backup step (DB dump + recordings/
#                       logs/config archive to /root/dialcore-uninstall-backup-*).
#    -y / --yes        Non-interactive — skip the confirmation prompt.
#    -h / --help       Show this help
#
#  What this script removes by default (full teardown):
#    1.  dialcore-api systemd service + unit file
#    2.  Nginx site config for DialCore (the nginx package itself is kept —
#        it may serve other sites on a shared host)
#    3.  Asterisk (config, packages, spool/log/lib/run dirs)
#    4.  Coturn (config, package)
#    5.  Redis (config, package)
#    6.  PostgreSQL 'dialcore' database + role, and (unless --keep-packages)
#        the PostgreSQL 16 / TimescaleDB packages + their apt repos
#    7.  .NET ASP.NET Core runtime + Microsoft apt repo (unless --keep-packages)
#    8.  /opt/Ascentic/Dialer, /etc/ascentic/dialer, /etc/odbc.ini DSN
#    9.  UFW rules added by the installer (3478, 5060, 10000:10100)
#    10. The system user created to run the service
#
#  Does NOT remove: nginx, git, curl, build-essential, ufw, and other generic
#  OS packages the installer used as prerequisites — those are assumed shared
#  with the rest of the box and are safe to leave in place.
# ============================================================
set -euo pipefail

# ── Constants (must match install.sh) ────────────────────────────────────────
readonly APP_DIR="/opt/Ascentic/Dialer"
readonly BACKEND_DIR="${APP_DIR}/BackEnd"
readonly FRONTEND_DIR="${APP_DIR}/FrontEnd"
readonly CONF_DIR="/etc/ascentic/dialer"
readonly SERVICE_NAME="dialcore-api"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }
die()     { err "$*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
PURGE_PACKAGES=true
KEEP_DATA=false
DO_BACKUP=true
NON_INTERACTIVE=false

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-packages)  PURGE_PACKAGES=false; shift ;;
    --keep-data)      KEEP_DATA=true;       shift ;;
    --no-backup)      DO_BACKUP=false;      shift ;;
    -y|--yes)         NON_INTERACTIVE=true; shift ;;
    -h|--help)
      sed -n '8,34p' "$0" | sed 's/^#  \{0,2\}//' | sed 's/^#//'
      exit 0 ;;
    *) die "Unknown option: $1. Run with --help." ;;
  esac
done

# ── Root Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script with sudo: sudo bash uninstall.sh"

# ── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
cat <<'BANNER'
  ____  _       _  ____
 |  _ \(_) __ _| |/ ___|___  _ __ ___
 | | | | |/ _` | | |   / _ \| '__/ _ \
 | |_| | | (_| | | |__| (_) | | |  __/
 |____/|_|\__,_|_|\____\___/|_|  \___|

  Ubuntu Server Uninstaller
BANNER
echo -e "${NC}"

# ── Detect what's actually installed ─────────────────────────────────────────
INSTALL_USER=""
if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
  INSTALL_USER="$(grep -E '^User=' "/etc/systemd/system/${SERVICE_NAME}.service" | head -1 | cut -d= -f2)"
fi

DB_USER=""
if [[ -f "${BACKEND_DIR}/appsettings.Production.json" ]]; then
  DB_USER="$(grep -oE 'Username=[^;"]+' "${BACKEND_DIR}/appsettings.Production.json" | head -1 | cut -d= -f2)"
fi

DOMAIN=""
if [[ -f /etc/nginx/sites-available/dialcore.conf ]]; then
  DOMAIN="$(grep -m1 -oE 'server_name [^;]+;' /etc/nginx/sites-available/dialcore.conf | awk '{print $2}' | tr -d ';')"
fi

# ── Confirm ──────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}This will remove the following from this server:${NC}"
echo -e "    Service:        ${SERVICE_NAME} (systemd unit)"
echo -e "    App files:      ${APP_DIR}"
echo -e "    Config:         ${CONF_DIR}"
echo -e "    System user:    ${INSTALL_USER:-<not found>}"
echo -e "    Database:       dialcore (role: ${DB_USER:-<not found>}) $($KEEP_DATA && echo '— KEPT (--keep-data)')"
echo -e "    Nginx site:     dialcore.conf (nginx package itself is kept)"
echo -e "    Domain seen:    ${DOMAIN:-<not found>}"
echo -e "    Services:       PostgreSQL 16+TimescaleDB, Redis, Coturn, Asterisk, .NET runtime"
echo -e "                    $($PURGE_PACKAGES && echo '— packages will be PURGED' || echo '— packages kept, only stopped/disabled')"
echo -e "    Backup:         $($DO_BACKUP && echo 'yes, to /root/dialcore-uninstall-backup-<timestamp>/' || echo 'skipped (--no-backup)')"
echo ""
warn "This is destructive and largely irreversible beyond the backup taken above."

if ! $NON_INTERACTIVE; then
  read -rp "Type 'yes' to proceed: " _confirm
  [[ "${_confirm}" == "yes" ]] || die "Aborted."
fi

# ── Phase 1: Backup ──────────────────────────────────────────────────────────
if $DO_BACKUP; then
  header "Phase 1 — Backup"
  BACKUP_DIR="/root/dialcore-uninstall-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "${BACKUP_DIR}"

  if systemctl is-active --quiet postgresql 2>/dev/null && \
     sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='dialcore'" 2>/dev/null | grep -q 1; then
    sudo -u postgres pg_dump dialcore > "${BACKUP_DIR}/dialcore.sql" 2>/dev/null \
      && ok "Database dumped to ${BACKUP_DIR}/dialcore.sql" \
      || warn "Database dump failed — continuing anyway"
  fi

  [[ -d "${BACKEND_DIR}/recordings" ]] && tar czf "${BACKUP_DIR}/recordings.tar.gz" -C "${BACKEND_DIR}" recordings 2>/dev/null || true
  [[ -d "${BACKEND_DIR}/logs" ]]       && tar czf "${BACKUP_DIR}/logs.tar.gz"       -C "${BACKEND_DIR}" logs       2>/dev/null || true
  [[ -f "${BACKEND_DIR}/.env" ]]       && cp "${BACKEND_DIR}/.env" "${BACKUP_DIR}/env.bak" 2>/dev/null || true
  [[ -f "${BACKEND_DIR}/appsettings.Production.json" ]] && cp "${BACKEND_DIR}/appsettings.Production.json" "${BACKUP_DIR}/appsettings.Production.json.bak" 2>/dev/null || true
  [[ -d /etc/asterisk ]] && tar czf "${BACKUP_DIR}/etc-asterisk.tar.gz" -C /etc asterisk 2>/dev/null || true

  chmod 700 "${BACKUP_DIR}"
  ok "Backup written to ${BACKUP_DIR}"
else
  warn "Skipping backup (--no-backup)"
fi

# ── Phase 2: dialcore-api systemd service ───────────────────────────────────
header "Phase 2 — DialCore API service"

systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
ok "Removed systemd unit '${SERVICE_NAME}'"

# ── Phase 3: Nginx site ──────────────────────────────────────────────────────
header "Phase 3 — Nginx site"

rm -f /etc/nginx/sites-enabled/dialcore.conf /etc/nginx/sites-available/dialcore.conf
rm -f /etc/nginx/sites-enabled/certbot-temp.conf /etc/nginx/sites-available/certbot-temp.conf
if [[ -f /etc/nginx/sites-available/default ]] && [[ ! -e /etc/nginx/sites-enabled/default ]]; then
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi
if command -v nginx &>/dev/null; then
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || warn "Nginx reload skipped (config test failed or nginx not running)"
fi
ok "DialCore Nginx site removed (nginx package kept)"

if [[ -n "$DOMAIN" ]] && [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]] && command -v certbot &>/dev/null; then
  certbot delete --cert-name "${DOMAIN}" --non-interactive 2>/dev/null || warn "Could not remove Let's Encrypt cert for ${DOMAIN}"
  (crontab -l 2>/dev/null | grep -v "certbot renew") | crontab - 2>/dev/null || true
fi

# ── Phase 4: Asterisk ────────────────────────────────────────────────────────
header "Phase 4 — Asterisk"

systemctl stop asterisk 2>/dev/null || true
systemctl disable asterisk 2>/dev/null || true
if $PURGE_PACKAGES; then
  apt-get purge -y -qq asterisk asterisk-doc asterisk-modules asterisk-config \
    asterisk-core-sounds-en asterisk-core-sounds-en-gsm asterisk-moh-opsound-gsm 2>/dev/null || true
  rm -rf /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/run/asterisk
  ok "Asterisk packages purged and data removed"
else
  rm -f /etc/asterisk/*.conf 2>/dev/null || true
  warn "Asterisk package left installed (--keep-packages); DialCore config files removed"
fi

# ── Phase 5: Coturn ──────────────────────────────────────────────────────────
header "Phase 5 — Coturn"

systemctl stop coturn 2>/dev/null || true
systemctl disable coturn 2>/dev/null || true
rm -f /etc/turnserver.conf
if $PURGE_PACKAGES; then
  apt-get purge -y -qq coturn 2>/dev/null || true
  ok "Coturn purged"
else
  warn "Coturn package left installed (--keep-packages)"
fi

# ── Phase 6: Redis ───────────────────────────────────────────────────────────
header "Phase 6 — Redis"

if $PURGE_PACKAGES; then
  systemctl stop redis-server 2>/dev/null || true
  systemctl disable redis-server 2>/dev/null || true
  apt-get purge -y -qq redis-server 2>/dev/null || true
  rm -rf /etc/redis
  ok "Redis purged"
else
  if [[ -f /etc/redis/redis.conf.orig ]]; then
    cp /etc/redis/redis.conf.orig /etc/redis/redis.conf
    systemctl restart redis-server 2>/dev/null || true
    ok "Redis config restored from pre-install backup"
  fi
  warn "Redis package left installed (--keep-packages)"
fi

# ── Phase 7: PostgreSQL + TimescaleDB ────────────────────────────────────────
header "Phase 7 — PostgreSQL + TimescaleDB"

if systemctl is-active --quiet postgresql 2>/dev/null; then
  if ! $KEEP_DATA; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS dialcore;" 2>/dev/null || true
    [[ -n "$DB_USER" ]] && sudo -u postgres psql -c "DROP ROLE IF EXISTS \"${DB_USER}\";" 2>/dev/null || true
    ok "Database 'dialcore' and role dropped"
  else
    warn "Keeping database 'dialcore' and its role (--keep-data)"
  fi
fi

if $PURGE_PACKAGES; then
  systemctl stop postgresql 2>/dev/null || true
  apt-get purge -y -qq postgresql-16 postgresql-client-16 timescaledb-2-postgresql-16 timescaledb-tools 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/postgresql.list /etc/apt/sources.list.d/timescaledb.list
  rm -f /etc/apt/keyrings/postgresql.gpg /etc/apt/keyrings/timescaledb.gpg
  warn "PostgreSQL 16 cluster packages purged — if other databases lived in this cluster they are gone (check the backup dir)"
else
  warn "PostgreSQL package left installed (--keep-packages)"
fi

rm -f /etc/odbc.ini
ok "ODBC DSN removed"

# ── Phase 8: .NET ASP.NET Core Runtime ───────────────────────────────────────
header "Phase 8 — .NET Runtime"

if $PURGE_PACKAGES; then
  apt-get purge -y -qq aspnetcore-runtime-10.0 dotnet-runtime-10.0 dotnet-hostfxr-10.0 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/microsoft-prod.list
  rm -f /etc/apt/keyrings/microsoft.gpg
  ok ".NET runtime purged"
else
  warn ".NET runtime left installed (--keep-packages)"
fi

# ── Phase 9: App files and system user ───────────────────────────────────────
header "Phase 9 — App files and system user"

if $KEEP_DATA; then
  find "${BACKEND_DIR}" -mindepth 1 -maxdepth 1 ! -name recordings ! -name logs -exec rm -rf {} + 2>/dev/null || true
  rm -rf "${FRONTEND_DIR}"
  warn "Kept ${BACKEND_DIR}/recordings and ${BACKEND_DIR}/logs (--keep-data)"
else
  rm -rf "${APP_DIR}"
  ok "Removed ${APP_DIR}"
fi
rm -rf "${CONF_DIR}"
ok "Removed ${CONF_DIR}"

if [[ -n "$INSTALL_USER" ]] && id "${INSTALL_USER}" &>/dev/null; then
  userdel "${INSTALL_USER}" 2>/dev/null && ok "Removed system user '${INSTALL_USER}'" \
    || warn "Could not remove user '${INSTALL_USER}' (it may still own files)"
fi

# ── Phase 10: UFW rules ───────────────────────────────────────────────────────
header "Phase 10 — Firewall rules"

if command -v ufw &>/dev/null; then
  ufw delete allow 3478/udp        2>/dev/null || true
  ufw delete allow 3478/tcp        2>/dev/null || true
  ufw delete allow 5060/udp        2>/dev/null || true
  ufw delete allow 5060/tcp        2>/dev/null || true
  ufw delete allow 10000:10100/udp 2>/dev/null || true
  ok "Removed DialCore-specific UFW rules (22/80/443 and UFW itself left untouched)"
fi

# ── Phase 11: Cleanup ─────────────────────────────────────────────────────────
if $PURGE_PACKAGES; then
  header "Phase 11 — Cleanup"
  apt-get autoremove -y -qq 2>/dev/null || true
  ok "Orphaned dependencies removed"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  DialCore Uninstall Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
$DO_BACKUP && echo -e "  ${BOLD}Backup:${NC} ${BACKUP_DIR}"
$KEEP_DATA && echo -e "  ${YELLOW}Kept:${NC} dialcore database, ${BACKEND_DIR}/recordings, ${BACKEND_DIR}/logs"
$PURGE_PACKAGES || echo -e "  ${YELLOW}Kept installed (--keep-packages):${NC} PostgreSQL, Redis, Coturn, Asterisk, .NET runtime, nginx"
echo -e "  ${DIM}Existing /root/dialcore-credentials-*.txt files were not touched — remove manually if desired.${NC}"
echo ""
