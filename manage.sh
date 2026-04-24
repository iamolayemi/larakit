#!/usr/bin/env bash
# =============================================================================
#  LaraKit — Management Console
#  Day-to-day server management for your Laravel stack
#  Usage: sudo bash manage.sh
#  Remote: sudo bash <(curl -fsSL https://raw.githubusercontent.com/iamolayemi/larakit/main/manage.sh)
# =============================================================================
set -euo pipefail

SETUP_VERSION="1.0.0"
GITHUB_USER="${GITHUB_USER:-iamolayemi}"
GITHUB_REPO="${GITHUB_REPO:-larakit}"
SETUP_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main"

if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "bash" ]]; then
  SETUP_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SETUP_BASE_DIR="$(mktemp -d /tmp/larakit-manage.XXXXXXXX)"
  for lib in colors.sh prompts.sh creds.sh utils.sh; do
    curl -fsSL "${SETUP_BASE_URL}/lib/${lib}" -o "${SETUP_BASE_DIR}/lib/${lib}" --create-dirs
  done
fi

export SETUP_BASE_DIR SETUP_BASE_URL SETUP_LOADED=1

source "${SETUP_BASE_DIR}/lib/colors.sh"
source "${SETUP_BASE_DIR}/lib/prompts.sh"
source "${SETUP_BASE_DIR}/lib/creds.sh"
source "${SETUP_BASE_DIR}/lib/utils.sh"

declare -a MANAGE_FILES=(
  "health.sh"
  "report.sh"
  "deploy.sh"
  "redeploy.sh"
  "rollback.sh"
  "restart.sh"
  "logs.sh"
  "db-backup.sh"
  "db-restore.sh"
  "ssl-renew.sh"
  "queue-status.sh"
  "test-mail.sh"
  "generate-env.sh"
  "webhook-listen.sh"
  "self-update.sh"
  "credentials.sh"
  "firewall-audit.sh"
  "init.sh"
  "db-optimize.sh"
  "performance-test.sh"
  "diagnose.sh"
  "env-check.sh"
  "ssh-keys.sh"
  "swap.sh"
  "crontab.sh"
  "php-ext.sh"
  "db-copy.sh"
  "logrotate.sh"
  "queue-scale.sh"
  "cache-clear.sh"
  "ssl-info.sh"
  "app-create.sh"
)

declare -a MANAGE_NAMES=(
  "Health Check — service statuses, ports, disk, RAM"
  "Server Report — full stack overview with URLs and versions"
  "Deploy — pull latest code and deploy"
  "Redeploy — full redeploy (composer, migrations, cache)"
  "Rollback — revert to previous release"
  "Restart Services — PHP-FPM, Nginx, queue workers, Horizon"
  "View Logs — tail Laravel, Nginx, queue worker logs"
  "Database Backup — create an on-demand backup"
  "Database Restore — restore from a backup file"
  "Renew SSL — force Let's Encrypt certificate renewal"
  "Queue Status — Supervisor workers and failed jobs"
  "Test Mail — verify SMTP / mail configuration"
  "Generate .env — build Laravel .env from saved credentials"
  "Webhook Listener — GitHub/GitLab deploy trigger setup"
  "Self-Update — download latest LaraKit scripts from GitHub"
  "Show Credentials — display saved credentials"
  "Firewall Audit — review UFW rules and open ports"
  "Init — collect project credentials without installing anything"
  "DB Optimize — OPTIMIZE TABLE (MySQL) or VACUUM ANALYZE (Postgres)"
  "Performance Test — load test with ab or wrk"
  "Diagnose — health + firewall + SSL check in one shot"
  "Env Check — compare .env against expected keys"
  "SSH Keys — manage authorized_keys for the deploy user"
  "Swap — add, resize, or remove swap space"
  "Crontab — view and manage application cron entries"
  "PHP Extensions — enable or disable PHP extensions"
  "DB Copy — copy database between environments"
  "Log Rotate — configure log rotation for app and Nginx"
  "Queue Scale — adjust Supervisor worker count live"
  "Cache Clear — flush config, route, view, OPcache, Redis"
  "SSL Info — certificate expiry and chain for all domains"
  "App Create — scaffold a new app (vhost, DB, directory, .env)"
)

run_manage() {
  local script="$1"
  local script_path="${SETUP_BASE_DIR}/manage/${script}"

  if [[ ! -f "$script_path" ]]; then
    mkdir -p "${SETUP_BASE_DIR}/manage"
    curl -fsSL "${SETUP_BASE_URL}/manage/${script}" -o "$script_path" 2> /dev/null || {
      error "Could not load manage/${script}"
      return 1
    }
    chmod +x "$script_path"
  fi

  bash "$script_path"
}

main() {
  clear
  banner

  echo -e "  ${BOLD}LaraKit Management Console${NC}  v${SETUP_VERSION}"
  echo -e "  ${DIM}Server: $(get_public_ip 2> /dev/null || hostname)${NC}"
  echo
  divider

  echo -e "\n  ${BOLD}Available operations:${NC}\n"
  for i in "${!MANAGE_FILES[@]}"; do
    printf "  ${BOLD}%2d)${NC} %s\n" "$((i + 1))" "${MANAGE_NAMES[$i]}"
  done

  echo -e "   ${DIM}q)  Quit${NC}\n"

  local choice
  read -r -p "$(echo -e "  ${YELLOW}?${NC}  Select operation: ")" choice

  [[ "$choice" == "q" || "$choice" == "Q" ]] && exit 0

  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#MANAGE_FILES[@]}" ]]; then
    echo
    section "${MANAGE_NAMES[$((choice - 1))]}"
    run_manage "${MANAGE_FILES[$((choice - 1))]}"
  else
    error "Invalid selection."
    exit 1
  fi
}

main "$@"
