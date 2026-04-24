#!/usr/bin/env bash
# =============================================================================
#  Manage — DB Copy
#  Copy database between environments (prod → staging, remote → local, etc.)
#  Run standalone: sudo bash manage/db-copy.sh
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

module_header "DB Copy" "Copy a database between environments — remote to local or between apps on this server."
require_root

DB_DRIVER="$(creds_load DB_DRIVER 2> /dev/null || echo "mysql")"
DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "laravel")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "laravel")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"

ask_choice COPY_MODE "Copy mode:" \
  "remote-to-local  — dump from a remote server, import here" \
  "local-to-local   — copy between two databases on this server" \
  "export-only      — dump to a .sql.gz file"
COPY_MODE="${COPY_MODE%% *}"

# ---- Source database --------------------------------------------------------
section "Source Database"
ask SRC_HOST "Source host (localhost or remote IP)" "localhost"
ask SRC_PORT "Source port" "3306"
ask SRC_DB "Source database name" "$DB_NAME"
ask SRC_USER "Source database user" "$DB_USER"
ask SRC_PASS "Source database password" "$DB_PASSWORD"

DUMP_FILE="/tmp/larakit-dbcopy-$(date +%Y%m%d-%H%M%S).sql.gz"

# ---- Destination ------------------------------------------------------------
if [[ "$COPY_MODE" != "export-only" ]]; then
  section "Destination Database"
  ask DST_HOST "Destination host" "localhost"
  ask DST_PORT "Destination port" "3306"
  ask DST_DB "Destination database name" "${SRC_DB}_staging"
  ask DST_USER "Destination database user" "$DB_USER"
  ask DST_PASS "Destination database password" "$DB_PASSWORD"
  ask_yn DROP_DST "Drop and recreate destination database first?" "y"
fi

if [[ "$COPY_MODE" == "export-only" ]]; then
  ask DUMP_FILE "Save dump to" "$DUMP_FILE"
fi

echo
confirm_or_exit "Proceed with database copy?"

# ---- Build remote SSH prefix if needed --------------------------------------
SSH_PREFIX=""
if [[ "$COPY_MODE" == "remote-to-local" ]] && [[ "$SRC_HOST" != "localhost" && "$SRC_HOST" != "127.0.0.1" ]]; then
  ask SSH_USER "SSH user for ${SRC_HOST}" "deploy"
  ask SSH_PORT "SSH port" "22"
  SSH_PREFIX="ssh -p ${SSH_PORT} ${SSH_USER}@${SRC_HOST}"
  step "Testing SSH connection to ${SRC_HOST}..."
  $SSH_PREFIX "echo connected" > /dev/null 2>&1 || {
    error "SSH connection failed."
    exit 1
  }
  success "SSH connection OK."
fi

# ---- Dump -------------------------------------------------------------------
step "Dumping source database '${SRC_DB}'..."

case "$DB_DRIVER" in
  postgres | postgresql | pg)
    DUMP_CMD="PGPASSWORD='${SRC_PASS}' pg_dump -h '${SRC_HOST}' -p '${SRC_PORT}' -U '${SRC_USER}' '${SRC_DB}' | gzip"
    ;;
  *)
    DUMP_CMD="mysqldump -h '${SRC_HOST}' -P '${SRC_PORT}' -u '${SRC_USER}' -p'${SRC_PASS}' --single-transaction --routines --triggers '${SRC_DB}' | gzip"
    ;;
esac

if [[ -n "$SSH_PREFIX" ]]; then
  $SSH_PREFIX "$DUMP_CMD" > "$DUMP_FILE"
else
  eval "$DUMP_CMD" > "$DUMP_FILE"
fi

DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
success "Dump complete: ${DUMP_FILE} (${DUMP_SIZE})"

if [[ "$COPY_MODE" == "export-only" ]]; then
  echo
  success "Export saved to: ${DUMP_FILE}"
  info "To import: zcat '${DUMP_FILE}' | mysql -u user -p database"
  exit 0
fi

# ---- Restore ----------------------------------------------------------------
step "Importing into '${DST_DB}' on ${DST_HOST}..."

case "$DB_DRIVER" in
  postgres | postgresql | pg)
    if [[ "$DROP_DST" == "true" ]]; then
      PGPASSWORD="$DST_PASS" psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -c "DROP DATABASE IF EXISTS \"${DST_DB}\";" postgres 2> /dev/null || true
      PGPASSWORD="$DST_PASS" psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" -c "CREATE DATABASE \"${DST_DB}\";" postgres
    fi
    zcat "$DUMP_FILE" | PGPASSWORD="$DST_PASS" psql -h "$DST_HOST" -p "$DST_PORT" -U "$DST_USER" "$DST_DB"
    ;;
  *)
    if [[ "$DROP_DST" == "true" ]]; then
      mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" \
        -e "DROP DATABASE IF EXISTS \`${DST_DB}\`; CREATE DATABASE \`${DST_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2> /dev/null
    fi
    zcat "$DUMP_FILE" | mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$DST_DB"
    ;;
esac

rm -f "$DUMP_FILE"

echo
success "Database copy complete."
info "Source:      ${SRC_DB} @ ${SRC_HOST}"
info "Destination: ${DST_DB} @ ${DST_HOST}"
warn "Remember to update .env APP_KEY and any environment-specific settings."
