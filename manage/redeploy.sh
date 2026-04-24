#!/usr/bin/env bash
# =============================================================================
#  Manage — Redeploy
#  Full redeploy with maintenance mode and optional npm build.
#  Run standalone: sudo bash manage/redeploy.sh
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
  _src notify.sh
  export SETUP_LOADED=1
fi

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
DEPLOY_BRANCH="$(creds_load DEPLOY_BRANCH 2> /dev/null || echo "main")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_PATH "App path" "${APP_PATH:-/var/www/app/current}"
ask DEPLOY_USER "Deploy user" "$DEPLOY_USER"
ask DEPLOY_BRANCH "Branch" "$DEPLOY_BRANCH"
ask_yn BUILD_ASSETS "Build frontend assets (npm run build)?" "n"
ask_yn SEED_DB "Run database seeders?" "n"
ask_yn USE_MAINTENANCE "Enable maintenance mode during deploy?" "y"

echo
warn "This will run a full redeploy. Traffic will be interrupted briefly."
confirm_or_exit "Proceed with full redeploy?"

notify_deploy start "Full redeploy started — branch: ${DEPLOY_BRANCH}"
trap 'notify_deploy failure "Full redeploy FAILED — branch: ${DEPLOY_BRANCH}"' ERR

PHP_BIN="/usr/bin/php${PHP_VERSION}"
ARTISAN="${APP_PATH}/artisan"

# Maintenance mode on
if [[ "$USE_MAINTENANCE" == "true" ]]; then
  step "Enabling maintenance mode..."
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" down --retry=60 --no-interaction 2> /dev/null || true
fi

deploy_cleanup() {
  # Always bring app back up on exit
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" up --no-interaction 2> /dev/null || true
}
[[ "$USE_MAINTENANCE" == "true" ]] && trap deploy_cleanup EXIT

step "Pulling code..."
sudo -u "$DEPLOY_USER" git -C "$APP_PATH" fetch --all
sudo -u "$DEPLOY_USER" git -C "$APP_PATH" reset --hard "origin/${DEPLOY_BRANCH}"

step "Installing Composer dependencies..."
sudo -u "$DEPLOY_USER" composer install \
  --working-dir="$APP_PATH" \
  --no-dev --optimize-autoloader --no-interaction --quiet

if [[ "$BUILD_ASSETS" == "true" ]]; then
  step "Building frontend assets..."
  sudo -u "$DEPLOY_USER" bash -c "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ${APP_PATH}
    npm ci --quiet && npm run build
  "
  success "Assets built."
fi

step "Running migrations..."
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" migrate --force --no-interaction

[[ "$SEED_DB" == "true" ]] && sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" db:seed --force --no-interaction

step "Rebuilding caches..."
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" optimize:clear --no-interaction 2> /dev/null || {
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" config:clear --no-interaction 2> /dev/null || true
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" route:clear --no-interaction 2> /dev/null || true
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" view:clear --no-interaction 2> /dev/null || true
}
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" config:cache --no-interaction
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" route:cache --no-interaction
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" view:cache --no-interaction

step "Reloading PHP-FPM..."
systemctl reload "php${PHP_VERSION}-fpm" 2> /dev/null || true

step "Restarting workers..."
if has_cmd supervisorctl; then
  supervisorctl restart "laravel-worker:*" 2> /dev/null || true
  supervisorctl restart "laravel-horizon" 2> /dev/null || true
  supervisorctl restart "laravel-octane" 2> /dev/null || true
fi

# Maintenance off (also called by trap)
if [[ "$USE_MAINTENANCE" == "true" ]]; then
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" up --no-interaction 2> /dev/null || true
  trap - EXIT
fi

notify_deploy success "Full redeploy complete — branch: ${DEPLOY_BRANCH}"

DEPLOY_HOOK="$(creds_load DEPLOY_HOOK 2> /dev/null || echo "")"
if [[ -n "$DEPLOY_HOOK" ]]; then
  step "Running post-deploy hook..."
  eval "$DEPLOY_HOOK" && success "Post-deploy hook complete." || warn "Post-deploy hook finished with errors."
fi

echo
success "Full redeploy complete at $(date '+%H:%M:%S')."
