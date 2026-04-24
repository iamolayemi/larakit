#!/usr/bin/env bash
# =============================================================================
#  Module 14 — Laravel Octane (Swoole / FrankenPHP)
#  Run standalone: sudo bash modules/14-octane.sh
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

module_header "Laravel Octane" "Supercharge Laravel with persistent application servers (Swoole / FrankenPHP)."
require_root

warn "Octane replaces PHP-FPM. Nginx will proxy to Octane instead of PHP-FPM."

# Detect existing
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"

OCTANE_INSTALLED=false
if [[ -f "${APP_PATH}/vendor/laravel/octane/src/Octane.php" ]] 2> /dev/null; then
  OCTANE_INSTALLED=true
  warn "Octane already installed."
  ask_choice EXISTING_MODE "Octane detected — what to do?" \
    "Reconfigure Supervisor and Nginx only" \
    "Reinstall and reconfigure everything" \
    "Skip — just generate Nginx config"
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

ask_choice OCTANE_SERVER "Octane server:" \
  "FrankenPHP (recommended — no extension needed)" \
  "Swoole (best performance, requires extension)" \
  "RoadRunner (Go-based, no extension)"

OCTANE_PORT="8000"
ask OCTANE_PORT "Octane internal port" "$OCTANE_PORT"

WORKERS=$(nproc 2> /dev/null || echo "4")
ask OCTANE_WORKERS "Number of workers" "$WORKERS"

echo
confirm_or_exit "Set up Laravel Octane with ${OCTANE_SERVER%% *}?"

# Install dependencies
OCTANE_DRIVER="${OCTANE_SERVER%% *}"
OCTANE_DRIVER_LOWER="${OCTANE_DRIVER,,}"

if [[ "$EXISTING_MODE" == "Reinstall"* ]]; then
  step "Installing laravel/octane..."
  sudo -u "$DEPLOY_USER" composer require laravel/octane --working-dir="$APP_PATH" --no-interaction --quiet

  case "$OCTANE_DRIVER_LOWER" in
    swoole)
      step "Installing Swoole PHP extension..."
      if ! php -m 2> /dev/null | grep -q swoole; then
        if pkg_installed "php${PHP_VERSION}-swoole" 2> /dev/null; then
          info "Swoole extension already installed."
        else
          add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1 || true
          apt-get update -qq
          pkg_install "php${PHP_VERSION}-swoole"
        fi
        systemctl restart "php${PHP_VERSION}-fpm" 2> /dev/null || true
      fi
      sudo -u "$DEPLOY_USER" php "${APP_PATH}/artisan" octane:install --server=swoole --no-interaction 2> /dev/null || true
      ;;

    frankenphp)
      step "Installing FrankenPHP binary..."
      FRANKEN_VERSION="1.3.7"
      FRANKEN_URL="https://github.com/dunglas/frankenphp/releases/download/v${FRANKEN_VERSION}/frankenphp-linux-x86_64"
      curl -fsSL "$FRANKEN_URL" -o /usr/local/bin/frankenphp
      chmod +x /usr/local/bin/frankenphp
      success "FrankenPHP $(frankenphp version 2> /dev/null | head -1 || echo "installed")"
      sudo -u "$DEPLOY_USER" php "${APP_PATH}/artisan" octane:install --server=frankenphp --no-interaction 2> /dev/null || true
      ;;

    roadrunner)
      step "Installing RoadRunner..."
      sudo -u "$DEPLOY_USER" composer require spiral/roadrunner --working-dir="$APP_PATH" --no-interaction --quiet 2> /dev/null || true
      if [[ -f "${APP_PATH}/vendor/bin/rr" ]]; then
        "${APP_PATH}/vendor/bin/rr" get-binary > /dev/null 2>&1 || true
      fi
      sudo -u "$DEPLOY_USER" php "${APP_PATH}/artisan" octane:install --server=roadrunner --no-interaction 2> /dev/null || true
      ;;
  esac

  success "Octane installed (${OCTANE_DRIVER})."
