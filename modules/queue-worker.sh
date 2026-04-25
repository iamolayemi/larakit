#!/usr/bin/env bash
# =============================================================================
#  Module 10 — Queue Worker (Supervisor)
#  Run standalone: sudo bash modules/10-queue-worker.sh
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
else
  # Called from larakit CLI or setup.sh — source libs from SETUP_BASE_DIR
  source "${SETUP_BASE_DIR}/lib/colors.sh"
  source "${SETUP_BASE_DIR}/lib/prompts.sh"
  source "${SETUP_BASE_DIR}/lib/creds.sh"
  source "${SETUP_BASE_DIR}/lib/utils.sh"
fi

module_header "Queue Worker" "Installs Supervisor and sets up Laravel queue workers."
require_root

# Config
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"
ask DEPLOY_USER "User to run worker as" "$DEPLOY_USER"
ask PHP_VERSION "PHP version" "$PHP_VERSION"

ask_choice QUEUE_CONNECTION "Queue connection:" \
  "redis (recommended)" \
  "database" \
  "sqs (AWS SQS)"

QUEUE_CONNECTION="${QUEUE_CONNECTION%% *}"

ask QUEUE_NAME "Queue name(s) — comma separated" "default"
ask NUM_WORKERS "Number of worker processes" "2"
ask WORKER_TIMEOUT "Worker timeout (seconds)" "90"
ask WORKER_SLEEP "Sleep between jobs when queue empty (seconds)" "3"
ask WORKER_MAX_TRIES "Max attempts before failing a job" "3"
ask WORKER_MAX_JOBS "Restart worker after N jobs (memory leak prevention)" "500"

echo
confirm_or_exit "Configure Supervisor queue workers?"

# Install Supervisor
step "Installing Supervisor..."
pkg_install supervisor
systemctl enable supervisor --quiet
systemctl start supervisor
success "Supervisor installed and running."

# Queue worker config
step "Creating Supervisor configuration..."
APP_NAME="${APP_PATH##*/}"
APP_NAME="${APP_NAME:-laravel}"

cat > /etc/supervisor/conf.d/laravel-worker.conf << EOF
[program:laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php${PHP_VERSION} ${APP_PATH}/artisan queue:work ${QUEUE_CONNECTION} \
  --queue=${QUEUE_NAME} \
  --sleep=${WORKER_SLEEP} \
  --tries=${WORKER_MAX_TRIES} \
  --timeout=${WORKER_TIMEOUT} \
  --max-jobs=${WORKER_MAX_JOBS} \
  --max-time=3600
autostart=true
autorestart=true
startsecs=1
startretries=5
user=${DEPLOY_USER}
numprocs=${NUM_WORKERS}
redirect_stderr=true
stdout_logfile=/var/log/supervisor/laravel-worker.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
stopasgroup=true
killasgroup=true
stopwaitsecs=120
EOF

# Reload supervisor
supervisorctl reread > /dev/null
supervisorctl update > /dev/null
supervisorctl start "laravel-worker:*" 2> /dev/null || true
success "Queue workers started (${NUM_WORKERS} processes)."

# Quick health check
sleep 2
STATUS=$(supervisorctl status laravel-worker 2> /dev/null | head -1)
if echo "$STATUS" | grep -q "RUNNING"; then
  success "Workers running: ${STATUS}"
else
  warn "Worker status: ${STATUS}"
  warn "Check: supervisorctl status laravel-worker"
fi

# Save
creds_section "Queue"
creds_save "QUEUE_CONNECTION" "$QUEUE_CONNECTION"
creds_save "QUEUE_WORKERS" "$NUM_WORKERS"
creds_save "QUEUE_LOG" "/var/log/supervisor/laravel-worker.log"
creds_save "SUPERVISOR_CONF" "/etc/supervisor/conf.d/laravel-worker.conf"

echo
success "Queue worker module complete."
info "Manage workers:"
dim "supervisorctl status laravel-worker"
dim "supervisorctl restart laravel-worker:*"
dim "tail -f /var/log/supervisor/laravel-worker.log"
