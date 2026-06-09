#!/usr/bin/env bash
# ============================================================
#  DialCore — Tail service logs (native systemd / file)
#  Usage:  ./logs.sh [service] [--lines N]
#  Services: api | asterisk | postgres | redis | coturn | all
#  Examples:
#    ./logs.sh              # all (multiplexed via journalctl)
#    ./logs.sh api          # API only
#    ./logs.sh asterisk     # Asterisk messages log
#    ./logs.sh api --lines 200
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BLUE='\033[0;34m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SERVICE="${1:-all}"
LINES=100
[[ "${2:-}" == "--lines" && -n "${3:-}" ]] && LINES="$3"

APP_LOG_DIR="/opt/Ascentic/Dialer/logs"

case "$SERVICE" in
  api)
    info "Streaming dialcore-api journal (last ${LINES} lines)..."
    exec journalctl -u dialcore-api -n "$LINES" -f
    ;;
  asterisk)
    info "Streaming Asterisk messages log (last ${LINES} lines)..."
    exec tail -n "$LINES" -f /var/log/asterisk/messages
    ;;
  postgres|postgresql)
    info "Streaming PostgreSQL journal (last ${LINES} lines)..."
    exec journalctl -u postgresql -n "$LINES" -f
    ;;
  redis)
    info "Streaming Redis journal (last ${LINES} lines)..."
    exec journalctl -u redis-server -n "$LINES" -f
    ;;
  coturn)
    info "Streaming Coturn journal (last ${LINES} lines)..."
    exec journalctl -u coturn -n "$LINES" -f
    ;;
  nginx)
    info "Streaming Nginx error log (last ${LINES} lines)..."
    exec tail -n "$LINES" -f /var/log/nginx/error.log
    ;;
  app)
    LOG_GLOB="${APP_LOG_DIR}/dialcore-*.log"
    # shellcheck disable=SC2086
    LATEST=$(ls -t $LOG_GLOB 2>/dev/null | head -1)
    if [[ -z "$LATEST" ]]; then
      err "No application log files found in ${APP_LOG_DIR}/"
      exit 1
    fi
    info "Streaming ${LATEST} (last ${LINES} lines)..."
    exec tail -n "$LINES" -f "$LATEST"
    ;;
  all)
    info "Streaming all DialCore services (last ${LINES} lines each, Ctrl+C to stop)..."
    exec journalctl \
      -u dialcore-api \
      -u asterisk \
      -u postgresql \
      -u redis-server \
      -u coturn \
      -n "$LINES" -f
    ;;
  *)
    err "Unknown service: ${SERVICE}"
    echo ""
    echo -e "  Usage: $(basename "$0") [service] [--lines N]"
    echo -e "  Services: ${BOLD}api${NC} | asterisk | postgres | redis | coturn | nginx | app | all"
    exit 1
    ;;
esac
