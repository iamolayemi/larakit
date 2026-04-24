#!/usr/bin/env bash
# =============================================================================
#  Manage — Cache Clear
#  Clear all application caches: config, route, view, events, OPcache, Redis.
#  Run standalone: sudo bash manage/cache-clear.sh
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

manage_header "Cache Clear" "Flush all caches for the Laravel application."

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"
PHP_BIN="/usr/bin/php${PHP_VERSION}"
[[ ! -x "$PHP_BIN" ]] && PHP_BIN="$(command -v php)"

ask_yn CLEAR_OPCACHE "Clear OPcache (requires PHP-FPM restart)?" "y"
ask_yn CLEAR_REDIS "Flush Redis cache database?" "n"

echo
confirm_or_exit "Clear all caches now?"

# Laravel artisan cache clears
step "Clearing Laravel caches..."
declare -a ARTISAN_CMDS=(
  "optimize:clear"
  "view:clear"
  "event:clear"
)
for cmd in "${ARTISAN_CMDS[@]}"; do
  if sudo -u "$(stat -c '%U' "$APP_PATH")" "$PHP_BIN" "${APP_PATH}/artisan" "$cmd" --no-interaction 2> /dev/null; then
    success "php artisan ${cmd}"
  else
    warn "php artisan ${cmd} failed (skipped)"
  fi
done

# OPcache
if [[ "$CLEAR_OPCACHE" == "true" ]]; then
  step "Restarting PHP-FPM to clear OPcache..."
  PHP_VERSION_LOADED="$(creds_load PHP_VERSION 2> /dev/null || echo "$PHP_VERSION")"
  systemctl restart "php${PHP_VERSION_LOADED}-fpm" 2> /dev/null \
    || systemctl restart php-fpm 2> /dev/null \
    || warn "Could not restart PHP-FPM — clear OPcache manually."
  success "OPcache cleared via PHP-FPM restart."
fi

# Redis
if [[ "$CLEAR_REDIS" == "true" ]]; then
  step "Flushing Redis cache..."
  REDIS_DB="$(creds_load REDIS_CACHE_DB 2> /dev/null || echo "1")"
  if has_cmd redis-cli; then
    redis-cli -n "$REDIS_DB" FLUSHDB > /dev/null && success "Redis database ${REDIS_DB} flushed."
  else
    warn "redis-cli not found — skipping Redis flush."
  fi
fi

echo
success "Cache clear complete."
