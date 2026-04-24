#!/usr/bin/env bash
# =============================================================================
#  Manage — Queue Status
#  Queue worker status and failed job dashboard.
#  Run standalone: sudo bash manage/queue-status.sh
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
else
  # Called from larakit CLI or setup.sh — source libs from SETUP_BASE_DIR
  source "${SETUP_BASE_DIR}/lib/colors.sh"
  source "${SETUP_BASE_DIR}/lib/prompts.sh"
  source "${SETUP_BASE_DIR}/lib/creds.sh"
  source "${SETUP_BASE_DIR}/lib/utils.sh"
fi

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

PHP_BIN="/usr/bin/php${PHP_VERSION}"

echo -e "\n  ${BOLD}Supervisor Processes${NC}"
divider
if has_cmd supervisorctl; then
  supervisorctl status 2> /dev/null | grep -E "laravel-" | while read -r line; do
    if echo "$line" | grep -q RUNNING; then
      echo -e "  ${GREEN}${BOLD}✔${NC}  $line"
    else
      echo -e "  ${RED}${BOLD}✘${NC}  $line"
    fi
  done
else
  warn "Supervisor not installed."
fi

if [[ -n "$APP_PATH" ]] && [[ -f "${APP_PATH}/artisan" ]]; then
  echo -e "\n  ${BOLD}Failed Jobs${NC}"
  divider
  "$PHP_BIN" "${APP_PATH}/artisan" queue:failed 2> /dev/null | head -20 | sed 's/^/  /' \
    || warn "Could not retrieve failed jobs."

  echo -e "\n  ${BOLD}Queue Actions${NC}"
  divider
  echo -e "  ${BOLD}1)${NC} Retry all failed jobs"
  echo -e "  ${BOLD}2)${NC} Flush all failed jobs"
  echo -e "  ${BOLD}3)${NC} No action"

  read -r -p "$(echo -e "  ${YELLOW}?${NC}  Choice [1-3]: ")" choice
  case "$choice" in
    1)
      "$PHP_BIN" "${APP_PATH}/artisan" queue:retry all --no-interaction
      success "All failed jobs queued for retry."
      ;;
    2)
      "$PHP_BIN" "${APP_PATH}/artisan" queue:flush --no-interaction
      success "Failed jobs flushed."
      ;;
    *) info "No action taken." ;;
  esac
fi
