#!/usr/bin/env bash
# =============================================================================
#  Module — Laravel Application Deployment
#  Clones the repo, configures .env, runs migrations, sets permissions
#  Run standalone: sudo bash modules/laravel-app.sh
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

module_header "Laravel Application Deployment" "Clone, configure, migrate, and set up your Laravel app."
require_root

# Load saved values
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
APP_ROOT="$(creds_load APP_ROOT 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"
REDIS_HOST="$(creds_load REDIS_HOST 2> /dev/null || echo "127.0.0.1")"
REDIS_PORT="$(creds_load REDIS_PORT 2> /dev/null || echo "6379")"
REDIS_PASSWORD="$(creds_load REDIS_PASSWORD 2> /dev/null || echo "")"

# User inputs
ask APP_ROOT "Application root directory" "${APP_ROOT:-/var/www/${APP_DOMAIN}}"
ask GIT_REPO "Git repository URL (SSH or HTTPS)" ""
[[ -z "$GIT_REPO" ]] && {
  error "Git repository URL is required."
  exit 1
}

ask_choice DEPLOY_BRANCH "Deployment branch:" \
  "main" \
  "master" \
  "production" \
  "staging"

ask_choice DEPLOY_STYLE "Deployment structure:" \
  "Direct (clone directly to app root)" \
  "Deployer-style (releases + current symlink)"

ask APP_NAME "Application name (APP_NAME)" "${APP_DOMAIN:-Laravel App}"
ask APP_URL "Application URL" "https://${APP_DOMAIN:-localhost}"
ask APP_ENV "Application environment" "production"

# DB settings
ask DB_HOST "DB Host" "127.0.0.1"
ask DB_PORT "DB Port" "3306"
ask DB_DATABASE "DB Name" "${DB_NAME:-}"
ask DB_USERNAME "DB User" "${DB_USER:-}"
ask_secret DB_PASSWORD_INPUT "DB Password (leave blank to use saved)"
[[ -n "$DB_PASSWORD_INPUT" ]] && DB_PASSWORD="$DB_PASSWORD_INPUT"

ask_yn RUN_MIGRATIONS "Run migrations after deployment?" "y"
ask_yn RUN_SEEDERS "Run database seeders?" "n"
ask_yn CACHE_CONFIG "Cache config, routes, and views after deploy?" "y"
ask_yn SETUP_STORAGE_LINK "Create storage symlink?" "y"
ask_yn INSTALL_NPM_ASSETS "Build frontend assets (npm run build)?" "n"

echo
confirm_or_exit "Deploy Laravel application?"

# Prepare directory
step "Preparing application directory..."
mkdir -p "$APP_ROOT"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_ROOT"

# Clone repository
if [[ "$DEPLOY_STYLE" == "Direct"* ]]; then
  DEPLOY_PATH="$APP_ROOT"
else
  DEPLOY_PATH="${APP_ROOT}/releases/initial"
  mkdir -p "$DEPLOY_PATH"
  mkdir -p "${APP_ROOT}/shared/storage"
fi

step "Cloning repository..."
if [[ -d "${DEPLOY_PATH}/.git" ]]; then
  warn "Repository already exists. Pulling latest..."
  sudo -u "$DEPLOY_USER" git -C "$DEPLOY_PATH" pull origin "$DEPLOY_BRANCH"
else
  sudo -u "$DEPLOY_USER" git clone --branch "$DEPLOY_BRANCH" --depth 1 "$GIT_REPO" "$DEPLOY_PATH"
fi
success "Repository cloned."

# Setup shared storage (Deployer-style)
if [[ "$DEPLOY_STYLE" == "Deployer"* ]]; then
  step "Setting up shared directories..."
  # Move storage to shared if it exists
  if [[ -d "${DEPLOY_PATH}/storage" ]] && [[ ! -d "${APP_ROOT}/shared/storage/app" ]]; then
    cp -r "${DEPLOY_PATH}/storage/." "${APP_ROOT}/shared/storage/"
  fi
  rm -rf "${DEPLOY_PATH}/storage"
  ln -sf "${APP_ROOT}/shared/storage" "${DEPLOY_PATH}/storage"

  # .env is shared too
  touch "${APP_ROOT}/shared/.env"
  ln -sf "${APP_ROOT}/shared/.env" "${DEPLOY_PATH}/.env"

  # current symlink
  ln -sfn "$DEPLOY_PATH" "${APP_ROOT}/current"
  APP_PATH="${APP_ROOT}/current"
