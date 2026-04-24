#!/usr/bin/env bash
# =============================================================================
#  Manage — Db Restore
#  Restore a database from a backup file.
#  Run standalone: sudo bash manage/db-restore.sh
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

DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"
DB_ENGINE="$(creds_load DB_ENGINE 2> /dev/null || echo "MySQL")"
BACKUP_DIR="$(creds_load BACKUP_DIR 2> /dev/null || echo "/var/backups/laravel")"

ask DB_NAME "Database name to restore into" "$DB_NAME"
ask DB_USER "Database user" "$DB_USER"
ask_secret DB_PASS_INPUT "Database password (blank to use saved)"
[[ -n "$DB_PASS_INPUT" ]] && DB_PASSWORD="$DB_PASS_INPUT"

step "Available backup files:"
ls -lht "${BACKUP_DIR}"/*.sql.gz 2> /dev/null | head -10 | awk '{print "  " $9 " (" $5 ")"}' || warn "No .sql.gz files found in ${BACKUP_DIR}"

ask BACKUP_FILE "Full path to backup file" ""
[[ -z "$BACKUP_FILE" ]] && {
  error "No backup file specified."
  exit 1
}
[[ ! -f "$BACKUP_FILE" ]] && {
  error "File not found: ${BACKUP_FILE}"
  exit 1
}

SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
warn "This will OVERWRITE the current '${DB_NAME}' database with: $(basename "$BACKUP_FILE") (${SIZE})"
confirm_or_exit "Proceed with restore?"

step "Restoring database..."
if echo "$DB_ENGINE" | grep -qi "postgres"; then
  PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" "$DB_NAME" < <(zcat "$BACKUP_FILE")
else
  zcat "$BACKUP_FILE" | mysql --user="$DB_USER" --password="$DB_PASSWORD" "$DB_NAME"
fi

success "Database '${DB_NAME}' restored from $(basename "$BACKUP_FILE")."

ask_yn CLEAR_CACHE "Clear Laravel caches after restore?" "y"
if [[ "$CLEAR_CACHE" == "true" ]]; then
  APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
  PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
  if [[ -n "$APP_PATH" ]] && [[ -f "${APP_PATH}/artisan" ]]; then
    "/usr/bin/php${PHP_VERSION}" "${APP_PATH}/artisan" cache:clear --no-interaction 2> /dev/null || true
    success "Cache cleared."
  fi
fi
