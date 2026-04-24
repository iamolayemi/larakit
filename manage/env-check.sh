#!/usr/bin/env bash
# =============================================================================
#  Manage — Env Check
#  Compare the app's .env against expected Laravel keys.
#  Run standalone: sudo bash manage/env-check.sh
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

module_header "Env Check" "Compare .env against expected keys — flag missing, empty, and extra entries."

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "/var/www/app")"
ask ENV_PATH "Path to .env file" "${APP_PATH}/.env"
[[ ! -f "$ENV_PATH" ]] && {
  error ".env not found at ${ENV_PATH}"
  exit 1
}

# Required keys for a production Laravel app
REQUIRED_KEYS=(
  APP_NAME APP_ENV APP_KEY APP_DEBUG APP_URL
  LOG_CHANNEL LOG_LEVEL
  DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD
  BROADCAST_CONNECTION CACHE_STORE FILESYSTEM_DISK QUEUE_CONNECTION
  SESSION_DRIVER SESSION_LIFETIME
  REDIS_HOST REDIS_PASSWORD REDIS_PORT
  MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_FROM_ADDRESS MAIL_FROM_NAME
)

section "Scanning: ${ENV_PATH}"
echo

# Read actual keys from .env
declare -A ENV_KEYS=()
while IFS='=' read -r key rest; do
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$key" ]] && continue
  key="${key%%[[:space:]]*}"
  [[ -z "$key" ]] && continue
  ENV_KEYS["$key"]="${rest:-}"
done < "$ENV_PATH"

missing=0 empty=0 ok=0

for key in "${REQUIRED_KEYS[@]}"; do
  if [[ -z "${ENV_KEYS[$key]+x}" ]]; then
    printf "  ${RED}${BOLD}MISSING${NC}  %s\n" "$key"
    missing=$((missing + 1))
  elif [[ -z "${ENV_KEYS[$key]}" ]]; then
    printf "  ${YELLOW}${BOLD}EMPTY  ${NC}  %s\n" "$key"
    empty=$((empty + 1))
  else
    printf "  ${GREEN}${BOLD}OK     ${NC}  %s\n" "$key"
    ok=$((ok + 1))
  fi
done

echo
divider
printf "\n  ${GREEN}OK: %d${NC}   ${YELLOW}Empty: %d${NC}   ${RED}Missing: %d${NC}\n\n" "$ok" "$empty" "$missing"

if [[ "$missing" -gt 0 || "$empty" -gt 0 ]]; then
  warn "Run 'larakit manage env' to rebuild .env from saved credentials."
else
  success "All required keys are present and non-empty."
fi
