#!/usr/bin/env bash
# =============================================================================
#  Manage — Crontab
#  View and manage application cron entries.
#  Run standalone: sudo bash manage/crontab.sh
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

module_header "Crontab Manager" "View and manage cron entries for the deploy user."
require_root

DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "/var/www/app")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask_choice CRON_ACTION "Action:" \
  "list   — show current crontab entries" \
  "add    — add Laravel schedule runner (* * * * *)" \
  "edit   — open crontab in editor" \
  "remove — remove the Laravel schedule entry"
CRON_ACTION="${CRON_ACTION%% *}"

SCHEDULE_ENTRY="* * * * * cd ${APP_PATH} && /usr/bin/php${PHP_VERSION} artisan schedule:run >> /dev/null 2>&1"

case "$CRON_ACTION" in
  list)
    section "Crontab for ${DEPLOY_USER}"
    if crontab -u "$DEPLOY_USER" -l 2> /dev/null | grep -v '^#' | grep -q .; then
      crontab -u "$DEPLOY_USER" -l 2> /dev/null | grep -v '^$' | while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && printf "  ${DIM}%s${NC}\n" "$line" && continue
        printf "  ${CYAN}%s${NC}\n" "$line"
      done
    else
      info "No crontab entries for ${DEPLOY_USER}."
    fi

    echo
    section "Root Crontab (relevant)"
    crontab -l 2> /dev/null | grep -i "artisan\|larakit\|laravel" | while IFS= read -r line; do
      printf "  ${DIM}root:${NC} %s\n" "$line"
    done || true
    ;;

  add)
    # Build correct PHP path
    ask CRON_USER "Add cron for which user?" "$DEPLOY_USER"
    ask PHP_BIN "PHP binary" "/usr/bin/php${PHP_VERSION}"
    ask CRON_APP_PATH "App path" "$APP_PATH"

    SCHEDULE_ENTRY="* * * * * cd ${CRON_APP_PATH} && ${PHP_BIN} artisan schedule:run >> /dev/null 2>&1"

    if crontab -u "$CRON_USER" -l 2> /dev/null | grep -qF "artisan schedule:run"; then
      warn "Laravel schedule:run already exists in crontab for ${CRON_USER}."
      crontab -u "$CRON_USER" -l 2> /dev/null | grep "artisan schedule"
    else
      (
        crontab -u "$CRON_USER" -l 2> /dev/null
        echo "$SCHEDULE_ENTRY"
      ) | crontab -u "$CRON_USER" -
      success "Laravel schedule runner added for ${CRON_USER}:"
      echo -e "  ${DIM}${SCHEDULE_ENTRY}${NC}"
    fi
    ;;

  edit)
    ask CRON_USER "Edit crontab for which user?" "$DEPLOY_USER"
    step "Opening crontab for ${CRON_USER} in \$EDITOR / nano..."
    EDITOR="${EDITOR:-nano}"
    crontab -u "$CRON_USER" -e
    ;;

  remove)
    ask CRON_USER "Remove from crontab for which user?" "$DEPLOY_USER"
    if crontab -u "$CRON_USER" -l 2> /dev/null | grep -qF "artisan schedule:run"; then
      confirm_or_exit "Remove the artisan schedule:run entry for ${CRON_USER}?"
      tmp=$(mktemp)
      crontab -u "$CRON_USER" -l 2> /dev/null | grep -vF "artisan schedule:run" > "$tmp" || true
      crontab -u "$CRON_USER" "$tmp"
      rm -f "$tmp"
      success "Schedule runner removed from ${CRON_USER}'s crontab."
    else
      info "No artisan schedule:run entry found for ${CRON_USER}."
    fi
    ;;
esac
