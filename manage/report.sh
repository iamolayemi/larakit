#!/usr/bin/env bash
# =============================================================================
#  Manage — Report
#  Full server stack report — services, versions, URLs, ports.
#  Run standalone: sudo bash manage/report.sh
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
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "")"
SERVER_IP="$(creds_load SERVER_IP 2> /dev/null || get_public_ip 2> /dev/null || hostname -I | awk '{print $1}')"
SETUP_DATE="$(creds_load SETUP_DATE 2> /dev/null || echo "unknown")"

row() {
  local label="$1" value="$2" color="${3:-$NC}"
  printf "  ${BOLD}%-30s${NC} ${color}%s${NC}\n" "$label" "$value"
}

row_check() {
  local label="$1" cmd="$2"
  if has_cmd "$cmd"; then
    local ver
    ver=$($cmd --version 2> /dev/null | head -1 | sed 's/^[^0-9]*//' | awk '{print $1}') || ver="installed"
    row "$label" "$ver" "$GREEN"
  else
    row "$label" "not installed" "$DIM"
  fi
}

service_status() {
  local label="$1" service="$2" extra="${3:-}"
  if systemctl is-active --quiet "$service" 2> /dev/null; then
    printf "  ${GREEN}${BOLD}●${NC}  ${BOLD}%-28s${NC} ${GREEN}running${NC}" "$label"
    [[ -n "$extra" ]] && printf "  ${DIM}%s${NC}" "$extra"
    echo
  else
    printf "  ${DIM}○${NC}  ${BOLD}%-28s${NC} ${DIM}stopped / not installed${NC}\n" "$label"
  fi
}

clear
banner
echo -e "  ${BOLD}Server Report${NC}   $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  ${DIM}Setup date: ${SETUP_DATE}${NC}"
echo
divider

echo -e "\n  ${BOLD}${CYAN}Server${NC}"
row "Public IP" "$SERVER_IP"
row "Hostname" "$(hostname -f 2> /dev/null || hostname)"
row "OS" "$(grep PRETTY_NAME /etc/os-release 2> /dev/null | cut -d'"' -f2 || uname -r)"
row "Kernel" "$(uname -r)"
row "Uptime" "$(uptime -p 2> /dev/null || uptime)"

echo -e "\n  ${BOLD}${CYAN}Resources${NC}"
df -h / | awk 'NR==2 {printf "  '"${BOLD}"'%-30s'"${NC}"' %s used of %s (%s free)\n", "Disk (/)", $3, $2, $4}'
free -h | awk '/^Mem:/  {printf "  '"${BOLD}"'%-30s'"${NC}"' %s used of %s\n", "RAM", $3, $2}'
free -h | awk '/^Swap:/ {printf "  '"${BOLD}"'%-30s'"${NC}"' %s used of %s\n", "Swap", $3, $2}'

echo -e "\n  ${BOLD}${CYAN}Application${NC}"
if [[ -n "$APP_DOMAIN" ]]; then
  row "Domain" "$APP_DOMAIN"
  row "URL" "https://${APP_DOMAIN}"
fi
[[ -n "$APP_PATH" ]] && row "App path" "$APP_PATH"
if [[ -n "$APP_PATH" ]] && [[ -f "${APP_PATH}/artisan" ]]; then
  PHP_BIN="php${PHP_VERSION:-}"
  has_cmd "$PHP_BIN" || PHP_BIN="php"
  APP_VER=$("$PHP_BIN" "${APP_PATH}/artisan" --version 2> /dev/null | awk '{print $NF}') || APP_VER="?"
  row "Laravel version" "$APP_VER"
  ENV_VAL=$("$PHP_BIN" "${APP_PATH}/artisan" config:show app.env 2> /dev/null || true)
  [[ -n "$ENV_VAL" ]] && row "Environment" "$ENV_VAL"
fi

