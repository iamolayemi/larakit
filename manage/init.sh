#!/usr/bin/env bash
# =============================================================================
#  Manage — Init
#  Collect project credentials without installing anything.
#  Run standalone: sudo bash manage/init.sh
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
else
  # Called from larakit CLI or setup.sh — source libs from SETUP_BASE_DIR
  source "${SETUP_BASE_DIR}/lib/colors.sh"
  source "${SETUP_BASE_DIR}/lib/prompts.sh"
  source "${SETUP_BASE_DIR}/lib/creds.sh"
  source "${SETUP_BASE_DIR}/lib/utils.sh"
fi

module_header "LaraKit Init" "Collect project credentials — no packages installed"

section "Server"
server_ip=$(get_public_ip 2> /dev/null || hostname -I | awk '{print $1}')
info "Detected IP: ${server_ip}"
creds_save SERVER_IP "$server_ip"
creds_save SETUP_DATE "$(date '+%Y-%m-%d %H:%M:%S')"

section "App"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "/var/www/app")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
DEPLOY_BRANCH="$(creds_load DEPLOY_BRANCH 2> /dev/null || echo "main")"
GITHUB_REPO_URL="$(creds_load GITHUB_REPO_URL 2> /dev/null || echo "")"

ask APP_DOMAIN "Primary domain (e.g. example.com)" "$APP_DOMAIN"
ask APP_PATH "App directory" "$APP_PATH"
ask DEPLOY_USER "Deploy user" "$DEPLOY_USER"
ask DEPLOY_BRANCH "Deploy branch" "$DEPLOY_BRANCH"
ask GITHUB_REPO_URL "Git repository URL" "$GITHUB_REPO_URL"

creds_section "App"
creds_save APP_DOMAIN "$APP_DOMAIN"
creds_save APP_PATH "$APP_PATH"
creds_save DEPLOY_USER "$DEPLOY_USER"
creds_save DEPLOY_BRANCH "$DEPLOY_BRANCH"
creds_save GITHUB_REPO_URL "$GITHUB_REPO_URL"

section "PHP"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
ask_choice PHP_VERSION "PHP version" "8.4 (Latest)" "8.3 (Stable)" "8.2 (LTS)"
PHP_VERSION="${PHP_VERSION%% *}"
creds_section "PHP"
creds_save PHP_VERSION "$PHP_VERSION"

section "Database"
DB_DRIVER="$(creds_load DB_DRIVER 2> /dev/null || echo "")"
DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "laravel")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "laravel")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || gen_password 20)"
DB_PORT="$(creds_load DB_PORT 2> /dev/null || echo "3306")"

ask_choice DB_DRIVER "Database driver" "mysql" "mariadb" "postgres"
ask DB_NAME "Database name" "$DB_NAME"
ask DB_USER "Database user" "$DB_USER"
ask DB_PASSWORD "Database password" "$DB_PASSWORD"
ask DB_PORT "Database port" "$DB_PORT"

creds_section "Database"
creds_save DB_DRIVER "$DB_DRIVER"
creds_save DB_NAME "$DB_NAME"
creds_save DB_USER "$DB_USER"
creds_save DB_PASSWORD "$DB_PASSWORD"
creds_save DB_PORT "$DB_PORT"

section "Redis"
REDIS_PASSWORD="$(creds_load REDIS_PASSWORD 2> /dev/null || gen_password 20)"
REDIS_PORT="$(creds_load REDIS_PORT 2> /dev/null || echo "6379")"
ask REDIS_PASSWORD "Redis password" "$REDIS_PASSWORD"
ask REDIS_PORT "Redis port" "$REDIS_PORT"
creds_section "Redis"
creds_save REDIS_PASSWORD "$REDIS_PASSWORD"
creds_save REDIS_PORT "$REDIS_PORT"

section "Notifications (optional)"
echo -e "  ${DIM}Leave blank to skip.${NC}\n"
SLACK_URL="$(creds_load SLACK_WEBHOOK_URL 2> /dev/null || echo "")"
TG_TOKEN="$(creds_load TELEGRAM_BOT_TOKEN 2> /dev/null || echo "")"
TG_CHAT="$(creds_load TELEGRAM_CHAT_ID 2> /dev/null || echo "")"
DISCORD_URL="$(creds_load DISCORD_WEBHOOK_URL 2> /dev/null || echo "")"

ask SLACK_URL "Slack Webhook URL" "$SLACK_URL"
ask TG_TOKEN "Telegram Bot Token" "$TG_TOKEN"
ask TG_CHAT "Telegram Chat ID" "$TG_CHAT"
ask DISCORD_URL "Discord Webhook URL" "$DISCORD_URL"

[[ -n "$SLACK_URL" ]] && creds_save SLACK_WEBHOOK_URL "$SLACK_URL"
[[ -n "$TG_TOKEN" ]] && creds_save TELEGRAM_BOT_TOKEN "$TG_TOKEN"
[[ -n "$TG_CHAT" ]] && creds_save TELEGRAM_CHAT_ID "$TG_CHAT"
[[ -n "$DISCORD_URL" ]] && creds_save DISCORD_WEBHOOK_URL "$DISCORD_URL"

echo
success "Credentials saved to ${CREDS_FILE}"
echo -e "  ${DIM}Run 'larakit setup' to install your stack, or 'larakit install <module>' for a single component.${NC}"
echo
creds_show
