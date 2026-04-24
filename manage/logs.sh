#!/usr/bin/env bash
# =============================================================================
#  Manage — Logs
#  Tail Laravel, Nginx, and queue-worker logs simultaneously.
#  Run standalone: sudo bash manage/logs.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh"
  _src() {
    local f="$1"
    if [[ -f "${_BASE}/lib/${f}" ]]; then source "${_BASE}/lib/${f}"; else
      local t
      t=$(mktemp)
      curl -fsSL "${SETUP_BASE_URL}/lib/${f}" -o "$t" && source "$t"
      rm -f "$t"
    fi
  }
  _src colors.sh
  _src prompts.sh
  _src creds.sh
  _src utils.sh
  export SETUP_LOADED=1
fi

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask_choice LOG_TARGET "Which logs to view?" \
  "Laravel application log" \
  "Nginx error log" \
  "Nginx access log" \
  "Queue worker log (Supervisor)" \
  "Horizon log" \
  "Octane log" \
  "All Laravel logs (combined)" \
  "System log (journald)"

LINE_COUNT=100
ask LINE_COUNT "Lines to tail" "100"

case "$LOG_TARGET" in
  "Laravel application"*)
    LOG="${APP_PATH}/storage/logs/laravel.log"
    ;;
  "Nginx error"*)
    LOG="/var/log/nginx/${APP_DOMAIN}-error.log"
    [[ ! -f "$LOG" ]] && LOG="/var/log/nginx/error.log"
    ;;
  "Nginx access"*)
    LOG="/var/log/nginx/${APP_DOMAIN}-access.log"
    [[ ! -f "$LOG" ]] && LOG="/var/log/nginx/access.log"
    ;;
  "Queue worker"*)
    LOG="/var/log/supervisor/laravel-worker.log"
    ;;
  "Horizon"*)
    LOG="${APP_PATH}/storage/logs/horizon.log"
    ;;
  "Octane"*)
    LOG="${APP_PATH}/storage/logs/octane.log"
    ;;
  "All Laravel logs"*)
    info "Tailing all logs in ${APP_PATH}/storage/logs/"
    echo -e "${DIM}Press Ctrl+C to stop${NC}\n"
    tail -f "${APP_PATH}"/storage/logs/*.log 2> /dev/null
    exit 0
    ;;
  "System log"*)
    info "Tailing system journal (Ctrl+C to stop)..."
    journalctl -f -n "$LINE_COUNT"
    exit 0
    ;;
esac

if [[ ! -f "$LOG" ]]; then
  error "Log file not found: ${LOG}"
  exit 1
fi

info "Log: ${LOG}"
echo -e "${DIM}Showing last ${LINE_COUNT} lines, then tailing... (Ctrl+C to stop)${NC}\n"
divider
tail -n "$LINE_COUNT" -f "$LOG"
