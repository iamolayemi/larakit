#!/usr/bin/env bash
# =============================================================================
#  Module — Laravel Horizon (Redis Queue Dashboard)
#  Run standalone: sudo bash modules/horizon.sh
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

module_header "Laravel Horizon" "Redis queue monitor with a beautiful dashboard at /horizon."
require_root

# Detect existing
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"

HORIZON_INSTALLED=false
if [[ -f "${APP_PATH}/vendor/laravel/horizon/src/Horizon.php" ]]; then
  HORIZON_INSTALLED=true
  warn "Horizon is already installed in ${APP_PATH}."
  ask_choice EXISTING_MODE "Horizon detected — what to do?" \
    "Reconfigure Supervisor and Nginx only (use existing)" \
    "Reinstall and reconfigure everything" \
    "Skip — just generate configs"
else
  EXISTING_MODE="Reinstall and reconfigure everything"
fi

# Config
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask DEPLOY_USER "Deploy user" "$DEPLOY_USER"
ask PHP_VERSION "PHP version" "$PHP_VERSION"

# Horizon dashboard auth
ask HORIZON_USER "Horizon dashboard username" "admin"
HORIZON_PASS="$(gen_password 16)"
warn "Generated Horizon password: ${HORIZON_PASS}"
ask_yn USE_GEN_PASS "Use this generated password?" "y"
[[ "$USE_GEN_PASS" != "true" ]] && ask_secret HORIZON_PASS "Enter Horizon dashboard password"

# Nginx basic auth for /horizon
ask_yn NGINX_BASIC_AUTH "Protect /horizon with Nginx basic auth?" "y"
APP_DOMAIN_INPUT="${APP_DOMAIN}"
ask APP_DOMAIN_INPUT "App domain (for Nginx config)" "$APP_DOMAIN_INPUT"

echo
confirm_or_exit "Set up Laravel Horizon?"

# Install Horizon via Composer
if [[ "$EXISTING_MODE" == "Reinstall"* ]]; then
  step "Installing laravel/horizon..."
  sudo -u "$DEPLOY_USER" composer require laravel/horizon --working-dir="$APP_PATH" --no-interaction --quiet
  sudo -u "$DEPLOY_USER" php "${APP_PATH}/artisan" horizon:install --no-interaction 2> /dev/null || true
  success "Horizon installed."
fi

# Supervisor config
if [[ "$EXISTING_MODE" != "Skip"* ]]; then
  step "Creating Horizon Supervisor configuration..."
  pkg_install supervisor 2> /dev/null || true

  cat > /etc/supervisor/conf.d/laravel-horizon.conf << EOF
[program:laravel-horizon]
process_name=%(program_name)s
command=/usr/bin/php${PHP_VERSION} ${APP_PATH}/artisan horizon
autostart=true
autorestart=true
user=${DEPLOY_USER}
redirect_stderr=true
stdout_logfile=${APP_PATH}/storage/logs/horizon.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
stopasgroup=true
killasgroup=true
stopwaitsecs=3600
EOF

  supervisorctl reread > /dev/null
  supervisorctl update > /dev/null
  supervisorctl start laravel-horizon 2> /dev/null || supervisorctl restart laravel-horizon 2> /dev/null || true
  success "Horizon Supervisor process configured."
fi

# Nginx basic auth
if [[ "$NGINX_BASIC_AUTH" == "true" ]]; then
  step "Setting up Nginx basic auth for /horizon..."
  pkg_install apache2-utils -y -q 2> /dev/null || true

  HTPASSWD_FILE="/etc/nginx/.htpasswd-horizon"
  htpasswd -bc "$HTPASSWD_FILE" "$HORIZON_USER" "$HORIZON_PASS" 2> /dev/null

  VHOST_FILE="/etc/nginx/sites-available/${APP_DOMAIN_INPUT}"
  if [[ -f "$VHOST_FILE" ]]; then
    # Inject /horizon location block before the closing }
    if ! grep -q "location /horizon" "$VHOST_FILE"; then
      tmp=$(mktemp)
      awk -v htpasswd="$HTPASSWD_FILE" '
        /location ~ \\\.php\$/ {
          print ""
          print "    location /horizon {"
          print "        auth_basic \"Horizon\";"
          print "        auth_basic_user_file " htpasswd ";"
          print "        try_files $uri $uri/ /index.php?$query_string;"
          print "    }"
          print ""
        }
        { print }
      ' "$VHOST_FILE" > "$tmp" && mv "$tmp" "$VHOST_FILE"
      nginx -t 2> /dev/null && systemctl reload nginx 2> /dev/null || warn "Nginx reload failed — check config manually."
    fi
    success "Nginx basic auth configured for /horizon."
  else
    warn "Nginx vhost not found at ${VHOST_FILE} — add the location block manually."
  fi
fi

# Save
creds_section "Horizon"
creds_save "HORIZON_URL" "https://${APP_DOMAIN_INPUT}/horizon"
creds_save "HORIZON_USER" "$HORIZON_USER"
creds_save "HORIZON_PASSWORD" "$HORIZON_PASS"
creds_save "HORIZON_SUPERVISOR_CONF" "/etc/supervisor/conf.d/laravel-horizon.conf"

echo
success "Horizon module complete."
info "Dashboard: https://${APP_DOMAIN_INPUT}/horizon"
info "Credentials: ${HORIZON_USER} / ${HORIZON_PASS}"
dim "Manage: supervisorctl restart laravel-horizon"
