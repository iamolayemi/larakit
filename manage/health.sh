#!/usr/bin/env bash
# =============================================================================
#  Manage — Health
#  Check service status and versions across the full stack.
#  Run standalone: sudo bash manage/health.sh
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

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

check_service() {
  local name="$1" service="$2"
  if systemctl is-active --quiet "$service" 2> /dev/null; then
    printf "  ${GREEN}${BOLD}✔${NC}  %-25s ${GREEN}running${NC}\n" "$name"
  else
    printf "  ${RED}${BOLD}✘${NC}  %-25s ${RED}stopped${NC}\n" "$name"
  fi
}

check_cmd() {
  local name="$1" cmd="$2"
  if has_cmd "$cmd"; then
    local ver
    ver=$($cmd --version 2> /dev/null | head -1) || ver="installed"
    printf "  ${GREEN}${BOLD}✔${NC}  %-25s ${DIM}%s${NC}\n" "$name" "$ver"
  else
    printf "  ${YELLOW}${BOLD}—${NC}  %-25s ${DIM}not installed${NC}\n" "$name"
  fi
}

check_port() {
  local name="$1" port="$2"
  if ss -tlnp 2> /dev/null | grep -q ":${port} " || netstat -tlnp 2> /dev/null | grep -q ":${port} "; then
    printf "  ${GREEN}${BOLD}✔${NC}  %-25s ${GREEN}listening on :${port}${NC}\n" "$name"
  else
    printf "  ${RED}${BOLD}✘${NC}  %-25s ${RED}not listening on :${port}${NC}\n" "$name"
  fi
}

echo -e "\n  ${BOLD}Service Status${NC}"
divider
check_service "Nginx" "nginx"
check_service "PHP-FPM" "php${PHP_VERSION}-fpm"
check_service "MySQL" "mysql"
check_service "MariaDB" "mariadb"
check_service "PostgreSQL" "postgresql"
check_service "Redis" "redis"
check_service "Supervisor" "supervisor"
check_service "Fail2ban" "fail2ban"
check_service "Certbot timer" "certbot.timer"
check_service "Cron" "cron"

echo -e "\n  ${BOLD}Installed Tools${NC}"
divider
check_cmd "PHP" "php"
check_cmd "Composer" "composer"
check_cmd "Node.js" "node"
check_cmd "NPM" "npm"
check_cmd "Redis CLI" "redis-cli"
check_cmd "MySQL CLI" "mysql"
check_cmd "psql" "psql"
check_cmd "Certbot" "certbot"

echo -e "\n  ${BOLD}Network & Ports${NC}"
divider
check_port "HTTP  (80)" 80
check_port "HTTPS (443)" 443
check_port "MySQL (3306)" 3306
check_port "Redis (6379)" 6379
check_port "PG    (5432)" 5432

echo -e "\n  ${BOLD}Disk & Memory${NC}"
divider
df -h / | awk 'NR==2 {printf "  Disk:   %s used of %s (%s)\n", $3, $2, $5}'
free -h | awk '/^Mem:/ {printf "  RAM:    %s used of %s\n", $3, $2}'
free -h | awk '/^Swap:/ {printf "  Swap:   %s used of %s\n", $3, $2}'

if [[ -n "$APP_PATH" ]]; then
  echo -e "\n  ${BOLD}Laravel App${NC}"
  divider
  if [[ -f "${APP_PATH}/artisan" ]]; then
    php "${APP_PATH}/artisan" about --only=environment 2> /dev/null | head -10 | sed 's/^/  /' || true
    echo
    FAILED=$(php "${APP_PATH}/artisan" queue:failed --count 2> /dev/null | grep -oP '\d+' | head -1 || echo "?")
    echo -e "  Failed queue jobs: ${FAILED}"
  else
    warn "  Artisan not found at ${APP_PATH}/artisan"
  fi
fi

echo -e "\n  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
