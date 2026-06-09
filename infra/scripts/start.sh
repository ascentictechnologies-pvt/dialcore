#!/usr/bin/env bash
# ============================================================
#  DialCore — Start all services
#  Usage: sudo bash start.sh [SERVICE]
#  Services: api | asterisk | redis | postgresql | coturn | nginx | all
#  Default: all
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

[[ $EUID -eq 0 ]] || { err "Run with sudo: sudo bash start.sh"; exit 1; }

TARGET="${1:-all}"

start_svc() {
  local name="$1"
  if systemctl is-active --quiet "${name}" 2>/dev/null; then
    ok "${name} already running"
  else
    systemctl start "${name}" && ok "${name} started" \
      || err "${name}: failed to start"
  fi
}

header "DialCore — Start ${TARGET}"

case "$TARGET" in
  api)        start_svc dialcore-api ;;
  asterisk)   start_svc asterisk ;;
  redis)      start_svc redis-server ;;
  postgresql) start_svc postgresql ;;
  coturn)     start_svc coturn ;;
  nginx)      start_svc nginx ;;
  all)
    start_svc postgresql
    start_svc redis-server
    start_svc coturn
    start_svc asterisk
    start_svc dialcore-api
    start_svc nginx
    ;;
  *)
    err "Unknown service: ${TARGET}"
    echo "Usage: sudo bash start.sh [api|asterisk|redis|postgresql|coturn|nginx|all]"
    exit 1 ;;
esac

echo ""
ok "Done."
