#!/usr/bin/env bash
# =============================================================================
#  Module 04 — Nginx Web Server & Virtual Host
#  Run standalone: sudo bash modules/04-nginx.sh
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

module_header "Nginx Web Server" "Installs Nginx, generates a production-ready Laravel vhost."
require_root

# Nginx version
ask_choice NGINX_SOURCE "Nginx source:" \
  "Ubuntu/Debian repo (stable)" \
  "Nginx mainline repo (latest features)" \
  "Nginx stable repo (latest stable)"

# App config
ask APP_DOMAIN "Application domain (e.g. app.example.com)" ""
[[ -z "$APP_DOMAIN" ]] && {
  error "Domain cannot be empty."
  exit 1
}

ask_yn HAS_WWW "Also serve www.${APP_DOMAIN}?" "y"
SERVER_NAME="$APP_DOMAIN"
[[ "$HAS_WWW" == "true" ]] && SERVER_NAME="${APP_DOMAIN} www.${APP_DOMAIN}"

# Detect PHP version from saved creds or ask
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "")"
if [[ -z "$PHP_VERSION" ]]; then
  ask_choice PHP_VERSION "PHP version (must match installed version):" \
    "8.5" "8.4" "8.3" "8.2"
  PHP_VERSION="${PHP_VERSION%% *}"
fi

ask_choice DEPLOY_STYLE "Deployment style:" \
  "Deployer (zero-downtime — uses /current symlink)" \
  "Direct (simple, no zero-downtime)"

DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
ask DEPLOY_USER "Deploy user that owns app files" "$DEPLOY_USER"

ask APP_ROOT "App root directory" "/var/www/${APP_DOMAIN}"

if [[ "$DEPLOY_STYLE" == Deployer* ]]; then
  NGINX_ROOT="${APP_ROOT}/current/public"
else
  NGINX_ROOT="${APP_ROOT}/public"
fi

ask_yn ENABLE_GZIP "Enable gzip compression?" "y"
ask_yn ENABLE_RATE_LIMIT "Enable rate limiting (login/api routes)?" "y"
ask MAX_BODY_SIZE "Max upload size (client_max_body_size)" "64m"

echo
info "Configuration:"
dim "Domain:    ${SERVER_NAME}"
dim "Root:      ${NGINX_ROOT}"
dim "PHP sock:  /run/php/php${PHP_VERSION}-fpm.sock"
dim "App dir:   ${APP_ROOT}"
echo
confirm_or_exit "Install Nginx and create vhost?"

# Install Nginx
step "Installing Nginx..."

if [[ "$NGINX_SOURCE" == "Nginx mainline"* ]]; then
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/nginx.gpg
  echo "deb http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
  apt-get update -qq
elif [[ "$NGINX_SOURCE" == "Nginx stable"* ]]; then
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/nginx.gpg
  echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
  apt-get update -qq
fi

pkg_install nginx
systemctl enable nginx --quiet
success "Nginx installed: $(nginx -v 2>&1 | awk -F'/' '{print $2}')"

# Create app directory
step "Creating app directory ${APP_ROOT}..."
mkdir -p "$APP_ROOT"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_ROOT"
setfacl -R -m u:www-data:rwx "$APP_ROOT" 2> /dev/null || chmod -R 775 "$APP_ROOT"

# Rate limiting map
RATE_LIMIT_BLOCK=""
if [[ "$ENABLE_RATE_LIMIT" == "true" ]]; then
  cat > /etc/nginx/conf.d/rate-limit.conf << EOF
limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone \$binary_remote_addr zone=api:10m rate=60r/m;
EOF
  RATE_LIMIT_BLOCK='
    location ~ ^/(login|register|password) {
        limit_req zone=login burst=3 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        try_files $uri $uri/ /index.php?$query_string;
    }'
fi

# Gzip block
GZIP_BLOCK=""
if [[ "$ENABLE_GZIP" == "true" ]]; then
  GZIP_BLOCK="
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_vary on;
    gzip_types application/javascript application/json application/xml text/css text/plain text/xml;"
fi

# Write vhost
VHOST_FILE="/etc/nginx/sites-available/${APP_DOMAIN}"
step "Writing vhost: ${VHOST_FILE}..."

cat > "$VHOST_FILE" << NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};
    root ${NGINX_ROOT};
    index index.php;

    charset utf-8;
    client_max_body_size ${MAX_BODY_SIZE};

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    ${GZIP_BLOCK}

    # Logs
    access_log /var/log/nginx/${APP_DOMAIN}-access.log;
    error_log  /var/log/nginx/${APP_DOMAIN}-error.log error;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    ${RATE_LIMIT_BLOCK}

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX

# Enable site
ln -sf "/etc/nginx/sites-available/${APP_DOMAIN}" "/etc/nginx/sites-enabled/${APP_DOMAIN}" 2> /dev/null || true
rm -f /etc/nginx/sites-enabled/default 2> /dev/null || true

nginx -t && systemctl reload nginx
success "Vhost created and enabled: ${APP_DOMAIN}"

# Save
creds_section "Nginx"
creds_save "APP_DOMAIN" "$APP_DOMAIN"
creds_save "APP_ROOT" "$APP_ROOT"
creds_save "NGINX_ROOT" "$NGINX_ROOT"
creds_save "NGINX_VHOST" "$VHOST_FILE"

success "Nginx module complete."
