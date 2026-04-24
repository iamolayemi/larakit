#!/usr/bin/env bash
# =============================================================================
#  Manage — Db Backup
#  On-demand database backup to a timestamped file.
#  Run standalone: sudo bash manage/db-backup.sh
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

DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"
DB_ENGINE="$(creds_load DB_ENGINE 2> /dev/null || echo "MySQL")"
BACKUP_DIR="$(creds_load BACKUP_DIR 2> /dev/null || echo "/var/backups/laravel")"

ask DB_NAME "Database name" "$DB_NAME"
ask DB_USER "Database user" "$DB_USER"
ask_secret DB_PASS_INPUT "Database password (blank to use saved)"
[[ -n "$DB_PASS_INPUT" ]] && DB_PASSWORD="$DB_PASS_INPUT"
ask BACKUP_DIR "Backup destination" "$BACKUP_DIR"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo
confirm_or_exit "Create backup of '${DB_NAME}' to ${BACKUP_FILE}?"

step "Dumping database..."
if echo "$DB_ENGINE" | grep -qi "postgres"; then
  PGPASSWORD="$DB_PASSWORD" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"
else
  mysqldump \
    --user="$DB_USER" \
    --password="$DB_PASSWORD" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    --routines \
    --triggers \
    "$DB_NAME" | gzip > "$BACKUP_FILE"
fi

SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
success "Backup created: ${BACKUP_FILE} (${SIZE})"

ask_yn UPLOAD_S3 "Upload to S3/MinIO?" "n"
if [[ "$UPLOAD_S3" == "true" ]]; then
  S3_BUCKET="$(creds_load BACKUP_REMOTE 2> /dev/null || echo "")"
  ask S3_BUCKET "S3 bucket/path" "$S3_BUCKET"
  ask S3_ENDPOINT "S3 endpoint URL (blank for AWS)" "$(creds_load MINIO_ENDPOINT 2> /dev/null || echo "")"
  S3_KEY="$(creds_load MINIO_ACCESS_KEY 2> /dev/null || creds_load AWS_ACCESS_KEY_ID 2> /dev/null || echo "")"
  ask S3_KEY "Access key" "$S3_KEY"
  ask_secret S3_SECRET "Secret key"

  S3_OPTS=""
  [[ -n "$S3_ENDPOINT" ]] && S3_OPTS="--endpoint-url $S3_ENDPOINT"

  export AWS_ACCESS_KEY_ID="$S3_KEY"
  export AWS_SECRET_ACCESS_KEY="$S3_SECRET"
  aws s3 cp "$BACKUP_FILE" "${S3_BUCKET}/$(basename "$BACKUP_FILE")" $S3_OPTS \
    && success "Uploaded to: ${S3_BUCKET}"
fi