echo -e "\n  ${BOLD}${CYAN}Services${NC}"
service_status "Nginx" "nginx" "$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)"
[[ -n "$PHP_VERSION" ]] && service_status "PHP-FPM ${PHP_VERSION}" "php${PHP_VERSION}-fpm" "$(php${PHP_VERSION} -v 2> /dev/null | head -1 | awk '{print $2}')"
service_status "MySQL" "mysql" "$(mysql --version 2> /dev/null | awk '{print $3}')"
service_status "MariaDB" "mariadb" "$(mariadb --version 2> /dev/null | awk '{print $3}')"
service_status "PostgreSQL" "postgresql" "$(psql --version 2> /dev/null | awk '{print $3}')"
service_status "Redis" "redis" "$(redis-server --version 2> /dev/null | awk '{print $3}' | tr -d 'v=')"
service_status "Supervisor" "supervisor"
service_status "Meilisearch" "meilisearch"
service_status "Mailpit" "mailpit"
service_status "Varnish" "varnish"
service_status "Fail2ban" "fail2ban"
service_status "Certbot timer" "certbot.timer"

echo -e "\n  ${BOLD}${CYAN}Ports${NC}"
print_port() {
  local label="$1" port="$2"
  if ss -tlnp 2> /dev/null | grep -q ":${port} " || netstat -tlnp 2> /dev/null | grep -q ":${port} " 2> /dev/null; then
    printf "  ${GREEN}${BOLD}●${NC}  %-28s ${GREEN}:%-6s${NC} listening\n" "$label" "$port"
  else
    printf "  ${DIM}○${NC}  %-28s ${DIM}:%-6s${NC} not listening\n" "$label" "$port"
  fi
}
print_port "HTTP" 80
print_port "HTTPS" 443
print_port "MySQL" 3306
print_port "PostgreSQL" 5432
print_port "Redis" "${REDIS_PORT:-6379}"
print_port "Reverb WS" "$(creds_load REVERB_PORT 2> /dev/null || echo 8080)"
print_port "Octane" "$(creds_load OCTANE_PORT 2> /dev/null || echo 8000)"
print_port "Meilisearch" "$(creds_load MEILI_PORT 2> /dev/null || echo 7700)"
print_port "Mailpit SMTP" "$(creds_load MAILPIT_SMTP_PORT 2> /dev/null || echo 1025)"
print_port "Mailpit UI" "$(creds_load MAILPIT_WEB_PORT 2> /dev/null || echo 8025)"
print_port "MinIO API" "$(creds_load MINIO_PORT 2> /dev/null || echo 9000)"
print_port "MinIO Console" "$(creds_load MINIO_CONSOLE_PORT 2> /dev/null || echo 9001)"

echo -e "\n  ${BOLD}${CYAN}SSL Certificates${NC}"
if has_cmd certbot; then
  certbot certificates 2> /dev/null | grep -E "Domains:|Expiry|VALID|EXPIRED|INVALID" \
    | sed 's/^  */  /' | sed "s/VALID/${GREEN}VALID${NC}/; s/EXPIRED/${RED}EXPIRED${NC}/; s/INVALID/${RED}INVALID${NC}/" | head -20 || true
else
  echo -e "  ${DIM}Certbot not installed${NC}"
fi

if [[ -n "$APP_PATH" ]] && [[ -f "${APP_PATH}/artisan" ]]; then
  echo -e "\n  ${BOLD}${CYAN}Queue${NC}"
  PHP_BIN="php${PHP_VERSION:-}"
  has_cmd "$PHP_BIN" || PHP_BIN="php"
  FAILED=$("$PHP_BIN" "${APP_PATH}/artisan" queue:failed 2> /dev/null | grep -c "^\|" || echo "0")
  [[ "$FAILED" -gt 0 ]] \
    && printf "  ${RED}${BOLD}!${NC}  Failed jobs: ${RED}%s${NC}\n" "$FAILED" \
    || printf "  ${GREEN}${BOLD}✔${NC}  Failed jobs: ${GREEN}0${NC}\n"

  if has_cmd supervisorctl; then
    supervisorctl status 2> /dev/null | awk '{
      status=$2; name=$1;
      if (status=="RUNNING") printf "  \033[32m●\033[0m  %-30s \033[32m%s\033[0m\n", name, status;
      else printf "  \033[33m○\033[0m  %-30s \033[33m%s\033[0m\n", name, status;
    }' || true
  fi
fi

echo
divider
echo -e "  ${DIM}Credentials file: ${CREDS_FILE}${NC}"
echo
