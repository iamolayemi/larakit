#!/usr/bin/env bash
# =============================================================================
#  Manage — Log Rotate
#  Configure logrotate for Laravel, Nginx, and queue worker logs.
#  Run standalone: sudo bash manage/logrotate.sh
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

module_header "Log Rotation" "Configure logrotate for Laravel, Nginx, and queue worker logs."
require_root

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "/var/www/app")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "app")"

ask APP_PATH "App directory" "$APP_PATH"
ask DEPLOY_USER "App user (owns log files)" "$DEPLOY_USER"

ask_choice LOG_FREQ "Log rotation frequency:" \
  "daily   — rotate every day" \
  "weekly  — rotate every week" \
  "monthly — rotate every month"
LOG_FREQ="${LOG_FREQ%% *}"

ask_choice LOG_KEEP "Keep rotated logs for:" \
  "14  — 14 days / 14 files" \
  "30  — 30 days / 30 files" \
  "7   — 7 days / 7 files" \
  "60  — 60 days / 60 files"
LOG_KEEP="${LOG_KEEP%% *}"

echo
confirm_or_exit "Configure logrotate?"

pkg_install logrotate 2> /dev/null || true

# ---- Laravel logs -----------------------------------------------------------
LARAVEL_CONF="/etc/logrotate.d/laravel-${APP_DOMAIN}"
step "Writing ${LARAVEL_CONF}..."
backup_file "$LARAVEL_CONF" 2> /dev/null || true
cat > "$LARAVEL_CONF" << CONF
${APP_PATH}/storage/logs/*.log {
    ${LOG_FREQ}
    missingok
    rotate ${LOG_KEEP}
    compress
    delaycompress
    notifempty
    copytruncate
    su ${DEPLOY_USER} ${DEPLOY_USER}
    dateext
    dateformat -%Y%m%d-%s
}
CONF
success "Laravel log rotation configured."

# ---- Nginx logs -------------------------------------------------------------
if [[ -d "/var/log/nginx" ]]; then
  NGINX_CONF="/etc/logrotate.d/nginx-${APP_DOMAIN}"
  step "Writing ${NGINX_CONF}..."
  backup_file "$NGINX_CONF" 2> /dev/null || true
  cat > "$NGINX_CONF" << CONF
/var/log/nginx/${APP_DOMAIN}*.log {
    ${LOG_FREQ}
    missingok
    rotate ${LOG_KEEP}
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2> /dev/null || true
    endscript
}
CONF
  success "Nginx log rotation configured."
fi

# ---- Supervisor / Queue logs ------------------------------------------------
SUPERVISOR_LOG="/var/log/supervisor"
if [[ -d "$SUPERVISOR_LOG" ]]; then
  SUP_CONF="/etc/logrotate.d/supervisor-${APP_DOMAIN}"
  step "Writing ${SUP_CONF}..."
  backup_file "$SUP_CONF" 2> /dev/null || true
  cat > "$SUP_CONF" << CONF
${SUPERVISOR_LOG}/*.log {
    ${LOG_FREQ}
    missingok
    rotate ${LOG_KEEP}
    compress
    delaycompress
    notifempty
    copytruncate
}
CONF
  success "Supervisor log rotation configured."
fi

# ---- PHP-FPM logs -----------------------------------------------------------
PHP_FPM_LOG="/var/log/php${PHP_VERSION}-fpm.log"
if [[ -f "$PHP_FPM_LOG" ]]; then
  PHP_CONF="/etc/logrotate.d/php${PHP_VERSION}-fpm-${APP_DOMAIN}"
  step "Writing ${PHP_CONF}..."
  cat > "$PHP_CONF" << CONF
${PHP_FPM_LOG} {
    ${LOG_FREQ}
    missingok
    rotate ${LOG_KEEP}
    compress
    delaycompress
    notifempty
    postrotate
        kill -USR1 \$(cat /run/php/php${PHP_VERSION}-fpm.pid 2> /dev/null) 2> /dev/null || true
    endscript
}
CONF
  success "PHP-FPM log rotation configured."
fi

# ---- Test -------------------------------------------------------------------
step "Testing logrotate configuration..."
logrotate --debug /etc/logrotate.d/laravel-"${APP_DOMAIN}" 2>&1 | tail -5

echo
success "Log rotation configured."
info "Frequency: ${LOG_FREQ} | Keep: ${LOG_KEEP} files"
info "Force a test rotation with: logrotate -f /etc/logrotate.d/laravel-${APP_DOMAIN}"
