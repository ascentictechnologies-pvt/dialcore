#!/usr/bin/env bash
# ============================================================
#  DialCore — Ubuntu Server Installation Script
#  Supported: Ubuntu 22.04 LTS (Jammy) / 24.04 LTS (Noble)
#
#  Usage:
#    sudo bash install.sh [OPTIONS]
#
#  Options:
#    --domain <value>          Server FQDN or IP  (required)
#    --db-user <value>         PostgreSQL application username (prompted if omitted)
#    --db-password <value>     PostgreSQL password for the DB user (default: auto-generated)
#    --secret-key <value>      Base64 32-byte DIALCORE_SECRET_KEY; preserve on redeploy
#    --redis-password <value>  Redis password (default: preserve existing or auto-generated)
#    --ari-password <value>    Asterisk ARI password (default: preserve existing or auto-generated)
#    --ami-secret <value>      Asterisk AMI secret (default: preserve existing or auto-generated)
#    --coturn-credential <v>   Coturn shared credential (default: preserve existing or auto-generated)
#    --ssl-cert <path>         Path to existing SSL certificate (.crt / fullchain.pem)
#    --ssl-key  <path>         Path to existing SSL private key (.key)
#    --no-ssl                  Use HTTP only — no TLS (for LB-terminated setups)
#    --certbot                 Use Let's Encrypt instead of self-signed cert
#    --letsencrypt-email <v>   E-mail for Let's Encrypt registration
#    -y / --yes                Non-interactive, accept all defaults
#    -h / --help               Show this help
#
#  NOTE: Does NOT build source. Deploy compiled artifacts first with deploy-production.sh.
#        BackEnd/ and FrontEnd/ must be populated before running this script.
#
#  What this script does:
#    1.  Installs PostgreSQL 16 + TimescaleDB 2
#    2.  Installs Redis 7
#    3.  Installs Coturn TURN/STUN
#    4.  Installs .NET 10 ASP.NET Core Runtime
#    5.  Installs Nginx + ffmpeg
#    6.  Creates system user and directory layout
#    7.  Configures PostgreSQL database and user
#    8.  Configures Coturn
#    9.  Writes native backend .env + appsettings.Production.json
#    10. Generates TLS certificate (self-signed or Let's Encrypt)
#    11. Configures Nginx
#    12. Creates and enables systemd service
#    13. Installs and configures Asterisk
#    14. Configures UFW firewall
#    15. Starts all services and runs health checks
#    16. Records installer-owned components to /etc/ascentic/dialer/installed-components.list
# ============================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # infra/ root — holds asterisk/, nginx/, postgres/
readonly APP_DIR="/opt/Ascentic/Dialer"
readonly BACKEND_DIR="${APP_DIR}/BackEnd"
readonly FRONTEND_DIR="${APP_DIR}/FrontEnd"
readonly CONF_DIR="/etc/ascentic/dialer"
readonly COMPONENT_MANIFEST="${CONF_DIR}/installed-components.list"
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

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

init_component_manifest() {
  mkdir -p "${CONF_DIR}"
  touch "${COMPONENT_MANIFEST}"
  chmod 600 "${COMPONENT_MANIFEST}"
}

record_component() {
  local component="$1"
  mkdir -p "${CONF_DIR}"
  touch "${COMPONENT_MANIFEST}"
  chmod 600 "${COMPONENT_MANIFEST}"
  grep -qxF "${component}" "${COMPONENT_MANIFEST}" 2>/dev/null || echo "${component}" >> "${COMPONENT_MANIFEST}"
}

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN=""
DB_USER=""
DB_PASSWORD=""
SECRET_KEY=""
JWT_SECRET=""
REDIS_PASSWORD=""
ARI_PASSWORD=""
AMI_SECRET=""
COTURN_CREDENTIAL=""
NO_SSL=false
USE_CERTBOT=false
LE_EMAIL=""
CUSTOM_CERT=""
CUSTOM_KEY=""
NON_INTERACTIVE=false

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)             DOMAIN="$2";            shift 2 ;;
    --db-user)            DB_USER="$2";            shift 2 ;;
    --db-password)        DB_PASSWORD="$2";        shift 2 ;;
    --secret-key)         SECRET_KEY="$2";         shift 2 ;;
    --redis-password)     REDIS_PASSWORD="$2";     shift 2 ;;
    --ari-password)       ARI_PASSWORD="$2";       shift 2 ;;
    --ami-secret)         AMI_SECRET="$2";         shift 2 ;;
    --coturn-credential)  COTURN_CREDENTIAL="$2";  shift 2 ;;
    --ssl-cert)           CUSTOM_CERT="$2";        shift 2 ;;
    --ssl-key)            CUSTOM_KEY="$2";         shift 2 ;;
    --no-ssl)             NO_SSL=true;             shift ;;
    --certbot)            USE_CERTBOT=true;        shift ;;
    --letsencrypt-email)  LE_EMAIL="$2";           shift 2 ;;
    -y|--yes)             NON_INTERACTIVE=true;    shift ;;
    -h|--help)
      sed -n '8,25p' "$0" | sed 's/^#  \{0,2\}//' | sed 's/^#//'
      exit 0 ;;
    *) die "Unknown option: $1. Run with --help." ;;
  esac
done

