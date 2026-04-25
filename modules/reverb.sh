#!/usr/bin/env bash
# =============================================================================
#  Module — Laravel Reverb (WebSockets Server)
#  Run standalone: sudo bash modules/reverb.sh
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

module_header "Laravel Reverb" "High-performance WebSocket server for real-time Laravel apps."
require_root

# Detect existing
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"

REVERB_INSTALLED=false
if [[ -f "${APP_PATH}/vendor/laravel/reverb/src/Reverb.php" ]] 2> /dev/null; then
  REVERB_INSTALLED=true
  warn "Reverb is already installed."
  ask_choice EXISTING_MODE "Reverb detected — what to do?" \
    "Reconfigure Supervisor and Nginx only" \
    "Reinstall and reconfigure everything" \
    "Skip — just show config"
else
  EXISTING_MODE="Reinstall and reconfigure everything"
fi

# Config
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask DEPLOY_USER "Deploy user" "$DEPLOY_USER"
ask PHP_VERSION "PHP version" "$PHP_VERSION"
ask APP_DOMAIN_INPUT "App domain" "${APP_DOMAIN:-}"

ask REVERB_PORT "Reverb internal port" "8080"
ask_choice REVERB_SCHEME "WebSocket scheme:" \
  "wss (secure — via Nginx proxy, recommended)" \
  "ws  (plain, dev only)"

ask_yn NGINX_PROXY "Proxy WebSocket connections via Nginx (port 443 → ${REVERB_PORT})?" "y"

echo
confirm_or_exit "Set up Laravel Reverb?"

# Install
if [[ "$EXISTING_MODE" == "Reinstall"* ]]; then
  step "Installing laravel/reverb..."
  sudo -u "$DEPLOY_USER" composer require laravel/reverb --working-dir="$APP_PATH" --no-interaction --quiet
  sudo -u "$DEPLOY_USER" php "${APP_PATH}/artisan" reverb:install --no-interaction 2> /dev/null || true
  success "Reverb installed."
fi

# UFW rule
if [[ "$REVERB_SCHEME" == "ws"* ]] && [[ "$NGINX_PROXY" != "true" ]]; then
  step "Opening port ${REVERB_PORT} in UFW..."
  add_firewall_rule "$REVERB_PORT" "tcp"
  success "Port ${REVERB_PORT} opened."
fi

# Supervisor config
if [[ "$EXISTING_MODE" != "Skip"* ]]; then
  step "Creating Reverb Supervisor configuration..."
  pkg_install supervisor 2> /dev/null || true

  cat > /etc/supervisor/conf.d/laravel-reverb.conf << EOF
[program:laravel-reverb]
process_name=%(program_name)s
command=/usr/bin/php${PHP_VERSION} ${APP_PATH}/artisan reverb:start --host=0.0.0.0 --port=${REVERB_PORT} --no-interaction
autostart=true
autorestart=true
user=${DEPLOY_USER}
redirect_stderr=true
stdout_logfile=${APP_PATH}/storage/logs/reverb.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
stopasgroup=true
killasgroup=true
EOF

  supervisorctl reread > /dev/null
  supervisorctl update > /dev/null
  supervisorctl start laravel-reverb 2> /dev/null || supervisorctl restart laravel-reverb 2> /dev/null || true
  success "Reverb Supervisor process configured."
fi

# Nginx WebSocket proxy
if [[ "$NGINX_PROXY" == "true" ]]; then
  step "Configuring Nginx WebSocket proxy..."

  VHOST_FILE="/etc/nginx/sites-available/${APP_DOMAIN_INPUT}"
  if [[ -f "$VHOST_FILE" ]]; then
    if ! grep -q "location /app" "$VHOST_FILE"; then
      tmp=$(mktemp)
      # Prepend upstream block
      {
        printf 'upstream reverb {\n    server 127.0.0.1:%s;\n    keepalive 128;\n}\n\n' "$REVERB_PORT"
        cat "$VHOST_FILE"
      } > "$tmp" && mv "$tmp" "$VHOST_FILE"
      # Inject location block before the PHP location
      tmp=$(mktemp)
      awk '
        /location ~ \\\.php\$/ {
          print ""
          print "    location /app {"
          print "        proxy_pass http://reverb;"
          print "        proxy_http_version 1.1;"
          print "        proxy_set_header Upgrade $http_upgrade;"
          print "        proxy_set_header Connection \"upgrade\";"
          print "        proxy_set_header Host $host;"
          print "        proxy_set_header X-Real-IP $remote_addr;"
          print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
          print "        proxy_set_header X-Forwarded-Proto $scheme;"
          print "        proxy_read_timeout 3600;"
          print "        proxy_send_timeout 3600;"
          print "    }"
          print ""
        }
        { print }
      ' "$VHOST_FILE" > "$tmp" && mv "$tmp" "$VHOST_FILE"
      nginx -t 2> /dev/null && systemctl reload nginx 2> /dev/null || warn "Nginx reload failed — check config manually."
    fi
    success "Nginx WebSocket proxy configured."
  else
    warn "Nginx vhost not found — add WebSocket proxy manually."
    info "Proxy upstream block:"
    dim "upstream reverb { server 127.0.0.1:${REVERB_PORT}; }"
    info "Location block:"
    dim "location /app { proxy_pass http://reverb; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; }"
  fi
fi

# Save
REVERB_KEY="$(gen_secret 20)"
REVERB_SECRET="$(gen_secret 40)"
APP_ID="$(gen_secret 8)"

creds_section "Reverb"
creds_save "REVERB_APP_ID" "$APP_ID"
creds_save "REVERB_APP_KEY" "$REVERB_KEY"
creds_save "REVERB_APP_SECRET" "$REVERB_SECRET"
creds_save "REVERB_HOST" "${APP_DOMAIN_INPUT}"
creds_save "REVERB_PORT" "$REVERB_PORT"
creds_save "REVERB_SCHEME" "${REVERB_SCHEME%% *}"

echo
success "Reverb module complete."
info "Add to your .env:"
dim "REVERB_APP_ID=${APP_ID}"
dim "REVERB_APP_KEY=${REVERB_KEY}"
dim "REVERB_APP_SECRET=${REVERB_SECRET}"
dim "REVERB_HOST=${APP_DOMAIN_INPUT}"
dim "REVERB_PORT=${REVERB_PORT}"
dim "REVERB_SCHEME=${REVERB_SCHEME%% *}"
dim ""
dim "VITE_REVERB_APP_KEY=\${REVERB_APP_KEY}"
dim "VITE_REVERB_HOST=\${REVERB_HOST}"
dim "VITE_REVERB_PORT=\${REVERB_PORT}"
dim "VITE_REVERB_SCHEME=\${REVERB_SCHEME}"