else
  APP_PATH="$DEPLOY_PATH"
fi

# Configure .env
step "Configuring .env..."
ENV_FILE="${APP_PATH}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "${APP_PATH}/.env.example" "$ENV_FILE" 2> /dev/null || cat > "$ENV_FILE" << 'BLANK'
APP_NAME=
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=
DB_USERNAME=
DB_PASSWORD=

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
BLANK
fi

set_env_value "APP_NAME" "\"${APP_NAME}\"" "$ENV_FILE"
set_env_value "APP_ENV" "$APP_ENV" "$ENV_FILE"
set_env_value "APP_DEBUG" "false" "$ENV_FILE"
set_env_value "APP_URL" "$APP_URL" "$ENV_FILE"
set_env_value "DB_HOST" "$DB_HOST" "$ENV_FILE"
set_env_value "DB_PORT" "$DB_PORT" "$ENV_FILE"
set_env_value "DB_DATABASE" "$DB_DATABASE" "$ENV_FILE"
set_env_value "DB_USERNAME" "$DB_USERNAME" "$ENV_FILE"
set_env_value "DB_PASSWORD" "$DB_PASSWORD" "$ENV_FILE"
set_env_value "REDIS_HOST" "$REDIS_HOST" "$ENV_FILE"
set_env_value "REDIS_PORT" "$REDIS_PORT" "$ENV_FILE"
set_env_value "REDIS_PASSWORD" "${REDIS_PASSWORD:-null}" "$ENV_FILE"

# Composer install
step "Installing Composer dependencies..."
sudo -u "$DEPLOY_USER" composer install \
  --working-dir="$APP_PATH" \
  --no-dev \
  --optimize-autoloader \
  --no-interaction \
  --quiet
success "Composer dependencies installed."

# Generate app key
step "Generating application key..."
APP_KEY=$(sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" key:generate --show --no-interaction 2> /dev/null)
set_env_value "APP_KEY" "$APP_KEY" "$ENV_FILE"
success "Application key generated."

# Migrations
if [[ "$RUN_MIGRATIONS" == "true" ]]; then
  step "Running migrations..."
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" migrate --force --no-interaction
  success "Migrations complete."
fi

if [[ "$RUN_SEEDERS" == "true" ]]; then
  step "Running seeders..."
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" db:seed --force --no-interaction
  success "Seeders complete."
fi

# Storage link
if [[ "$SETUP_STORAGE_LINK" == "true" ]]; then
  step "Creating storage symlink..."
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" storage:link --no-interaction 2> /dev/null || true
  success "Storage link created."
fi

# Cache
if [[ "$CACHE_CONFIG" == "true" ]]; then
  step "Caching config, routes, and views..."
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" config:cache --no-interaction
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" route:cache --no-interaction
  sudo -u "$DEPLOY_USER" php "$APP_PATH/artisan" view:cache --no-interaction
  success "Caches warmed."
fi

# Frontend assets
if [[ "$INSTALL_NPM_ASSETS" == "true" ]]; then
  step "Building frontend assets..."
  # Source NVM for the deploy user
  sudo -u "$DEPLOY_USER" bash -c "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ${APP_PATH}
    npm ci --quiet && npm run build
  "
  success "Frontend assets built."
fi

# Permissions
step "Setting permissions..."
chown -R "${DEPLOY_USER}:www-data" "$APP_PATH"
find "$APP_PATH" -type f -exec chmod 644 {} \;
find "$APP_PATH" -type d -exec chmod 755 {} \;
chmod -R 775 "${APP_PATH}/storage" "${APP_PATH}/bootstrap/cache" 2> /dev/null || true
success "Permissions set."

# Save
creds_section "Laravel App"
creds_save "APP_NAME" "$APP_NAME"
creds_save "APP_URL" "$APP_URL"
creds_save "APP_PATH" "$APP_PATH"
creds_save "APP_KEY" "$APP_KEY"
creds_save "GIT_REPO" "$GIT_REPO"
creds_save "DEPLOY_BRANCH" "$DEPLOY_BRANCH"

echo
success "Laravel application deployed!"
info "App path: ${APP_PATH}"
