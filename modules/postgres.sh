#!/usr/bin/env bash
# =============================================================================
#  Module 16 — PostgreSQL Database (alternative to MySQL)
#  Run standalone: sudo bash modules/16-postgres.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  # Source config for SETUP_BASE_URL
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

module_header "PostgreSQL Database" "Installs PostgreSQL — a powerful open-source relational database."
require_root

# Detect existing
if has_cmd psql; then
  CURRENT_PG=$(psql --version 2> /dev/null | awk '{print $3}')
  warn "PostgreSQL ${CURRENT_PG} is already installed."
  ask_choice EXISTING_MODE "PostgreSQL detected — what to do?" \
    "Create new database and user only" \
    "Reinstall and reconfigure" \
    "Skip — just show .env values"
else
  EXISTING_MODE="Fresh install"
fi

# Version selection
ask_choice PG_VERSION "Select PostgreSQL version:" \
  "17 (Latest)" \
  "16 (Stable — recommended)" \
  "15 (Previous stable)"

PG_VERSION="${PG_VERSION%% *}"

# App database config
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
DEFAULT_DB="${APP_DOMAIN//./_}"
DEFAULT_DB="${DEFAULT_DB//-/_}"
[[ -z "$DEFAULT_DB" ]] && DEFAULT_DB="laravel_app"

ask DB_NAME "Database name" "$DEFAULT_DB"
ask DB_USER "Database username" "laravel_user"

DB_PASSWORD="$(gen_password 24)"
warn "Generated DB password: ${DB_PASSWORD}"
ask_yn USE_GENERATED_PASS "Use this generated password?" "y"
[[ "$USE_GENERATED_PASS" != "true" ]] && ask_secret DB_PASSWORD "Enter a custom DB password"

ask PG_PORT "PostgreSQL port" "5432"
ask_yn PG_EXTENSIONS "Install common extensions (uuid-ossp, pg_trgm, hstore)?" "y"
ask_yn PG_TUNE "Apply PGTune-style performance tuning?" "y"

echo
info "Configuration:"
dim "Version:  PostgreSQL ${PG_VERSION}"
dim "Database: ${DB_NAME}"
dim "User:     ${DB_USER}"
dim "Port:     ${PG_PORT}"
echo
confirm_or_exit "Install PostgreSQL?"

# Install
if [[ "$EXISTING_MODE" != "Create new"* ]] && [[ "$EXISTING_MODE" != "Skip"* ]]; then
  step "Adding PostgreSQL official repo..."
  pkg_install gnupg curl lsb-release

  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg

  echo "deb [signed-by=/etc/apt/trusted.gpg.d/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

  apt-get update -qq
  pkg_install "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
  success "PostgreSQL ${PG_VERSION} installed."
fi

PG_SERVICE="postgresql"
systemctl enable "$PG_SERVICE" --quiet
systemctl start "$PG_SERVICE"

# Set port (if not default)
if [[ "$PG_PORT" != "5432" ]]; then
  PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
  if [[ -f "$PG_CONF" ]]; then
    tmp=$(mktemp)
    sed "s/^#*port = .*/port = ${PG_PORT}/" "$PG_CONF" > "$tmp" && mv "$tmp" "$PG_CONF"
  fi
  systemctl restart "$PG_SERVICE"
fi

# Create database and user
step "Creating database '${DB_NAME}' and user '${DB_USER}'..."
sudo -u postgres psql -p "$PG_PORT" << PGSQL
CREATE USER "${DB_USER}" WITH PASSWORD '${DB_PASSWORD}';
CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}" ENCODING 'UTF8' TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO "${DB_USER}";
PGSQL
success "Database and user created."

# Extensions
if [[ "$PG_EXTENSIONS" == "true" ]]; then
  step "Installing PostgreSQL extensions..."
  pkg_install "postgresql-${PG_VERSION}-pgroonga" 2> /dev/null || true
  sudo -u postgres psql -p "$PG_PORT" -d "$DB_NAME" << PGEXT 2> /dev/null
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "hstore";
PGEXT
  success "Extensions installed (uuid-ossp, pg_trgm, hstore)."
fi

# Performance tuning
if [[ "$PG_TUNE" == "true" ]]; then
  step "Applying PGTune-based performance settings..."
  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
  CPU_CORES=$(nproc)

  SHARED_BUFFERS_MB=$((TOTAL_RAM_MB / 4))
  EFFECTIVE_CACHE_MB=$((TOTAL_RAM_MB * 3 / 4))
  WORK_MEM_MB=$((TOTAL_RAM_MB / 64))
  MAINTENANCE_MB=$((TOTAL_RAM_MB / 8))

  PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
  [[ -f "$PG_CONF" ]] && backup_file "$PG_CONF"

  cat > "/etc/postgresql/${PG_VERSION}/main/conf.d/laravel-tuning.conf" << EOF
# PGTune-style settings — generated by laravel-server-setup

# Memory
shared_buffers = ${SHARED_BUFFERS_MB}MB
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
work_mem = ${WORK_MEM_MB}MB
maintenance_work_mem = ${MAINTENANCE_MB}MB

# Parallelism
max_worker_processes = ${CPU_CORES}
max_parallel_workers_per_gather = $((CPU_CORES / 2))
max_parallel_workers = ${CPU_CORES}

# Write-Ahead Log
wal_buffers = 16MB
checkpoint_completion_target = 0.9
checkpoint_timeout = 10min
max_wal_size = 2GB
min_wal_size = 80MB

# Query planning
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100

# Connections
max_connections = 150

# Logging
log_slow_statements = all
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
EOF

  systemctl restart "$PG_SERVICE"
  success "PostgreSQL tuned (shared_buffers: ${SHARED_BUFFERS_MB}MB)."
fi

# PHP extension
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
if has_cmd php; then
  step "Installing PHP PostgreSQL extension (php${PHP_VERSION}-pgsql)..."
  pkg_install "php${PHP_VERSION}-pgsql" 2> /dev/null && {
    systemctl restart "php${PHP_VERSION}-fpm" 2> /dev/null || true
    success "php${PHP_VERSION}-pgsql installed."
  } || warn "Could not install php${PHP_VERSION}-pgsql — install manually."
fi

# Save credentials
creds_section "PostgreSQL"
creds_save "DB_ENGINE" "PostgreSQL ${PG_VERSION}"
creds_save "DB_SERVICE" "postgresql"
creds_save "DB_CONNECTION" "pgsql"
creds_save "DB_HOST" "127.0.0.1"
creds_save "DB_PORT" "$PG_PORT"
creds_save "DB_NAME" "$DB_NAME"
creds_save "DB_USER" "$DB_USER"
creds_save "DB_PASSWORD" "$DB_PASSWORD"

echo
success "PostgreSQL module complete."
info "Laravel .env values:"
dim "DB_CONNECTION=pgsql"
dim "DB_HOST=127.0.0.1"
dim "DB_PORT=${PG_PORT}"
dim "DB_DATABASE=${DB_NAME}"
dim "DB_USERNAME=${DB_USER}"
dim "DB_PASSWORD=${DB_PASSWORD}"
