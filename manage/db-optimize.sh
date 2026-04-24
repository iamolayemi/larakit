#!/usr/bin/env bash
# =============================================================================
#  Manage — Db Optimize
#  OPTIMIZE / VACUUM ANALYZE the application database.
#  Run standalone: sudo bash manage/db-optimize.sh
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

module_header "Database Optimize" "OPTIMIZE TABLE (MySQL/MariaDB) or VACUUM ANALYZE (PostgreSQL)"
require_root

DB_DRIVER="$(creds_load DB_DRIVER 2> /dev/null || echo "")"
DB_NAME="$(creds_load DB_NAME 2> /dev/null || echo "")"
DB_USER="$(creds_load DB_USER 2> /dev/null || echo "")"
DB_PASSWORD="$(creds_load DB_PASSWORD 2> /dev/null || echo "")"

if [[ -z "$DB_DRIVER" ]]; then
  ask_choice DB_DRIVER "Database type" "mysql" "mariadb" "postgres"
fi

ask DB_NAME "Database name" "$DB_NAME"
ask DB_USER "Database user" "$DB_USER"
ask DB_PASSWORD "Database password" "$DB_PASSWORD"

echo
confirm_or_exit "Optimize database ${DB_NAME}?"

if [[ "$DB_DRIVER" == "postgres" ]]; then
  section "PostgreSQL VACUUM ANALYZE"
  step "Running VACUUM ANALYZE on ${DB_NAME}..."
  PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -c "VACUUM ANALYZE;" && success "VACUUM ANALYZE complete." || warn "VACUUM ANALYZE finished with warnings."

  step "Table bloat estimate:"
  PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -c "
    SELECT
      schemaname,
      tablename,
      pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
      pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
      pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)
                     - pg_relation_size(schemaname||'.'||tablename)) AS index_size
    FROM pg_tables
    WHERE schemaname = 'public'
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
    LIMIT 20;
  " 2> /dev/null || true

else
  section "MySQL / MariaDB OPTIMIZE"
  MYSQL_CMD="mysql -u${DB_USER} -p${DB_PASSWORD} ${DB_NAME}"

  step "Checking tables..."
  TABLES=$(${MYSQL_CMD} -Bse "SHOW TABLES;" 2> /dev/null)
  TABLE_COUNT=$(echo "$TABLES" | wc -l | tr -d ' ')
  info "Found ${TABLE_COUNT} table(s)."

  step "Running OPTIMIZE TABLE on all tables..."
  OPTIMIZE_SQL=""
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    OPTIMIZE_SQL+="OPTIMIZE TABLE \`${table}\`; "
  done <<< "$TABLES"

  if [[ -n "$OPTIMIZE_SQL" ]]; then
    ${MYSQL_CMD} -e "$OPTIMIZE_SQL" 2> /dev/null && success "OPTIMIZE TABLE complete." || warn "Some tables may not support optimization (InnoDB tables are rebuilt via ALTER TABLE internally)."
  fi

  step "Table sizes:"
  ${MYSQL_CMD} -e "
    SELECT
      table_name AS 'Table',
      ROUND(((data_length + index_length) / 1024 / 1024), 2) AS 'Size (MB)',
      ROUND((data_free / 1024 / 1024), 2) AS 'Fragmented (MB)'
    FROM information_schema.TABLES
    WHERE table_schema = '${DB_NAME}'
    ORDER BY (data_length + index_length) DESC
    LIMIT 20;
  " 2> /dev/null || true
fi

echo
success "Database optimization complete."
