#!/usr/bin/env bash
# =============================================================================
#  Module 11 — Task Scheduler (Cron)
#  Run standalone: sudo bash modules/11-scheduler.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  # Source config for SETUP_BASE_URL
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

module_header "Task Scheduler" "Adds Laravel schedule:run to cron for automatic task scheduling."
require_root

# Config
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"
ask DEPLOY_USER "User to run scheduler as" "$DEPLOY_USER"
ask PHP_VERSION "PHP version" "$PHP_VERSION"

ask_choice SCHEDULER_TYPE "Scheduler mode:" \
  "Cron (every minute — traditional)" \
  "Laravel Schedule Work (daemon — Laravel 10+)" \
  "Both (cron as fallback)"

LOG_PATH="/var/log/laravel-scheduler.log"
ask LOG_PATH "Scheduler log file" "$LOG_PATH"

echo
confirm_or_exit "Configure Laravel scheduler?"

touch "$LOG_PATH"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$LOG_PATH" 2> /dev/null || true

PHP_BIN="/usr/bin/php${PHP_VERSION}"

case "$SCHEDULER_TYPE" in
  "Cron"*)
    step "Adding cron entry for ${DEPLOY_USER}..."
    CRON_LINE="* * * * * ${PHP_BIN} ${APP_PATH}/artisan schedule:run >> ${LOG_PATH} 2>&1"
    (
      crontab -u "$DEPLOY_USER" -l 2> /dev/null
      echo "$CRON_LINE"
    ) | sort -u | crontab -u "$DEPLOY_USER" -
    success "Cron entry added for ${DEPLOY_USER}."
    creds_save "SCHEDULER_TYPE" "cron"
    ;;

  "Laravel Schedule Work"*)
    step "Setting up schedule:work as a Supervisor daemon..."
    cat > /etc/supervisor/conf.d/laravel-scheduler.conf << EOF
[program:laravel-scheduler]
command=${PHP_BIN} ${APP_PATH}/artisan schedule:work
autostart=true
autorestart=true
user=${DEPLOY_USER}
numprocs=1
redirect_stderr=true
stdout_logfile=${LOG_PATH}
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=3
EOF
    supervisorctl reread > /dev/null && supervisorctl update > /dev/null
    supervisorctl start laravel-scheduler 2> /dev/null || true
    success "schedule:work daemon started via Supervisor."
    creds_save "SCHEDULER_TYPE" "supervisor-daemon"
    ;;

  "Both"*)
    step "Adding cron entry (every minute)..."
    CRON_LINE="* * * * * ${PHP_BIN} ${APP_PATH}/artisan schedule:run >> ${LOG_PATH} 2>&1"
    (
      crontab -u "$DEPLOY_USER" -l 2> /dev/null
      echo "$CRON_LINE"
    ) | sort -u | crontab -u "$DEPLOY_USER" -
    success "Cron entry added."
    creds_save "SCHEDULER_TYPE" "cron+supervisor"
    ;;
esac

# Log rotation
cat > /etc/logrotate.d/laravel-scheduler << EOF
${LOG_PATH} {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 ${DEPLOY_USER} ${DEPLOY_USER}
}
EOF

creds_section "Scheduler"
creds_save "SCHEDULER_LOG" "$LOG_PATH"

echo
success "Scheduler module complete."
info "Verify: php artisan schedule:list"
