#!/usr/bin/env bash
# =============================================================================
#  Manage — Rollback
#  Roll back to a previous release.
#  Run standalone: sudo bash manage/rollback.sh
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

APP_ROOT="$(creds_load APP_ROOT 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_ROOT "App root directory" "${APP_ROOT:-/var/www/app}"

PHP_BIN="/usr/bin/php${PHP_VERSION}"

# Check if deployer-style (releases/ directory)
if [[ -d "${APP_ROOT}/releases" ]]; then
  info "Deployer-style releases detected."

  step "Available releases:"
  mapfile -t releases < <(ls -1t "${APP_ROOT}/releases/" 2> /dev/null)

  for i in "${!releases[@]}"; do
    CURRENT_RELEASE="$(basename "$(readlink "${APP_ROOT}/current" 2> /dev/null)")"
    suffix=""
    [[ "${releases[$i]}" == "$CURRENT_RELEASE" ]] && suffix=" ${GREEN}← current${NC}"
    printf "  ${BOLD}%2d)${NC} %s%b\n" "$((i + 1))" "${releases[$i]}" "$suffix"
  done

  if [[ "${#releases[@]}" -lt 2 ]]; then
    error "Only one release available. Cannot rollback."
    exit 1
  fi

  read -r -p "$(echo -e "  ${YELLOW}?${NC}  Roll back to release number: ")" choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#releases[@]}" ]]; then
    TARGET_RELEASE="${releases[$((choice - 1))]}"
  else
    error "Invalid selection."
    exit 1
  fi

  warn "Rolling back to: ${TARGET_RELEASE}"
  confirm_or_exit "Switch current symlink?"

  ln -sfn "${APP_ROOT}/releases/${TARGET_RELEASE}" "${APP_ROOT}/current"
  success "Switched to release: ${TARGET_RELEASE}"

else
  # Git-based rollback
  info "Git-based deployment detected."
  APP_PATH="${APP_ROOT}"

  step "Recent git commits:"
  sudo -u "$DEPLOY_USER" git -C "$APP_PATH" log --oneline -10 | nl -v0 | sed 's/^/  /'

  read -r -p "$(echo -e "  ${YELLOW}?${NC}  Roll back N commits (e.g. 1): ")" ROLLBACK_N
  [[ ! "$ROLLBACK_N" =~ ^[0-9]+$ ]] && {
    error "Invalid number."
    exit 1
  }

  ROLLBACK_TARGET="HEAD~${ROLLBACK_N}"
  warn "Rolling back ${ROLLBACK_N} commit(s) to: $(sudo -u "$DEPLOY_USER" git -C "$APP_PATH" rev-parse --short "$ROLLBACK_TARGET" 2> /dev/null)"
  confirm_or_exit "Reset hard to ${ROLLBACK_TARGET}?"

  sudo -u "$DEPLOY_USER" git -C "$APP_PATH" reset --hard "$ROLLBACK_TARGET"
  success "Rolled back to: $(sudo -u "$DEPLOY_USER" git -C "$APP_PATH" log --oneline -1)"
fi

# Post-rollback
step "Rebuilding caches..."
ARTISAN="${APP_ROOT}/current/artisan"
[[ ! -f "$ARTISAN" ]] && ARTISAN="${APP_ROOT}/artisan"

sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" config:cache --no-interaction 2> /dev/null || true
sudo -u "$DEPLOY_USER" "$PHP_BIN" "$ARTISAN" route:cache --no-interaction 2> /dev/null || true

step "Reloading PHP-FPM..."
systemctl reload "php${PHP_VERSION}-fpm" 2> /dev/null || true

if has_cmd supervisorctl; then
  supervisorctl restart "laravel-worker:*" 2> /dev/null || true
  supervisorctl restart "laravel-octane" 2> /dev/null || true
fi

success "Rollback complete."