fi

# Supervisor config
if [[ "$EXISTING_MODE" != "Skip"* ]]; then
  step "Creating Octane Supervisor configuration..."
  pkg_install supervisor 2> /dev/null || true

  cat > /etc/supervisor/conf.d/laravel-octane.conf << EOF
[program:laravel-octane]
process_name=%(program_name)s
command=/usr/bin/php${PHP_VERSION} ${APP_PATH}/artisan octane:start \
  --server=${OCTANE_DRIVER_LOWER} \
  --host=127.0.0.1 \
  --port=${OCTANE_PORT} \
  --workers=${OCTANE_WORKERS} \
  --task-workers=auto \
  --max-requests=500
autostart=true
autorestart=true
user=${DEPLOY_USER}
redirect_stderr=true
stdout_logfile=${APP_PATH}/storage/logs/octane.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
stopasgroup=true
killasgroup=true
stopwaitsecs=60
EOF

  supervisorctl reread > /dev/null
  supervisorctl update > /dev/null
  supervisorctl start laravel-octane 2> /dev/null || supervisorctl restart laravel-octane 2> /dev/null || true
  success "Octane Supervisor process configured."
fi

# Nginx proxy config
step "Generating Nginx proxy config for Octane..."

VHOST_FILE="/etc/nginx/sites-available/${APP_DOMAIN_INPUT}"
NGINX_ROOT="$(creds_load NGINX_ROOT 2> /dev/null || echo "/var/www/${APP_DOMAIN_INPUT}/current/public")"

# Write a new Octane-optimized vhost
OCTANE_VHOST="/etc/nginx/sites-available/${APP_DOMAIN_INPUT}-octane"
cat > "$OCTANE_VHOST" << NGINX
upstream octane {
    server 127.0.0.1:${OCTANE_PORT};
    keepalive 128;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${APP_DOMAIN_INPUT} www.${APP_DOMAIN_INPUT};
    root ${NGINX_ROOT};
    index index.php;

    charset utf-8;
    client_max_body_size 64m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    access_log /var/log/nginx/${APP_DOMAIN_INPUT}-access.log;
    error_log  /var/log/nginx/${APP_DOMAIN_INPUT}-error.log error;

    # Serve static files directly from disk
    location ~* \.(css|js|gif|ico|jpg|jpeg|png|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm|ogg|pdf)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # Proxy everything else to Octane
    location / {
        proxy_pass http://octane;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Scheme \$scheme;
        proxy_set_header SERVER_PORT \$server_port;
        proxy_set_header REMOTE_ADDR \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX

info "Octane Nginx config written to: ${OCTANE_VHOST}"
ask_yn ACTIVATE_OCTANE_VHOST "Activate Octane Nginx vhost now (replaces current vhost)?" "n"

if [[ "$ACTIVATE_OCTANE_VHOST" == "true" ]]; then
  # Remove old vhost symlink and link octane config
  rm -f "/etc/nginx/sites-enabled/${APP_DOMAIN_INPUT}"
  ln -sf "$OCTANE_VHOST" "/etc/nginx/sites-enabled/${APP_DOMAIN_INPUT}"
  nginx -t && systemctl reload nginx
  success "Octane Nginx vhost activated."
fi

# Save
creds_section "Octane"
creds_save "OCTANE_SERVER" "$OCTANE_DRIVER"
creds_save "OCTANE_PORT" "$OCTANE_PORT"
creds_save "OCTANE_WORKERS" "$OCTANE_WORKERS"
creds_save "OCTANE_NGINX_CONF" "$OCTANE_VHOST"
creds_save "OCTANE_SUPERVISOR_CONF" "/etc/supervisor/conf.d/laravel-octane.conf"

echo
success "Octane module complete."
info "Restart Octane after code changes:"
dim "supervisorctl restart laravel-octane"
dim "# Or via artisan: php artisan octane:reload"
