#!/usr/bin/env bash
# =============================================================================
#  Manage — App Create
#  Scaffold a new Laravel application on this server — directory, Nginx vhost,
#  database, deploy user permissions, and .env skeleton.
#  Run standalone: sudo bash manage/app-create.sh
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

manage_header "App Create" "Scaffold a new Laravel app — directory, Nginx vhost, database, .env skeleton."
require_root

PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"

ask NEW_APP_DOMAIN "New app domain (e.g. api.example.com)" ""
ask NEW_APP_PATH "App root directory" "/var/www/${NEW_APP_DOMAIN}"
ask NEW_APP_DB_NAME "Database name" "${NEW_APP_DOMAIN//./_}"
ask NEW_APP_DB_USER "Database username" "${NEW_APP_DB_NAME:0:16}"

NEW_APP_DB_PASS="$(gen_password 24)"
warn "Generated DB password: ${NEW_APP_DB_PASS}"
ask_yn USE_GEN_PASS "Use this generated password?" "y"
[[ "$USE_GEN_PASS" != "true" ]] && ask_secret NEW_APP_DB_PASS "Database password"

ask_yn CREATE_NGINX_VHOST "Create Nginx vhost for ${NEW_APP_DOMAIN}?" "y"
ask_yn CREATE_DATABASE "Create database ${NEW_APP_DB_NAME}?" "y"
ask_yn REQUEST_SSL "Request SSL certificate via Certbot after vhost creation?" "y"

echo
info "Will create:"
dim "  App path:   ${NEW_APP_PATH}"
dim "  Nginx vhost: /etc/nginx/sites-available/${NEW_APP_DOMAIN}"
dim "  Database:    ${NEW_APP_DB_NAME} (user: ${NEW_APP_DB_USER})"
echo
confirm_or_exit "Create new app scaffold?"

# --- Directory ---
step "Creating app directory..."
mkdir -p "${NEW_APP_PATH}"/{public,storage/{app/public,framework/{cache,sessions,views},logs},bootstrap/cache}
chown -R "${DEPLOY_USER}:www-data" "${NEW_APP_PATH}"
chmod -R 755 "${NEW_APP_PATH}"
chmod -R 775 "${NEW_APP_PATH}/storage" "${NEW_APP_PATH}/bootstrap/cache"
success "Directory created: ${NEW_APP_PATH}"

# --- Nginx vhost ---
if [[ "$CREATE_NGINX_VHOST" == "true" ]]; then
  step "Writing Nginx vhost..."
  VHOST_FILE="/etc/nginx/sites-available/${NEW_APP_DOMAIN}"
  cat > "$VHOST_FILE" << NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${NEW_APP_DOMAIN};
    root ${NEW_APP_PATH}/public;
    index index.php;

    access_log /var/log/nginx/${NEW_APP_DOMAIN}-access.log;
    error_log  /var/log/nginx/${NEW_APP_DOMAIN}-error.log;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX
  ln -sf "$VHOST_FILE" "/etc/nginx/sites-enabled/${NEW_APP_DOMAIN}" 2> /dev/null || true
  nginx -t && systemctl reload nginx
  success "Nginx vhost created: ${VHOST_FILE}"
fi

# --- Database ---
if [[ "$CREATE_DATABASE" == "true" ]]; then
  DB_CONNECTION="$(creds_load DB_CONNECTION 2> /dev/null || echo "mysql")"
  DB_SERVICE="$(creds_load DB_SERVICE 2> /dev/null || echo "mysql")"

  if [[ "$DB_CONNECTION" == "pgsql" ]]; then
    step "Creating PostgreSQL database and user..."
    DB_PORT="$(creds_load DB_PORT 2> /dev/null || echo "5432")"
    sudo -u postgres psql -p "$DB_PORT" << PGSQL 2> /dev/null
CREATE USER "${NEW_APP_DB_USER}" WITH PASSWORD '${NEW_APP_DB_PASS}';
CREATE DATABASE "${NEW_APP_DB_NAME}" OWNER "${NEW_APP_DB_USER}" ENCODING 'UTF8' TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE "${NEW_APP_DB_NAME}" TO "${NEW_APP_DB_USER}";
PGSQL
    success "PostgreSQL database '${NEW_APP_DB_NAME}' created."
  else
    step "Creating MySQL/MariaDB database and user..."
    DB_ROOT_PASS="$(creds_load DB_ROOT_PASSWORD 2> /dev/null || echo "")"
    MYSQL_CMD="mysql -u root"
    [[ -n "$DB_ROOT_PASS" ]] && MYSQL_CMD="mysql -u root -p${DB_ROOT_PASS}"

    $MYSQL_CMD << MYSQL 2> /dev/null
CREATE DATABASE IF NOT EXISTS \`${NEW_APP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${NEW_APP_DB_USER}'@'localhost' IDENTIFIED BY '${NEW_APP_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${NEW_APP_DB_NAME}\`.* TO '${NEW_APP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL
    success "MySQL database '${NEW_APP_DB_NAME}' created."
  fi
fi

# --- .env skeleton ---
step "Writing .env skeleton..."
APP_KEY="base64:$(openssl rand -base64 32)"
cat > "${NEW_APP_PATH}/.env" << ENV
APP_NAME="Laravel"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=http://${NEW_APP_DOMAIN}

LOG_CHANNEL=stack
LOG_LEVEL=error

DB_CONNECTION=${DB_CONNECTION:-mysql}
DB_HOST=127.0.0.1
DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${NEW_APP_DB_NAME}
DB_USERNAME=${NEW_APP_DB_USER}
DB_PASSWORD=${NEW_APP_DB_PASS}

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
ENV
chown "${DEPLOY_USER}:www-data" "${NEW_APP_PATH}/.env"
chmod 640 "${NEW_APP_PATH}/.env"
success ".env skeleton written to ${NEW_APP_PATH}/.env"

# --- SSL ---
if [[ "$REQUEST_SSL" == "true" ]] && has_cmd certbot; then
  step "Requesting SSL certificate for ${NEW_APP_DOMAIN}..."
  certbot --nginx -d "$NEW_APP_DOMAIN" --non-interactive --agree-tos \
    --email "$(creds_load ADMIN_EMAIL 2> /dev/null || echo "admin@${NEW_APP_DOMAIN}")" \
    --redirect 2> /dev/null && success "SSL certificate issued." \
    || warn "Certbot failed — ensure DNS for ${NEW_APP_DOMAIN} points here and port 80 is open."
fi

echo
success "App scaffold complete."
info "Next steps:"
dim "  1. Deploy your Laravel code to: ${NEW_APP_PATH}"
dim "  2. Run: php artisan migrate --force"
dim "  3. Run: php artisan storage:link"
dim "  4. Run: php artisan optimize"
