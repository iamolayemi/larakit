#!/usr/bin/env bash
# =============================================================================
#  Manage — Generate Env
#  Generate a Laravel .env file from saved credentials.
#  Run standalone: sudo bash manage/generate-env.sh
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

section "Generate Laravel .env"

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"

ENV_FILE="${APP_PATH}/.env"
ENV_EXAMPLE="${APP_PATH}/.env.example"

if [[ ! -d "$APP_PATH" ]]; then
  error "App path not found: ${APP_PATH}"
  exit 1
fi

ask OUTPUT_PATH "Save .env to" "$ENV_FILE"

if [[ -f "$OUTPUT_PATH" ]]; then
  warn "File already exists: ${OUTPUT_PATH}"
  ask_yn OVERWRITE "Overwrite?" "n"
  [[ "$OVERWRITE" != "true" ]] && {
    info "Aborted."
    exit 0
  }
  backup_file "$OUTPUT_PATH"
fi

# Load all saved credentials
DB_ENGINE="$(creds_load DB_ENGINE 2> /dev/null || echo "MySQL")"
DB_HOST="$(creds_load DB_HOST 2> /dev/null || echo "127.0.0.1")"
DB_PORT="$(creds_load DB_PORT 2> /dev/null || echo "3306")"
DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"
REDIS_PASSWORD="$(creds_load REDIS_PASSWORD 2> /dev/null || echo "")"
REDIS_PORT="$(creds_load REDIS_PORT 2> /dev/null || echo "6379")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "example.com")"
REVERB_APP_ID="$(creds_load REVERB_APP_ID 2> /dev/null || echo "")"
REVERB_APP_KEY="$(creds_load REVERB_APP_KEY 2> /dev/null || echo "")"
REVERB_APP_SECRET="$(creds_load REVERB_APP_SECRET 2> /dev/null || echo "")"
REVERB_PORT="$(creds_load REVERB_PORT 2> /dev/null || echo "8080")"
MINIO_ACCESS_KEY="$(creds_load MINIO_ACCESS_KEY 2> /dev/null || echo "")"
MINIO_SECRET_KEY="$(creds_load MINIO_SECRET_KEY 2> /dev/null || echo "")"
MINIO_BUCKET="$(creds_load MINIO_BUCKET 2> /dev/null || echo "")"
MINIO_PORT="$(creds_load MINIO_PORT 2> /dev/null || echo "9000")"
MEILI_PORT="$(creds_load MEILI_PORT 2> /dev/null || echo "7700")"
MEILI_MASTER_KEY="$(creds_load MEILI_MASTER_KEY 2> /dev/null || echo "")"
MAILPIT_SMTP_PORT="$(creds_load MAILPIT_SMTP_PORT 2> /dev/null || echo "1025")"

# Prompt for things that aren't in creds
ask APP_NAME "Application name" "$(basename "$APP_PATH")"
ask APP_URL "Application URL" "https://${APP_DOMAIN}"
APP_KEY="base64:$(openssl rand -base64 32)"

# DB driver mapping
case "$DB_ENGINE" in
  *ostgres*)
    DB_DRIVER="pgsql"
    DB_PORT="${DB_PORT:-5432}"
    ;;
  *Maria*) DB_DRIVER="mysql" ;;
  *) DB_DRIVER="mysql" ;;
esac

ask_yn USE_REDIS_QUEUE "Use Redis for queue driver?" "y"
ask_yn USE_REDIS_CACHE "Use Redis for cache driver?" "y"
ask_yn USE_REDIS_SESSION "Use Redis for session driver?" "y"

QUEUE_DRIVER="database"
CACHE_DRIVER="database"
SESSION_DRIVER="database"
[[ "$USE_REDIS_QUEUE" == "true" ]] && QUEUE_DRIVER="redis"
[[ "$USE_REDIS_CACHE" == "true" ]] && CACHE_DRIVER="redis"
[[ "$USE_REDIS_SESSION" == "true" ]] && SESSION_DRIVER="redis"

ask_choice MAIL_MAILER "Mail mailer" \
  "smtp (Mailpit / staging)" \
  "ses (AWS SES)" \
  "mailgun" \
  "log (no sending)"
MAIL_MAILER="${MAIL_MAILER%% *}"
[[ "$MAIL_MAILER" == "smtp" ]] && MAIL_HOST="127.0.0.1" MAIL_PORT="$MAILPIT_SMTP_PORT"

step "Writing ${OUTPUT_PATH}..."

cat > "$OUTPUT_PATH" << ENV
APP_NAME="${APP_NAME}"
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=${APP_URL}

LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=error

DB_CONNECTION=${DB_DRIVER}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}

BROADCAST_CONNECTION=$([ -n "$REVERB_APP_KEY" ] && echo "reverb" || echo "log")
FILESYSTEM_DISK=$([ -n "$MINIO_BUCKET" ] && echo "s3" || echo "local")
QUEUE_CONNECTION=${QUEUE_DRIVER}
CACHE_STORE=${CACHE_DRIVER}
SESSION_DRIVER=${SESSION_DRIVER}

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=$([ -n "$REDIS_PASSWORD" ] && echo "\"${REDIS_PASSWORD}\"" || echo "null")
REDIS_PORT=${REDIS_PORT}

MAIL_MAILER=${MAIL_MAILER}
MAIL_HOST=${MAIL_HOST:-smtp.mailprovider.com}
MAIL_PORT=${MAIL_PORT:-587}
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS="hello@${APP_DOMAIN}"
MAIL_FROM_NAME="\${APP_NAME}"
ENV

# Conditional Reverb block
if [[ -n "$REVERB_APP_KEY" ]]; then
  cat >> "$OUTPUT_PATH" << ENV

REVERB_APP_ID=${REVERB_APP_ID}
REVERB_APP_KEY=${REVERB_APP_KEY}
REVERB_APP_SECRET=${REVERB_APP_SECRET}
REVERB_HOST=${APP_DOMAIN}
REVERB_PORT=${REVERB_PORT}
REVERB_SCHEME=https

VITE_REVERB_APP_KEY="\${REVERB_APP_KEY}"
VITE_REVERB_HOST="\${REVERB_HOST}"
VITE_REVERB_PORT="\${REVERB_PORT}"
VITE_REVERB_SCHEME="\${REVERB_SCHEME}"
ENV
fi

# Conditional MinIO block
if [[ -n "$MINIO_BUCKET" ]]; then
  cat >> "$OUTPUT_PATH" << ENV

AWS_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=${MINIO_BUCKET}
AWS_ENDPOINT=http://127.0.0.1:${MINIO_PORT}
AWS_USE_PATH_STYLE_ENDPOINT=true
ENV
fi

# Conditional Meilisearch block
if [[ -n "$MEILI_MASTER_KEY" ]]; then
  cat >> "$OUTPUT_PATH" << ENV

SCOUT_DRIVER=meilisearch
MEILISEARCH_HOST=http://127.0.0.1:${MEILI_PORT}
MEILISEARCH_KEY=${MEILI_MASTER_KEY}
ENV
fi

chmod 640 "$OUTPUT_PATH"
success ".env written to ${OUTPUT_PATH}"

echo
warn "Review and adjust the generated file before starting your app:"
echo -e "  ${DIM}nano ${OUTPUT_PATH}${NC}"
echo
info "Then run:"
echo -e "  ${DIM}php artisan config:cache && php artisan route:cache${NC}"