# ── Banner ───────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}"
cat <<'BANNER'
  ____  _       _  ____
 |  _ \(_) __ _| |/ ___|___  _ __ ___
 | | | | |/ _` | | |   / _ \| '__/ _ \
 | |_| | | (_| | | |__| (_) | | |  __/
 |____/|_|\__,_|_|\____\___/|_|  \___|

  Ubuntu Server Installation Script
BANNER
echo -e "${NC}"

# ── Root Check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script with sudo: sudo bash install.sh"

# ── System Username Detection ─────────────────────────────────────────────────
# SUDO_USER is set by sudo to the original invoking user; fall back to "dialcore".
INSTALL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "dialcore")}"
[[ "$INSTALL_USER" == "root" ]] && INSTALL_USER="dialcore"
info "Installation system user: ${INSTALL_USER}"

# ── Ubuntu Version Check ─────────────────────────────────────────────────────
if ! grep -qE "22\.04|24\.04" /etc/os-release 2>/dev/null; then
  warn "Tested on Ubuntu 22.04 and 24.04. Current OS may not be supported."
  $NON_INTERACTIVE || read -rp "Continue anyway? [y/N] " _confirm
  [[ "${_confirm:-n}" =~ ^[Yy]$ ]] || die "Aborted."
fi
OS_VER=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)   # e.g. 22.04
OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")  # jammy / noble

# ── Prompt for Required Values ───────────────────────────────────────────────
gen_secret() { openssl rand -hex "${1:-24}"; }
gen_key()    { openssl rand -base64 32; }

read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

read_json_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "\"${key}\"[[:space:]]*:" "$file" \
    | tail -1 \
    | sed -E 's/^[^:]+:[[:space:]]*"([^"]*)".*/\1/' \
    || true
}

extract_redis_password() {
  local value="$1"
  [[ "$value" == *password=* ]] || return 0
  printf '%s\n' "$value" | sed -E 's/^.*password=([^,]+).*$/\1/'
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

prompt_or_default() {
  local var_name="$1" prompt="$2" default="$3"
  if [[ -z "${!var_name}" ]]; then
    if $NON_INTERACTIVE; then
      printf -v "$var_name" '%s' "$default"
    else
      read -rp "${prompt} [default: auto-generated]: " _input
      printf -v "$var_name" '%s' "${_input:-$default}"
    fi
  fi
}

if [[ -z "$DOMAIN" ]]; then
  if $NON_INTERACTIVE; then
    die "--domain is required in non-interactive mode."
  fi
  read -rp "Enter server domain or IP address: " DOMAIN
  [[ -n "$DOMAIN" ]] || die "Domain/IP is required."
fi

# ── SSL mode prompt (interactive only, skipped if any SSL flag already set) ──
if ! $NO_SSL && ! $USE_CERTBOT && [[ -z "$CUSTOM_CERT" ]] && ! $NON_INTERACTIVE; then
  echo ""
  echo -e "  ${BOLD}SSL Certificate options:${NC}"
  echo -e "  ${BLUE}1)${NC} Provide your own certificate files (recommended for production)"
  echo -e "  ${BLUE}2)${NC} Let's Encrypt (auto-issue via certbot)"
  echo -e "  ${BLUE}3)${NC} Self-signed (dev/test only — browser will show a warning)"
  read -rp "  Choose [1/2/3, default: 1]: " _ssl_choice
  case "${_ssl_choice:-1}" in
    1)
      read -rp "  Path to certificate file (.crt / fullchain.pem): " CUSTOM_CERT
      read -rp "  Path to private key file (.key): " CUSTOM_KEY
      ;;
    2)
      USE_CERTBOT=true
      read -rp "  Let's Encrypt e-mail: " LE_EMAIL
      ;;
    3)
      : # self-signed — default fallback, nothing to set
      ;;
    *)
      warn "Invalid choice — defaulting to self-signed."
      ;;
  esac
fi

# Prompt for DB username — no non-interactive default; must be supplied explicitly
if [[ -z "$DB_USER" ]]; then
  if $NON_INTERACTIVE; then
    die "--db-user is required in non-interactive mode."
  fi
  read -rp "Enter PostgreSQL database username: " DB_USER
  [[ -n "$DB_USER" ]] || die "Database username is required."
fi

prompt_or_default DB_PASSWORD "PostgreSQL password" "$(gen_secret 16)"

EXISTING_ENV_FILE="${BACKEND_DIR}/.env"
EXISTING_APPSETTINGS="${BACKEND_DIR}/appsettings.Production.json"

if [[ -z "$SECRET_KEY" ]]; then
  SECRET_KEY="$(read_env_value "${EXISTING_ENV_FILE}" "DIALCORE_SECRET_KEY")"
  [[ -n "$SECRET_KEY" ]] || SECRET_KEY="$(read_json_value "${EXISTING_APPSETTINGS}" "DIALCORE_SECRET_KEY")"
  [[ -n "$SECRET_KEY" ]] || SECRET_KEY="$(gen_key)"
fi

if [[ -z "$JWT_SECRET" ]]; then
  JWT_SECRET="$(read_env_value "${EXISTING_ENV_FILE}" "JWT_SECRET")"
  [[ -n "$JWT_SECRET" ]] || JWT_SECRET="$(read_json_value "${EXISTING_APPSETTINGS}" "JWT_SECRET")"
  [[ -n "$JWT_SECRET" ]] || JWT_SECRET="$(gen_secret 32)"
fi

if [[ -z "$REDIS_PASSWORD" ]]; then
  _existing_redis="$(read_env_value "${EXISTING_ENV_FILE}" "REDIS_CONNECTION")"
  REDIS_PASSWORD="$(extract_redis_password "${_existing_redis:-}")"
  [[ -n "$REDIS_PASSWORD" ]] || REDIS_PASSWORD="$(gen_secret 16)"
fi

if [[ -z "$ARI_PASSWORD" ]]; then
  ARI_PASSWORD="$(read_env_value "${EXISTING_ENV_FILE}" "ASTERISK_ARI_PASSWORD")"
  [[ -n "$ARI_PASSWORD" ]] || ARI_PASSWORD="$(gen_secret 16)"
fi

if [[ -z "$AMI_SECRET" ]]; then
  AMI_SECRET="$(read_env_value "${EXISTING_ENV_FILE}" "AMI_SECRET")"
  [[ -n "$AMI_SECRET" ]] || AMI_SECRET="$(gen_secret 16)"
fi

if [[ -z "$COTURN_CREDENTIAL" ]]; then
  COTURN_CREDENTIAL="$(read_env_value "${EXISTING_ENV_FILE}" "COTURN_CREDENTIAL")"
  [[ -n "$COTURN_CREDENTIAL" ]] || COTURN_CREDENTIAL="$(gen_secret 16)"
fi

# ── Confirm ──────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Domain:${NC}      ${DOMAIN}"
echo -e "  ${BOLD}DB User:${NC}     ${DB_USER}"
echo -e "  ${BOLD}BackEnd:${NC}     ${BACKEND_DIR}"
echo -e "  ${BOLD}FrontEnd:${NC}    ${FRONTEND_DIR}"
echo -e "  ${BOLD}SSL:${NC}         $(if $NO_SSL; then echo HTTP-only; elif [[ -n "$CUSTOM_CERT" ]]; then echo "Custom cert: $CUSTOM_CERT"; elif $USE_CERTBOT; then echo "Let's Encrypt"; else echo "Self-signed"; fi)"
echo ""

# Verify that pre-built artifacts exist before proceeding
[[ -f "${BACKEND_DIR}/DialCore.API.dll" ]] || die "BackEnd not found: ${BACKEND_DIR}/DialCore.API.dll. Run deploy-production.sh first."
[[ -f "${FRONTEND_DIR}/index.html" ]]       || die "FrontEnd not found: ${FRONTEND_DIR}/index.html. Run deploy-production.sh first."

if ! $NON_INTERACTIVE; then
  read -rp "Proceed with installation? [Y/n] " _confirm
  [[ "${_confirm:-y}" =~ ^[Yy]$ ]] || die "Aborted."
fi

init_component_manifest
record_component "manifest:${COMPONENT_MANIFEST}"
record_component "config_dir:${CONF_DIR}"

# ── Phase 1: System Packages ─────────────────────────────────────────────────
header "Phase 1 — System Packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || warn "apt-get update reported errors (possibly stale/broken third-party repos already configured on this host) — continuing"
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  apt-transport-https software-properties-common \
  unzip git ffmpeg ufw openssl \
  build-essential jq net-tools \
  unixodbc odbc-postgresql
ok "Base packages installed"

# ── Phase 2: PostgreSQL 16 + TimescaleDB ────────────────────────────────────
header "Phase 2 — PostgreSQL 16 + TimescaleDB"

POSTGRES_WAS_INSTALLED=false
TIMESCALE_WAS_INSTALLED=false
package_installed postgresql-16 && POSTGRES_WAS_INSTALLED=true
package_installed timescaledb-2-postgresql-16 && TIMESCALE_WAS_INSTALLED=true
if systemctl is-active --quiet postgresql; then
  ok "PostgreSQL already running"
else
  # PostgreSQL official APT
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt ${OS_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/postgresql.list

  # TimescaleDB APT
  curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/timescaledb.gpg
  echo "deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] \
https://packagecloud.io/timescale/timescaledb/ubuntu/ ${OS_CODENAME} main" \
    > /etc/apt/sources.list.d/timescaledb.list

  apt-get update -qq || warn "apt-get update reported errors (possibly stale/broken third-party repos already configured on this host) — continuing"
  apt-get install -y -qq postgresql-16 timescaledb-2-postgresql-16
  $POSTGRES_WAS_INSTALLED || record_component "package:postgresql-16"
  $TIMESCALE_WAS_INSTALLED || record_component "package:timescaledb-2-postgresql-16"
  record_component "apt_repo:/etc/apt/sources.list.d/postgresql.list"
  record_component "apt_repo:/etc/apt/sources.list.d/timescaledb.list"
  record_component "apt_key:/etc/apt/keyrings/postgresql.gpg"
  record_component "apt_key:/etc/apt/keyrings/timescaledb.gpg"

  # Auto-tune for TimescaleDB
  timescaledb-tune --quiet --yes 2>/dev/null || true

  systemctl enable --now postgresql
  ok "PostgreSQL 16 + TimescaleDB installed"
fi

# ── Phase 4: Redis ───────────────────────────────────────────────────────────
header "Phase 4 — Redis 7"

REDIS_WAS_INSTALLED=false
package_installed redis-server && REDIS_WAS_INSTALLED=true
if systemctl is-active --quiet redis-server 2>/dev/null; then
  ok "Redis already running"
else
  apt-get install -y -qq redis-server
  $REDIS_WAS_INSTALLED || record_component "package:redis-server"
  systemctl enable redis-server
  ok "Redis installed"
fi

# Configure Redis
REDIS_CONF="/etc/redis/redis.conf"
cp -n "${REDIS_CONF}" "${REDIS_CONF}.orig" 2>/dev/null || true

# Bind to localhost only, set password, set memory policy
sed -i \
  -e 's/^bind .*/bind 127.0.0.1 ::1/' \
  -e 's/^# requirepass .*/requirepass REDIS_PASS_PLACEHOLDER/' \
  -e '/^requirepass /c requirepass REDIS_PASS_PLACEHOLDER' \
  -e 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' \
  "${REDIS_CONF}"

# Set actual password
REDIS_PASSWORD_SED="$(escape_sed_replacement "${REDIS_PASSWORD}")"
sed -i "s/REDIS_PASS_PLACEHOLDER/${REDIS_PASSWORD_SED}/g" "${REDIS_CONF}"

# Set maxmemory if not already set
grep -q "^maxmemory " "${REDIS_CONF}" || echo "maxmemory 512mb" >> "${REDIS_CONF}"

systemctl restart redis-server
record_component "config:/etc/redis/redis.conf"
ok "Redis configured (auth + memory policy)"

# ── Phase 5: Coturn ──────────────────────────────────────────────────────────
header "Phase 5 — Coturn TURN/STUN"

COTURN_WAS_INSTALLED=false
package_installed coturn && COTURN_WAS_INSTALLED=true
apt-get install -y -qq coturn
$COTURN_WAS_INSTALLED || record_component "package:coturn"

# Enable daemon
sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null \
  || echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn

# Write coturn config
cat > /etc/turnserver.conf <<TURNEOF
# DialCore Coturn configuration
listening-port=3478
fingerprint
lt-cred-mech
realm=${DOMAIN}
user=dialcore:${COTURN_CREDENTIAL}
total-quota=100
bps-capacity=0
stale-nonce=600
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
TURNEOF

systemctl enable --now coturn
record_component "config:/etc/turnserver.conf"
ok "Coturn configured (realm=${DOMAIN})"

# ── Phase 6: .NET 10 ASP.NET Core Runtime ────────────────────────────────────
header "Phase 6 — .NET 10 ASP.NET Core Runtime"

DOTNET_WAS_INSTALLED=false
package_installed aspnetcore-runtime-10.0 && DOTNET_WAS_INSTALLED=true
if dotnet --version 2>/dev/null | grep -q "^10\."; then
  ok ".NET 10 already installed"
else
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  chmod a+r /etc/apt/keyrings/microsoft.gpg

  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] \
https://packages.microsoft.com/ubuntu/${OS_VER}/prod ${OS_CODENAME} main" \
    > /etc/apt/sources.list.d/microsoft-prod.list

  apt-get update -qq || warn "apt-get update reported errors (possibly stale/broken third-party repos already configured on this host) — continuing"
  # Runtime only — no SDK needed, app is pre-compiled
  apt-get install -y -qq aspnetcore-runtime-10.0
  $DOTNET_WAS_INSTALLED || record_component "package:aspnetcore-runtime-10.0"
  record_component "apt_repo:/etc/apt/sources.list.d/microsoft-prod.list"
  record_component "apt_key:/etc/apt/keyrings/microsoft.gpg"
  ok ".NET ASP.NET Core Runtime $(dotnet --version) installed"
fi

# ── Phase 7: Nginx + ffmpeg ───────────────────────────────────────────────────
header "Phase 7 — Nginx + ffmpeg"

NGINX_WAS_INSTALLED=false
FFMPEG_WAS_INSTALLED=false
package_installed nginx && NGINX_WAS_INSTALLED=true
package_installed ffmpeg && FFMPEG_WAS_INSTALLED=true
apt-get install -y -qq nginx ffmpeg
$NGINX_WAS_INSTALLED || record_component "package:nginx"
$FFMPEG_WAS_INSTALLED || record_component "package:ffmpeg"
systemctl enable nginx
ok "Nginx + ffmpeg installed"

# ── Phase 8: System User and Directories ────────────────────────────────────
header "Phase 8 — System User and Directories"

if ! id "${INSTALL_USER}" &>/dev/null; then
  useradd -r -s /sbin/nologin -d "${APP_DIR}" "${INSTALL_USER}"
  record_component "system_user:${INSTALL_USER}"
fi

mkdir -p \
  "${BACKEND_DIR}" \
  "${FRONTEND_DIR}" \
  "${BACKEND_DIR}/recordings" \
  "${BACKEND_DIR}/logs" \
  "${CONF_DIR}/ssl"

# Root owns the tree; only writable runtime dirs belong to the service user
chown -R root:root "${APP_DIR}" "${CONF_DIR}"
chown "${INSTALL_USER}:${INSTALL_USER}" "${BACKEND_DIR}/logs" "${BACKEND_DIR}/recordings"
chmod 750 "${CONF_DIR}"
record_component "app_dir:${APP_DIR}"
record_component "runtime_dir:${BACKEND_DIR}/logs"
record_component "runtime_dir:${BACKEND_DIR}/recordings"
ok "User '${INSTALL_USER}' and directories ready"

# ── Phase 9: Configure PostgreSQL ───────────────────────────────────────────
header "Phase 9 — PostgreSQL Database Setup"

# Ensure postgres superuser can connect via Unix socket without a password prompt.
# Default Ubuntu pg_hba.conf has peer auth, but some deployments remove it.
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
if ! grep -qE "^local[[:space:]]+all[[:space:]]+postgres[[:space:]]+peer" "${PG_HBA}"; then
  sed -i "1s/^/local   all             postgres                                peer\n/" "${PG_HBA}"
  systemctl reload postgresql
  sleep 2
fi

# Create application DB role
if sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  :
else
  sudo -u postgres psql -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';"
  record_component "db_role:${DB_USER}"
fi

# Create database if not exists
if sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='dialcore'" | grep -q 1; then
  :
else
  sudo -u postgres psql -c "CREATE DATABASE dialcore OWNER \"${DB_USER}\";"
  record_component "database:dialcore"
fi

# Ensure ownership and grants (idempotent for re-runs)
sudo -u postgres psql -c "ALTER DATABASE dialcore OWNER TO \"${DB_USER}\";" 2>/dev/null || true
sudo -u postgres psql -d dialcore -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"${DB_USER}\";" 2>/dev/null || true

# Enable extensions (requires superuser)
sudo -u postgres psql -d dialcore -c \
  "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"; CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;" 2>/dev/null || true

# pg_hba: allow app DB user via scram-sha-256 on localhost TCP
if ! grep -qE "^host[[:space:]]+all[[:space:]]+${DB_USER}[[:space:]]+127" "${PG_HBA}"; then
  sed -i "/^host.*all.*all.*127\.0\.0\.1/i host    all             ${DB_USER}        127.0.0.1/32            scram-sha-256\nhost    all             ${DB_USER}        ::1/128                 scram-sha-256" "${PG_HBA}"
  systemctl reload postgresql
fi

ok "PostgreSQL database 'dialcore' ready (user: ${DB_USER})"

# ── ODBC DSN for Asterisk Realtime ──────────────────────────────────────────
# Asterisk loads res_odbc.so with pre-connect=yes; without a valid DSN it crashes at startup.
ODBC_DRIVER=$(odbcinst -q -d 2>/dev/null | grep -i postgres | head -1 | tr -d '[]' || echo "PostgreSQL Unicode")
cat > /etc/odbc.ini <<ODBCEOF
[dialcore]
Driver     = ${ODBC_DRIVER}
Servername = 127.0.0.1
Port       = 5432
Database   = dialcore
UserName   = ${DB_USER}
Password   = ${DB_PASSWORD}
ODBCEOF
chmod 640 /etc/odbc.ini
record_component "config:/etc/odbc.ini"
ok "ODBC DSN 'dialcore' written to /etc/odbc.ini (driver: ${ODBC_DRIVER})"

# ── Phase 10: Native Runtime Configuration ──────────────────────────────────
header "Phase 10 — Native Runtime Configuration"

PROTOCOL="https"
$NO_SSL && PROTOCOL="http"
REDIS_CONNECTION="localhost:6379,password=${REDIS_PASSWORD},abortConnect=false"

# Written after artifact deployment so dotnet publish cannot overwrite these files.
# The source-tree appsettings.Production.json is a blank template; these are the real values.
write_backend_env() {
cat > "${BACKEND_DIR}/.env" <<ENVEOF
ASPNETCORE_ENVIRONMENT=Production
REDIS_CONNECTION=${REDIS_CONNECTION}
JWT_SECRET=${JWT_SECRET}
JWT_ISSUER=dialcore
JWT_AUDIENCE=dialcore-api
JWT_EXPIRY_MINUTES=60
DIALCORE_SECRET_KEY=${SECRET_KEY}
ASTERISK_ARI_URL=http://localhost:8088
ASTERISK_ARI_USER=dialcore
ASTERISK_ARI_PASSWORD=${ARI_PASSWORD}
ASTERISK_ARI_APP=dialcore
AMI_ENABLED=false
AMI_HOST=localhost
AMI_PORT=5038
AMI_USERNAME=dialcore
AMI_SECRET=${AMI_SECRET}
AMI_RECONNECT_BACKOFF_SECONDS=5
COTURN_URL=turn:${DOMAIN}:3478
COTURN_USER=dialcore
COTURN_CREDENTIAL=${COTURN_CREDENTIAL}
RECORDING_STORAGE_TYPE=local
RECORDING_LOCAL_PATH=${BACKEND_DIR}/recordings
CORS_ORIGINS=${PROTOCOL}://${DOMAIN},http://localhost,http://localhost:4300
DIALCORE_RUN_API=true
DIALCORE_RUN_WORKERS=true
DIALCORE_WORKER_ROLES=all
DIALCORE_RUN_MIGRATIONS=true
ENVEOF
chmod 640 "${BACKEND_DIR}/.env"
chown root:"${INSTALL_USER}" "${BACKEND_DIR}/.env"
}

write_appsettings() {
cat > "${BACKEND_DIR}/appsettings.Production.json" <<JSONEOF
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore": "Warning"
    }
  },
  "AllowedHosts": "*",
  "ConnectionStrings": {
    "Default": "Host=localhost;Port=5432;Database=dialcore;Username=${DB_USER};Password=${DB_PASSWORD};Maximum Pool Size=200;Minimum Pool Size=10;Connection Idle Lifetime=60;Command Timeout=30"
  },
  "REDIS_CONNECTION": "${REDIS_CONNECTION}",
  "JWT_SECRET": "${JWT_SECRET}",
  "JWT_ISSUER": "dialcore",
  "JWT_AUDIENCE": "dialcore-api",
  "JWT_EXPIRY_MINUTES": "60",
  "DIALCORE_SECRET_KEY": "${SECRET_KEY}",
  "ASTERISK_ARI_URL": "http://localhost:8088",
  "ASTERISK_ARI_USER": "dialcore",
  "ASTERISK_ARI_PASSWORD": "${ARI_PASSWORD}",
  "ASTERISK_ARI_APP": "dialcore",
  "AMI_ENABLED": "false",
  "AMI_HOST": "localhost",
  "AMI_PORT": "5038",
  "AMI_USERNAME": "dialcore",
  "AMI_SECRET": "${AMI_SECRET}",
  "AMI_RECONNECT_BACKOFF_SECONDS": "5",
  "COTURN_URL": "turn:${DOMAIN}:3478",
  "COTURN_USER": "dialcore",
  "COTURN_CREDENTIAL": "${COTURN_CREDENTIAL}",
  "RECORDING_STORAGE_TYPE": "local",
  "RECORDING_LOCAL_PATH": "${BACKEND_DIR}/recordings",
  "CORS_ORIGINS": "${PROTOCOL}://${DOMAIN},http://localhost,http://localhost:4300"
}
JSONEOF
chmod 640 "${BACKEND_DIR}/appsettings.Production.json"
chown root:"${INSTALL_USER}" "${BACKEND_DIR}/appsettings.Production.json"
}

write_backend_env
write_appsettings
record_component "config:${BACKEND_DIR}/.env"
record_component "config:${BACKEND_DIR}/appsettings.Production.json"
ok "Native runtime .env and appsettings.Production.json written to ${BACKEND_DIR}/"

# ── Phase 11: TLS Certificate ────────────────────────────────────────────────
header "Phase 11 — TLS Certificate"

SSL_CRT="${CONF_DIR}/ssl/dialcore.crt"
SSL_KEY="${CONF_DIR}/ssl/dialcore.key"

if $NO_SSL; then
  warn "Skipping TLS (--no-ssl). Ensure a terminating proxy is in place."
elif [[ -n "$CUSTOM_CERT" ]]; then
  # ── Custom certificate provided by client ──────────────────────────────────
  [[ -n "$CUSTOM_KEY"  ]] || die "--ssl-key is required when --ssl-cert is provided."
  [[ -f "$CUSTOM_CERT" ]] || die "Certificate file not found: ${CUSTOM_CERT}"
  [[ -f "$CUSTOM_KEY"  ]] || die "Key file not found: ${CUSTOM_KEY}"

  cp "${CUSTOM_CERT}" "${SSL_CRT}"
  cp "${CUSTOM_KEY}"  "${SSL_KEY}"
  record_component "ssl_cert:${SSL_CRT}"
  record_component "ssl_key:${SSL_KEY}"
  ok "Custom SSL certificate installed from ${CUSTOM_CERT}"
elif $USE_CERTBOT; then
  # ── Let's Encrypt ──────────────────────────────────────────────────────────
  [[ -n "$LE_EMAIL" ]] || die "Provide --letsencrypt-email for Let's Encrypt."
  CERTBOT_WAS_INSTALLED=false
  CERTBOT_NGINX_WAS_INSTALLED=false
  package_installed certbot && CERTBOT_WAS_INSTALLED=true
  package_installed python3-certbot-nginx && CERTBOT_NGINX_WAS_INSTALLED=true
  apt-get install -y -qq certbot python3-certbot-nginx
  $CERTBOT_WAS_INSTALLED || record_component "package:certbot"
  $CERTBOT_NGINX_WAS_INSTALLED || record_component "package:python3-certbot-nginx"

  mkdir -p /var/www/certbot
  cat > /etc/nginx/sites-available/certbot-temp.conf <<'CERTEOF'
server { listen 80; location /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 200; } }
CERTEOF
  ln -sf /etc/nginx/sites-available/certbot-temp.conf /etc/nginx/sites-enabled/certbot-temp.conf
  nginx -t && systemctl reload nginx

  certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" --email "${LE_EMAIL}" --agree-tos --non-interactive

  ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${SSL_CRT}"
  ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "${SSL_KEY}"
  rm -f /etc/nginx/sites-enabled/certbot-temp.conf
  rm -f /etc/nginx/sites-available/certbot-temp.conf

  systemctl enable --now certbot.timer 2>/dev/null \
    || (crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet") | crontab -
  record_component "certbot_cert:${DOMAIN}"
  record_component "ssl_cert:${SSL_CRT}"
  record_component "ssl_key:${SSL_KEY}"
  ok "Let's Encrypt certificate issued for ${DOMAIN}"
else
  # ── Self-signed fallback ────────────────────────────────────────────────────
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${SSL_KEY}" \
    -out    "${SSL_CRT}" \
    -subj   "/C=US/ST=State/L=City/O=DialCore/CN=${DOMAIN}" \
    2>/dev/null
  record_component "ssl_cert:${SSL_CRT}"
  record_component "ssl_key:${SSL_KEY}"
  ok "Self-signed certificate generated (365 days)"
fi

chown root:"${INSTALL_USER}" "${SSL_CRT}" "${SSL_KEY}" 2>/dev/null || true
chmod 640 "${SSL_KEY}"

# ── Phase 12: Nginx Configuration ───────────────────────────────────────────
header "Phase 12 — Nginx Configuration"

SSL_BLOCK=""
if ! $NO_SSL; then
  SSL_BLOCK="
    ssl_certificate     ${SSL_CRT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;"
fi

# http2 on the listen line works for all Nginx versions (>= 1.9.5).
# The standalone "http2 on;" directive requires Nginx >= 1.25.1.
LISTEN_HTTPS="443 ssl http2"
$NO_SSL && LISTEN_HTTPS="80"

cat > /etc/nginx/sites-available/dialcore.conf <<NGINXEOF
# ── HTTP → HTTPS redirect ─────────────────────────────────────────────────
$(if ! $NO_SSL; then cat <<'REDIR'
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
REDIR
fi)

# ── Main site ─────────────────────────────────────────────────────────────
server {
    listen ${LISTEN_HTTPS};
    listen [::]:${LISTEN_HTTPS};
    server_name DOMAIN_PLACEHOLDER;
${SSL_BLOCK}

    root ${FRONTEND_DIR};
    index index.html;

    # Security headers
    add_header X-Frame-Options           "SAMEORIGIN"  always;
    add_header X-Content-Type-Options    "nosniff"     always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "camera=(), microphone=(self), geolocation=()" always;
    $(if ! $NO_SSL; then echo 'add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'; fi)

    # Gzip
    gzip on; gzip_vary on; gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript
               application/wasm image/svg+xml font/woff2 font/woff;

    # Static assets (Angular hashes filenames — long cache safe)
    location ~* \.(js|css|woff2?|ttf|eot|svg|png|ico|webp|wasm)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        expires 0;
    }

    # API proxy
    location /api/ {
        proxy_pass         http://unix:/run/dialcore/api.sock;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout  60s;
        proxy_connect_timeout 5s;
        proxy_send_timeout  60s;
        client_max_body_size 50m;
    }

    # SignalR WebSocket
    location /hubs/ {
        proxy_pass         http://unix:/run/dialcore/api.sock;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       \$host;
        proxy_set_header   X-Real-IP  \$remote_addr;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }

    # Health probe
    location = /health {
        proxy_pass http://unix:/run/dialcore/api.sock;
        access_log off;
    }

    location = /nginx-health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

# ── Asterisk PJSIP SIP/WSS TLS terminator (:8089) ────────────────────────
# Browser WebRTC phones connect to wss://domain:8089
# Nginx terminates TLS and forwards plain WS to Asterisk PJSIP on :8090
$(if ! $NO_SSL; then
cat <<'WSEOF'
server {
    listen 8089 ssl;
    server_name DOMAIN_PLACEHOLDER;
    ssl_certificate     SSL_CRT_PLACEHOLDER;
    ssl_certificate_key SSL_KEY_PLACEHOLDER;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "Upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout  86400s;
        proxy_send_timeout  86400s;
    }
}
WSEOF
fi)
NGINXEOF

# Replace placeholders
sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g"   /etc/nginx/sites-available/dialcore.conf
sed -i "s|SSL_CRT_PLACEHOLDER|${SSL_CRT}|g" /etc/nginx/sites-available/dialcore.conf
sed -i "s|SSL_KEY_PLACEHOLDER|${SSL_KEY}|g" /etc/nginx/sites-available/dialcore.conf

ln -sf /etc/nginx/sites-available/dialcore.conf /etc/nginx/sites-enabled/dialcore.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t || die "Nginx config test failed. Check /etc/nginx/sites-available/dialcore.conf"
record_component "nginx_site:/etc/nginx/sites-available/dialcore.conf"
record_component "nginx_site:/etc/nginx/sites-enabled/dialcore.conf"
ok "Nginx configured for ${DOMAIN}"

# ── Phase 13: Systemd Service ────────────────────────────────────────────────
header "Phase 13 — Systemd Service"

cat > /etc/systemd/system/${SERVICE_NAME}.service <<UNITEOF
[Unit]
Description=DialCore API
Documentation=https://github.com/avissol/dialcore
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=${INSTALL_USER}
Group=${INSTALL_USER}
WorkingDirectory=${BACKEND_DIR}
ExecStartPre=+/bin/mkdir -p ${BACKEND_DIR}/logs ${BACKEND_DIR}/recordings
ExecStartPre=+/bin/chown ${INSTALL_USER}:${INSTALL_USER} ${BACKEND_DIR}/logs ${BACKEND_DIR}/recordings
ExecStart=/usr/bin/dotnet ${BACKEND_DIR}/DialCore.API.dll
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
Environment=ASPNETCORE_ENVIRONMENT=Production
EnvironmentFile=${BACKEND_DIR}/.env
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# /run/dialcore/ is created by systemd on each start, owned by dialcore, mode 0750
# The Unix socket (api.sock) is written here by the .NET runtime
RuntimeDirectory=dialcore
RuntimeDirectoryMode=0750

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${BACKEND_DIR}/logs ${BACKEND_DIR}/recordings
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
record_component "systemd_unit:/etc/systemd/system/${SERVICE_NAME}.service"
ok "Systemd unit '${SERVICE_NAME}' registered"

# ── Phase 14: Asterisk (native) ──────────────────────────────────────────────
header "Phase 14 — Asterisk (native)"

ASTERISK_WAS_INSTALLED=false
ASTERISK_DOC_WAS_INSTALLED=false
package_installed asterisk && ASTERISK_WAS_INSTALLED=true
package_installed asterisk-doc && ASTERISK_DOC_WAS_INSTALLED=true
apt-get install -y -qq asterisk asterisk-doc
$ASTERISK_WAS_INSTALLED || record_component "package:asterisk"
$ASTERISK_DOC_WAS_INSTALLED || record_component "package:asterisk-doc"

# Our asterisk.conf pins astdatadir to /var/lib/asterisk (matching an upstream from-source
# install layout). The Debian package instead ships its version-matched XML documentation
# under /usr/share/asterisk/documentation. If a stray from-source build (e.g. leftover
# /usr/src/asterisk-*) previously wrote a mismatched core-en_US.xml into /var/lib/asterisk,
# Asterisk fails to register the 'bucket' sorcery type against it and refuses to start
# ("Bucket API initialization failed"). Always point at the package's own copy.
if [[ -d /usr/share/asterisk/documentation ]] && \
   [[ "$(readlink -f /var/lib/asterisk/documentation 2>/dev/null)" != "/usr/share/asterisk/documentation" ]]; then
  rm -rf /var/lib/asterisk/documentation
  ln -s /usr/share/asterisk/documentation /var/lib/asterisk/documentation
fi

# Copy config files into /etc/asterisk/
for f in "${INFRA_DIR}/asterisk/"*.conf; do
  cp "$f" "/etc/asterisk/$(basename "$f")"
  record_component "asterisk_config:/etc/asterisk/$(basename "$f")"
done

# Stamp generated credentials into the installed Asterisk configs, never the source files.
ARI_PASSWORD_SED="$(escape_sed_replacement "${ARI_PASSWORD}")"
AMI_SECRET_SED="$(escape_sed_replacement "${AMI_SECRET}")"
[[ -f "/etc/asterisk/ari.conf" ]] && sed -i "s/^password = .*/password = ${ARI_PASSWORD_SED}/" "/etc/asterisk/ari.conf"
[[ -f "/etc/asterisk/manager.conf" ]] && sed -i "s/^secret = .*/secret = ${AMI_SECRET_SED}/" "/etc/asterisk/manager.conf"

# Fix ownership (asterisk system user is created by the package)
chown -R asterisk:asterisk /etc/asterisk/ /var/spool/asterisk/ \
  /var/log/asterisk/ /var/run/asterisk/ /var/lib/asterisk/ 2>/dev/null || true

systemctl enable asterisk
ok "Asterisk installed (native systemd)"

# ── Phase 15: UFW Firewall ───────────────────────────────────────────────────
header "Phase 15 — UFW Firewall"

ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS"
ufw allow 3478/udp  comment "TURN UDP"
ufw allow 3478/tcp  comment "TURN TCP"
ufw allow 5060/udp  comment "SIP UDP"
ufw allow 5060/tcp  comment "SIP TCP"
ufw allow 10000:10100/udp comment "RTP media"
ufw --force enable > /dev/null
record_component "ufw_rule:3478/udp"
record_component "ufw_rule:3478/tcp"
record_component "ufw_rule:5060/udp"
record_component "ufw_rule:5060/tcp"
record_component "ufw_rule:10000:10100/udp"
ok "Firewall configured ($(ufw status | grep -c ALLOW) rules)"

# ── Phase 16: Start All Services ────────────────────────────────────────────
header "Phase 16 — Starting Services"

systemctl start postgresql
systemctl start redis-server
systemctl start coturn
systemctl start asterisk
systemctl start "${SERVICE_NAME}"
systemctl reload nginx

ok "All services started"

# ── Phase 17: Health Checks ──────────────────────────────────────────────────
header "Phase 17 — Health Checks"

_pass=0; _fail=0

check() {
  local name="$1" cmd="$2"
  if eval "$cmd" &>/dev/null; then
    ok "${name}"
    ((_pass++)) || true
  else
    warn "${name} — not responding (may still be starting up)"
    ((_fail++)) || true
  fi
}

sleep 8  # give API time to start and run migrations

check "PostgreSQL"      "sudo -u postgres psql -c 'SELECT 1' > /dev/null"
check "Redis"           "systemctl is-active --quiet redis-server"
check "Coturn"          "systemctl is-active --quiet coturn"
check "Asterisk"        "systemctl is-active --quiet asterisk"
check "API /health"     "curl -sf --unix-socket /run/dialcore/api.sock http://localhost/health"
check "Nginx"           "curl -sf -k https://localhost/nginx-health 2>/dev/null || curl -sf http://localhost/nginx-health"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  DialCore Installation Complete${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Application URL:${NC}     ${PROTOCOL}://${DOMAIN}"
echo -e "  ${BOLD}API URL:${NC}             ${PROTOCOL}://${DOMAIN}/api"
echo -e "  ${BOLD}Health Endpoint:${NC}     ${PROTOCOL}://${DOMAIN}/health"
echo ""
echo -e "  ${BOLD}Credentials saved to:${NC} /root/dialcore-credentials-*.txt"
echo -e "  ${DIM}  (chmod 600, root-only — delete after storing in a vault)${NC}"
echo ""
echo -e "  ${BOLD}Health check:${NC}  ${_pass} passed"
[[ $_fail -gt 0 ]] && echo -e "  ${YELLOW}${_fail} check(s) may still be starting — recheck in 30s${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${DIM}  sudo systemctl status dialcore-api${NC}"
echo -e "  ${DIM}  sudo journalctl -u dialcore-api -f${NC}"
echo -e "  ${DIM}  sudo journalctl -u asterisk -f${NC}"
echo -e "  ${DIM}  sudo tail -f /var/log/asterisk/messages${NC}"
echo -e "  ${DIM}  sudo tail -f ${BACKEND_DIR}/logs/dialcore-*.log${NC}"
echo ""

if [[ ! $NO_SSL && ! $USE_CERTBOT ]]; then
  echo -e "  ${YELLOW}Note: Self-signed certificate is in use.${NC}"
  echo -e "  ${YELLOW}      Replace with a CA certificate or re-run with --certbot.${NC}"
  echo ""
fi

echo -e "  ${YELLOW}NEXT STEP: Open ${PROTOCOL}://${DOMAIN} and complete the Setup Wizard.${NC}"
echo -e "  ${YELLOW}  Redis, JWT, Coturn, and local Asterisk bootstrap values were generated by this installer.${NC}"
echo -e "  ${YELLOW}  The wizard can update runtime service settings after first login.${NC}"
echo ""

# Save credentials to a local summary file
CREDS_FILE="/root/dialcore-credentials-$(date +%Y%m%d%H%M%S).txt"
cat > "${CREDS_FILE}" <<CREDSEOF
DialCore Installation — $(date)
Keep this file secure. Delete after storing in a password manager.

Domain:             ${DOMAIN}
App URL:            ${PROTOCOL}://${DOMAIN}

PostgreSQL:
  Host:             localhost:5432
  Database:         dialcore
  User:             ${DB_USER}
  Password:         ${DB_PASSWORD}

Redis:
  Connection:       ${REDIS_CONNECTION}

Asterisk:
  ARI URL:          http://localhost:8088
  ARI User:         dialcore
  ARI Password:     ${ARI_PASSWORD}
  AMI Host:         localhost:5038
  AMI User:         dialcore
  AMI Secret:       ${AMI_SECRET}

Coturn:
  URL:              turn:${DOMAIN}:3478
  User:             dialcore
  Credential:       ${COTURN_CREDENTIAL}

API Secrets:
  JWT_SECRET:       ${JWT_SECRET}
  DIALCORE_SECRET_KEY:
                    ${SECRET_KEY}

Runtime env:        ${BACKEND_DIR}/.env
Config file:        ${BACKEND_DIR}/appsettings.Production.json
Logs:               ${BACKEND_DIR}/logs/
Recordings:         ${BACKEND_DIR}/recordings/

NOTE: SMTP, SMS, and any external service credentials are configured via the
      Setup Wizard (${PROTOCOL}://${DOMAIN}). Preserve DIALCORE_SECRET_KEY
      on every redeploy or encrypted database values will become unreadable.
CREDSEOF
chmod 600 "${CREDS_FILE}"
record_component "credentials:${CREDS_FILE}"
echo -e "  ${BOLD}Credentials saved to:${NC} ${CREDS_FILE}"
echo -e "  ${BOLD}Installed components:${NC} ${COMPONENT_MANIFEST}"
echo -e "  ${RED}  Delete this file after storing passwords in a vault.${NC}"
echo ""
