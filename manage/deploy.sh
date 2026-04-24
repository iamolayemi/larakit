#!/usr/bin/env bash
# =============================================================================
#  Manage — Deploy
#  Deploy latest code — pull, migrate, cache, and restart.
#  Run standalone: sudo bash manage/deploy.sh
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

ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"
ask DEPLOY_USER "Deploy user" "$DEPLOY_USER"
ask DEPLOY_BRANCH "Branch to pull" "$DEPLOY_BRANCH"

ask_choice DEPLOY_STEPS "What to run after pulling?" \
  "Full redeploy (composer, migrate, caches, restart)" \
  "Quick (pull + caches only)" \
  "Pull only"

echo
confirm_or_exit "Deploy from branch ${DEPLOY_BRANCH}?"

notify_deploy start "Deploy started — branch: ${DEPLOY_BRANCH} (${DEPLOY_STEPS})"
trap 'notify_deploy failure "Deploy FAILED — branch: ${DEPLOY_BRANCH}"' ERR

PHP_BIN="/usr/bin/php${PHP_VERSION}"
ARTISAN="${APP_PATH}/artisan"

step "Pulling latest code (${DEPLOY_BRANCH})..."
sudo -u "$DEPLOY_USER" git -C "$APP_PATH" fetch --all
sudo -u "$DEPLOY_USER" git -C "$APP_PATH" reset --hard "origin/${DEPLOY_BRANCH}"
success "Code updated."

if [[ "$DEPLOY_STEPS" == "Pull only" ]]; then
  notify_deploy success "Deploy complete (pull only) — branch: ${DEPLOY_BRANCH}"
  success "Deploy complete (pull only)."
  exit 0
fi

if [[ "$DEPLOY_STEPS" == "Full redeploy"* ]]; then
  step "Installing Composer dependencies..."
  sudo -u "$DEPLOY_USER" composer install \
    --working-dir="$APP_PATH" \
    --no-dev --optimize-autoloader --no-interaction --quiet
  success "Composer done."

  step "Running migrations..."
  sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" migrate --force --no-interaction
  success "Migrations done."
fi

step "Clearing and rebuilding caches..."
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" config:clear --no-interaction 2> /dev/null || true
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" route:clear --no-interaction 2> /dev/null || true
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" view:clear --no-interaction 2> /dev/null || true
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" config:cache --no-interaction
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" route:cache --no-interaction
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" view:cache --no-interaction
success "Caches rebuilt."

if [[ "$DEPLOY_STEPS" == "Full redeploy"* ]]; then
  step "Restarting services..."
  systemctl restart "php${PHP_VERSION}-fpm" 2> /dev/null && success "PHP-FPM restarted." || true

  if has_cmd supervisorctl; then
    supervisorctl restart "laravel-worker:*" 2> /dev/null && success "Queue workers restarted." || true
    supervisorctl restart "laravel-horizon" 2> /dev/null && success "Horizon restarted." || true
    supervisorctl restart "laravel-octane" 2> /dev/null && success "Octane restarted." || true
  fi
fi

notify_deploy success "Deploy complete — branch: ${DEPLOY_BRANCH}"

DEPLOY_HOOK="$(creds_load DEPLOY_HOOK 2> /dev/null || echo "")"
if [[ -n "$DEPLOY_HOOK" ]]; then
  step "Running post-deploy hook..."
  eval "$DEPLOY_HOOK" && success "Post-deploy hook complete." || warn "Post-deploy hook finished with errors."
fi

echo
success "Deploy complete at $(date '+%H:%M:%S')."
