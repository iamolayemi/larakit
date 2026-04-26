#!/usr/bin/env bash
# =============================================================================
#  LaraKit - Orchestrator
#  Usage (local):   sudo bash setup.sh
#  Usage (remote):  curl -fsSL https://.../install.sh | sudo bash
# =============================================================================
set -euo pipefail

SETUP_VERSION="1.0.0"

# Resolve script dir
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# Source config if present locally
[[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/config.sh" ]] && source "${SCRIPT_DIR}/config.sh"

# Remote: download libs to temp dir
if [[ -z "$SCRIPT_DIR" ]] || [[ ! -d "${SCRIPT_DIR}/lib" ]]; then
  [[ -z "${SETUP_BASE_URL:-}" ]] && {
    echo "ERROR: SETUP_BASE_URL not set."
    exit 1
  }
  SCRIPT_DIR="$(mktemp -d /tmp/larakit.XXXXXXXX)"
  echo "Downloading installer..."
  for lib in colors.sh prompts.sh creds.sh utils.sh; do
    curl -fsSL "${SETUP_BASE_URL}/lib/${lib}" -o "${SCRIPT_DIR}/lib/${lib}" --create-dirs
  done
  mkdir -p "${SCRIPT_DIR}/modules"
fi

export SETUP_BASE_DIR="${SCRIPT_DIR}"
export SETUP_LOADED=1

source "${SCRIPT_DIR}/lib/colors.sh"
source "${SCRIPT_DIR}/lib/prompts.sh"
source "${SCRIPT_DIR}/lib/creds.sh"
source "${SCRIPT_DIR}/lib/utils.sh"

declare -a MODULE_FILES=(
  "system-init.sh"
  "server-hardening.sh"
  "php.sh"
  "nginx.sh"
  "mysql.sh"
  "redis.sh"
  "node.sh"
  "ssl.sh"
  "laravel-app.sh"
  "queue-worker.sh"
  "scheduler.sh"
  "horizon.sh"
  "reverb.sh"
  "octane.sh"
  "minio.sh"
  "postgres.sh"
  "meilisearch.sh"
  "typesense.sh"
  "elasticsearch.sh"
  "rabbitmq.sh"
  "varnish.sh"
  "load-balancer.sh"
  "mailpit.sh"
  "backups.sh"
  "tuning.sh"
  "monitoring.sh"
  "phpmyadmin.sh"
  "pgadmin.sh"
  "soketi.sh"
  "memcached.sh"
  "chromium.sh"
)

declare -a MODULE_NAMES=(
  "System Init & Updates"
  "Server Hardening (UFW, Fail2ban, SSH)"
  "PHP Installation & Configuration"
  "Nginx Web Server & Virtual Host"
  "MySQL / MariaDB Database"
  "Redis Cache & Sessions"
  "Node.js & npm (via NVM)"
  "SSL / TLS - Let's Encrypt"
  "Laravel Application Deployment"
  "Queue Worker (Supervisor)"
  "Task Scheduler (Cron)"
  "Laravel Horizon (Queue Dashboard)"
  "Laravel Reverb (WebSockets)"
  "Laravel Octane (Swoole / FrankenPHP)"
  "MinIO Object Storage (S3-compatible)"
  "PostgreSQL Database"
  "Meilisearch (Full-text Search)"
  "Typesense (Full-text Search)"
  "Elasticsearch + Kibana"
  "RabbitMQ (Message Broker)"
  "Varnish Cache (HTTP Accelerator)"
  "Load Balancer (Nginx / HAProxy)"
  "Mailpit (SMTP Mail Catcher)"
  "Automated Backups (DB + Files)"
  "Performance Tuning (PHP, Nginx, DB, kernel)"
  "Monitoring (Netdata + UptimeKuma)"
  "phpMyAdmin (Web-based DB Admin)"
  "pgAdmin 4 (Web-based PostgreSQL Admin)"
  "Soketi (Pusher-compatible WebSockets)"
  "Memcached (In-memory Cache)"
  "Headless Chromium & wkhtmltopdf (PDF / Screenshots)"
)

declare -a MODULE_CATEGORIES=(
  "foundation" "foundation" "foundation" "foundation" "foundation"
  "optional" "optional" "foundation" "app" "app" "app"
  "advanced" "advanced" "advanced" "advanced" "foundation"
  "optional" "optional" "optional" "optional"
  "advanced" "advanced" "optional"
  "advanced" "advanced" "advanced"
  "optional" "optional"
  "advanced" "optional" "optional"
)

run_cred_wizard() {
  section "Project Credentials"
  echo -e "  ${DIM}These are saved to ${CREDS_FILE} and pre-fill all module prompts.${NC}\n"

  local server_ip
  server_ip=$(get_public_ip 2> /dev/null || hostname -I | awk '{print $1}')
  creds_save SERVER_IP "$server_ip"
  creds_save SETUP_DATE "$(date '+%Y-%m-%d %H:%M:%S')"

  local APP_DOMAIN APP_PATH DEPLOY_USER DEPLOY_BRANCH GITHUB_REPO_URL
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

  local PHP_VERSION
  PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
  ask_choice PHP_VERSION "Default PHP version" \
    "8.5 (Latest)" "8.4 (Stable — recommended)" "8.3 (LTS)" "8.2 (LTS)"
  PHP_VERSION="${PHP_VERSION%% *}"
  creds_section "PHP"
  creds_save PHP_VERSION "$PHP_VERSION"

  local DB_DRIVER DB_NAME DB_USER DB_PASSWORD DB_PORT
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

  local REDIS_PASSWORD REDIS_PORT
  REDIS_PASSWORD="$(creds_load REDIS_PASSWORD 2> /dev/null || gen_password 20)"
  REDIS_PORT="$(creds_load REDIS_PORT 2> /dev/null || echo "6379")"
  ask REDIS_PASSWORD "Redis password" "$REDIS_PASSWORD"
  ask REDIS_PORT "Redis port" "$REDIS_PORT"
  creds_section "Redis"
  creds_save REDIS_PASSWORD "$REDIS_PASSWORD"
  creds_save REDIS_PORT "$REDIS_PORT"

  local SLACK_URL TG_TOKEN TG_CHAT DISCORD_URL
  echo -e "\n  ${DIM}Notification webhooks — leave blank to skip.${NC}\n"
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

  success "Credentials saved to ${CREDS_FILE}"
  echo
}

run_preset_minimal() { SELECTED_MODULES=("system-init.sh" "server-hardening.sh" "php.sh" "nginx.sh" "mysql.sh" "ssl.sh" "laravel-app.sh"); }
run_preset_standard() { SELECTED_MODULES=("system-init.sh" "server-hardening.sh" "php.sh" "nginx.sh" "mysql.sh" "redis.sh" "node.sh" "ssl.sh" "laravel-app.sh" "queue-worker.sh" "scheduler.sh" "tuning.sh"); }
run_preset_postgres() { SELECTED_MODULES=("system-init.sh" "server-hardening.sh" "php.sh" "nginx.sh" "postgres.sh" "redis.sh" "node.sh" "ssl.sh" "laravel-app.sh" "queue-worker.sh" "scheduler.sh"); }
run_preset_full() { SELECTED_MODULES=("${MODULE_FILES[@]}"); }
run_preset_api() { SELECTED_MODULES=("system-init.sh" "server-hardening.sh" "php.sh" "nginx.sh" "mysql.sh" "redis.sh" "ssl.sh" "laravel-app.sh" "queue-worker.sh" "scheduler.sh" "tuning.sh"); }
run_preset_queue_heavy() { SELECTED_MODULES=("system-init.sh" "server-hardening.sh" "php.sh" "nginx.sh" "mysql.sh" "redis.sh" "node.sh" "ssl.sh" "laravel-app.sh" "queue-worker.sh" "scheduler.sh" "horizon.sh" "tuning.sh"); }

run_module() {
  local mod="$1"
  local mod_path="${SETUP_BASE_DIR}/modules/${mod}"
  if [[ ! -f "$mod_path" ]]; then
    step "Downloading: ${mod}"
    mkdir -p "${SETUP_BASE_DIR}/modules"
    curl -fsSL "${SETUP_BASE_URL}/modules/${mod}" -o "$mod_path"
    chmod +x "$mod_path"
  fi
  SETUP_BASE_DIR="$SETUP_BASE_DIR" SETUP_BASE_URL="${SETUP_BASE_URL:-}" \
    SETUP_LOADED=1 CREDS_FILE="$CREDS_FILE" bash "$mod_path"
}

select_modules() {
  section "Module Selection"
  echo -e "  Choose what to install:\n"
  local cat_labels=("Foundation" "App Layer" "Advanced / Optional")
  local cat_filters=("foundation" "app" "advanced|optional")
  for cat_idx in "${!cat_labels[@]}"; do
    echo -e "  ${MAGENTA}${BOLD}${cat_labels[$cat_idx]}${NC}"
    for i in "${!MODULE_FILES[@]}"; do
      echo "${MODULE_CATEGORIES[$i]}" | grep -qE "${cat_filters[$cat_idx]}" \
        && printf "  ${BOLD}%-20s${NC} %s\n" "${MODULE_FILES[$i]%.sh}" "${MODULE_NAMES[$i]}"
    done
    echo
  done
  echo -e "  ${DIM}Shortcuts: minimal, standard, postgres, api, queue-heavy, full${NC}"
  echo -e "  ${DIM}Or type module names separated by spaces: php nginx mysql ssl laravel-app${NC}\n"
  local input
  read -r -p "$(echo -e "  ${YELLOW}?${NC}  Selection (shortcut or module names): ")" input
  SELECTED_MODULES=()
  case "$input" in
    all | full) run_preset_full ;;
    minimal) run_preset_minimal ;;
    standard) run_preset_standard ;;
    postgres) run_preset_postgres ;;
    api) run_preset_api ;;
    queue-heavy) run_preset_queue_heavy ;;
    *)
      for name in $input; do
        local matched=false
        for i in "${!MODULE_FILES[@]}"; do
          if [[ "${MODULE_FILES[$i]%.sh}" == "$name" ]]; then
            SELECTED_MODULES+=("${MODULE_FILES[$i]}")
            matched=true
            break
          fi
        done
        [[ "$matched" == "false" ]] && warn "Unknown module: $name"
      done
      ;;
  esac
  [[ ${#SELECTED_MODULES[@]} -eq 0 ]] && {
    error "No modules selected."
    exit 1
  }
  echo -e "\n  ${GREEN}${BOLD}Selected:${NC}"
  for mod in "${SELECTED_MODULES[@]}"; do
    for i in "${!MODULE_FILES[@]}"; do
      [[ "${MODULE_FILES[$i]}" == "$mod" ]] && echo -e "  ${GREEN}+${NC}  ${MODULE_NAMES[$i]}" && break
    done
  done
  echo
}

print_summary() {
  local -n _mods=$1 _results=$2
  echo
  section "Installation Summary"
  local passed=0 failed=0
  for i in "${!_mods[@]}"; do
    local mod="${_mods[$i]}"
    local status="${_results[$i]:-unknown}"
    local idx=0
    for j in "${!MODULE_FILES[@]}"; do [[ "${MODULE_FILES[$j]}" == "$mod" ]] && idx=$j && break; done
    local name="${MODULE_NAMES[$idx]}"
    if [[ "$status" == "ok" ]]; then
      printf "  ${GREEN}${BOLD}✔${NC}  %s\n" "$name"
      passed=$((passed + 1))
    else
      printf "  ${RED}${BOLD}✘${NC}  %s ${DIM}(errors)${NC}\n" "$name"
      failed=$((failed + 1))
    fi
  done
  echo
  printf "  Modules run: %d  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}\n\n" "${#_mods[@]}" "$passed" "$failed"

  local app_domain
  app_domain=$(creds_load APP_DOMAIN 2> /dev/null || echo "")
  local server_ip
  server_ip=$(creds_load SERVER_IP 2> /dev/null || get_public_ip 2> /dev/null || hostname -I | awk '{print $1}')
  if [[ -n "$app_domain" ]]; then
    echo -e "  ${BOLD}${CYAN}Your app:${NC} https://${app_domain}"
  else
    echo -e "  ${BOLD}${CYAN}Server IP:${NC} ${server_ip}"
  fi

  local horizon_pass
  horizon_pass=$(creds_load HORIZON_PASSWORD 2> /dev/null || echo "")
  [[ -n "$horizon_pass" ]] && echo -e "  ${BOLD}${CYAN}Horizon:${NC}   https://${app_domain:-${server_ip}}/horizon  ${DIM}(password: ${horizon_pass})${NC}"

  local mailpit_domain
  mailpit_domain=$(creds_load MAILPIT_DOMAIN 2> /dev/null || echo "")
  [[ -n "$mailpit_domain" ]] && echo -e "  ${BOLD}${CYAN}Mailpit:${NC}   http://${mailpit_domain}"

  local meili_domain
  meili_domain=$(creds_load MEILI_DOMAIN 2> /dev/null || echo "")
  [[ -n "$meili_domain" ]] && echo -e "  ${BOLD}${CYAN}Meilisearch:${NC} http://${meili_domain}"

  echo
  echo -e "  ${BOLD}Credentials saved to:${NC} ${DIM}${CREDS_FILE}${NC}"
  echo -e "  ${DIM}Delete after securing: rm ${CREDS_FILE}${NC}"
  echo
}

main() {
  # Parse --profile flag from args
  local PROFILE=""
  local filtered_args=()
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#--profile=}" ;;
      --profile) : ;; # next arg is value; handled below
      *) filtered_args+=("$arg") ;;
    esac
  done
  # Handle "--profile standard" (space-separated)
  local skip_next=false
  filtered_args=()
  for arg in "$@"; do
    if [[ "$skip_next" == "true" ]]; then
      skip_next=false
      continue
    fi
    case "$arg" in
      --profile=*) PROFILE="${arg#--profile=}" ;;
      --profile)
        PROFILE="${2:-}"
        skip_next=true
        ;;
      *) filtered_args+=("$arg") ;;
    esac
  done

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    warn "DRY RUN mode — no changes will be made."
  fi

  require_root
  detect_os
  clear
  banner
  echo -e "  ${BOLD}Version:${NC} ${SETUP_VERSION}"
  echo -e "  ${BOLD}OS:${NC}      ${OS_ID} ${OS_VERSION} ${OS_CODENAME:-}"
  echo -e "  ${BOLD}IP:${NC}      $(get_public_ip 2> /dev/null || hostname -I | awk '{print $1}')"
  echo -e "  ${BOLD}Creds:${NC}   ${CREDS_FILE}"
  [[ "${DRY_RUN:-false}" == "true" ]] && echo -e "  ${YELLOW}${BOLD}DRY RUN${NC}"
  echo
  divider
  echo

  ask_yn RUN_PREFLIGHT "Run pre-flight checks before setup?" "y"
  if [[ "$RUN_PREFLIGHT" == "true" ]]; then
    run_module "preflight.sh" || true
    echo
  fi

  creds_init
  creds_save "SERVER_OS" "${OS_ID} ${OS_VERSION}"

  # Run credential wizard — skip if creds exist and user declines update
  local SKIP_WIZARD=false
  if [[ -f "$CREDS_FILE" ]] && grep -q "^APP_DOMAIN=" "$CREDS_FILE" 2> /dev/null; then
    local existing_domain
    existing_domain=$(grep "^APP_DOMAIN=" "$CREDS_FILE" | cut -d'=' -f2-)
    echo -e "  ${GREEN}${BOLD}✔${NC}  Credentials found for ${BOLD}${existing_domain}${NC}  ${DIM}(${CREDS_FILE})${NC}"
    ask_yn UPDATE_CREDS "Update credentials?" "n"
    [[ "$UPDATE_CREDS" != "true" ]] && SKIP_WIZARD=true
  fi
  [[ "$SKIP_WIZARD" == "false" ]] && run_cred_wizard

  if [[ -n "$PROFILE" ]]; then
    case "$PROFILE" in
      minimal) run_preset_minimal ;;
      standard) run_preset_standard ;;
      postgres) run_preset_postgres ;;
      full) run_preset_full ;;
      api) run_preset_api ;;
      queue-heavy) run_preset_queue_heavy ;;
      *)
        error "Unknown profile '${PROFILE}'. Valid: minimal, standard, postgres, full, api, queue-heavy"
        exit 1
        ;;
    esac
    echo -e "\n  ${GREEN}${BOLD}Profile: ${PROFILE}${NC}"
    for mod in "${SELECTED_MODULES[@]}"; do
      for i in "${!MODULE_FILES[@]}"; do
        [[ "${MODULE_FILES[$i]}" == "$mod" ]] && echo -e "  ${GREEN}+${NC}  ${MODULE_NAMES[$i]}" && break
      done
    done
    echo
  else
    select_modules
  fi

  confirm_or_exit "Begin installation?"

  local total=${#SELECTED_MODULES[@]} current=0
  declare -a MODULE_RESULTS=()

  for mod in "${SELECTED_MODULES[@]}"; do
    current=$((current + 1))
    local idx=0
    for i in "${!MODULE_FILES[@]}"; do [[ "${MODULE_FILES[$i]}" == "$mod" ]] && idx=$i && break; done
    echo -e "\n${BLUE}${BOLD}[${current}/${total}]${NC} ${MODULE_NAMES[$idx]}"
    divider
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      dim "[DRY RUN] Would run: modules/${mod}"
      MODULE_RESULTS+=("ok")
    elif run_module "$mod"; then
      success "Done: ${MODULE_NAMES[$idx]}"
      MODULE_RESULTS+=("ok")
    else
      warn "Finished with errors: ${MODULE_NAMES[$idx]}"
      MODULE_RESULTS+=("fail")
      local cont
      ask_yn cont "Continue with remaining?" "y"
      [[ "$cont" != "true" ]] && break
    fi
  done

  print_summary SELECTED_MODULES MODULE_RESULTS
  creds_show
}

main "$@"
