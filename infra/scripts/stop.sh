#!/usr/bin/env bash
# ============================================================
#  DialCore — Stop all services
#  Usage: sudo bash stop.sh [SERVICE]
#  Services: api | asterisk | redis | postgresql | coturn | nginx | all
#  Default: all
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

[[ $EUID -eq 0 ]] || { err "Run with sudo: sudo bash stop.sh"; exit 1; }

TARGET="${1:-all}"

stop_svc() {
  local name="$1"
  if systemctl is-active --quiet "${name}" 2>/dev/null; then
    systemctl stop "${name}" && ok "${name} stopped"
  else
    info "${name} was not running"
  fi
}

header "DialCore — Stop ${TARGET}"

case "$TARGET" in
  api)        stop_svc dialcore-api ;;
  asterisk)   stop_svc asterisk ;;
  redis)      stop_svc redis-server ;;
  postgresql) stop_svc postgresql ;;
  coturn)     stop_svc coturn ;;
  nginx)      stop_svc nginx ;;
  all)
    stop_svc dialcore-api
    stop_svc asterisk
    stop_svc coturn
    stop_svc redis-server
    stop_svc postgresql
    stop_svc nginx
    ;;
  *)
    err "Unknown service: ${TARGET}"
    echo "Usage: sudo bash stop.sh [api|asterisk|redis|postgresql|coturn|nginx|all]"
    exit 1 ;;
esac

echo ""
ok "Done."
