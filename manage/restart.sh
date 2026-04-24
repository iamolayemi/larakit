#!/usr/bin/env bash
# =============================================================================
#  Manage — Restart
#  Restart all Laravel-related services (PHP-FPM, Nginx, workers).
#  Run standalone: sudo bash manage/restart.sh
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

PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

restart_service() {
  local name="$1" service="$2"
  if systemctl is-active --quiet "$service" 2> /dev/null; then
    systemctl restart "$service" && success "Restarted: ${name}"
  else
    dim "Not running: ${name} — skipping"
  fi
}

supervisor_restart() {
  local prog="$1"
  if has_cmd supervisorctl && supervisorctl status "$prog" 2> /dev/null | grep -q RUNNING; then
    supervisorctl restart "$prog" && success "Restarted: ${prog}"
  else
    dim "Not running in Supervisor: ${prog} — skipping"
  fi
}

ask_yn RESTART_NGINX "Restart Nginx?" "y"
ask_yn RESTART_FPM "Restart PHP-FPM?" "y"
ask_yn RESTART_REDIS "Restart Redis?" "n"
ask_yn RESTART_WORKERS "Restart queue workers?" "y"
ask_yn RESTART_HORIZON "Restart Horizon?" "y"
ask_yn RESTART_OCTANE "Restart Octane?" "n"
ask_yn RESTART_REVERB "Restart Reverb?" "n"

echo
confirm_or_exit "Restart selected services?"

[[ "$RESTART_NGINX" == "true" ]] && restart_service "Nginx" "nginx"
[[ "$RESTART_FPM" == "true" ]] && restart_service "PHP-FPM" "php${PHP_VERSION}-fpm"
[[ "$RESTART_REDIS" == "true" ]] && restart_service "Redis" "redis"
[[ "$RESTART_WORKERS" == "true" ]] && supervisor_restart "laravel-worker"
[[ "$RESTART_HORIZON" == "true" ]] && supervisor_restart "laravel-horizon"
[[ "$RESTART_OCTANE" == "true" ]] && supervisor_restart "laravel-octane"
[[ "$RESTART_REVERB" == "true" ]] && supervisor_restart "laravel-reverb"

echo
success "All selected services restarted."
