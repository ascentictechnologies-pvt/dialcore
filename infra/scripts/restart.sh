#!/usr/bin/env bash
# ============================================================
#  DialCore — Restart services
#  Usage: sudo bash restart.sh [SERVICE]
#  Services: api | asterisk | redis | postgresql | coturn | nginx | all
#  Default: api
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

[[ $EUID -eq 0 ]] || { err "Run with sudo: sudo bash restart.sh"; exit 1; }

TARGET="${1:-api}"

restart_svc() {
  local name="$1"
  systemctl restart "${name}" && ok "${name} restarted" \
    || err "${name}: failed to restart"
}

# Sync Asterisk config files before restarting
sync_asterisk_conf() {
  local src="${INFRA_DIR}/asterisk"
  local dest="/etc/asterisk"
  if [[ -d "${src}" && -d "${dest}" ]]; then
    for f in "${src}"/*.conf; do
      cp "$f" "${dest}/$(basename "$f")"
    done
    info "Asterisk config synced to ${dest}"
  fi
}

header "DialCore — Restart ${TARGET}"

case "$TARGET" in
  api)        restart_svc dialcore-api ;;
  asterisk)   sync_asterisk_conf; restart_svc asterisk ;;
  redis)      restart_svc redis-server ;;
  postgresql) restart_svc postgresql ;;
  coturn)     restart_svc coturn ;;
  nginx)      nginx -t && restart_svc nginx ;;
  all)
    sync_asterisk_conf
    restart_svc postgresql
    restart_svc redis-server
    restart_svc coturn
    restart_svc asterisk
    restart_svc dialcore-api
    nginx -t && restart_svc nginx
    ;;
  *)
    err "Unknown service: ${TARGET}"
    echo "Usage: sudo bash restart.sh [api|asterisk|redis|postgresql|coturn|nginx|all]"
    exit 1 ;;
esac

echo ""
ok "Done."
