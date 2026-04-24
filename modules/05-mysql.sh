#!/usr/bin/env bash
# =============================================================================
#  Module 05 — MySQL / MariaDB Database
#  Run standalone: sudo bash modules/05-mysql.sh
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
fi

module_header "Database Server" "Installs MySQL or MariaDB, creates app database and user."
require_root

# DB engine selection
ask_choice DB_ENGINE "Select database engine:" \
  "MySQL 9.2 (Latest)" \
  "MySQL 8.4 (LTS)" \
  "MySQL 8.0 (Legacy LTS)" \
  "MariaDB 11.7 (Latest)" \
  "MariaDB 11.4 (LTS)" \
  "MariaDB 10.11 (LTS)"

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
if [[ "$USE_GENERATED_PASS" != "true" ]]; then
  ask_secret DB_PASSWORD "Enter a custom DB password"
fi

MYSQL_ROOT_PASS="$(gen_password 28)"
warn "Generated MySQL root password: ${MYSQL_ROOT_PASS}"
ask_yn USE_GENERATED_ROOT "Use this generated root password?" "y"
if [[ "$USE_GENERATED_ROOT" != "true" ]]; then
  ask_secret MYSQL_ROOT_PASS "Enter MySQL root password"
fi

echo
info "Installation plan:"
dim "Engine:    ${DB_ENGINE}"
dim "Database:  ${DB_NAME}"
dim "DB User:   ${DB_USER}"
echo
confirm_or_exit "Install database server?"

# Install engine
case "$DB_ENGINE" in
  "MySQL 9.2"*)
    step "Installing MySQL 9.2..."
    curl -fsSL https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb -o /tmp/mysql-apt-config.deb
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb > /dev/null 2>&1 || true
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive pkg_install mysql-server
    DB_SERVICE="mysql"
    ;;
  "MySQL 8.4"*)
    step "Installing MySQL 8.4 (LTS)..."
    curl -fsSL https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb -o /tmp/mysql-apt-config.deb
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/mysql-apt-config.deb > /dev/null 2>&1 || true
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive pkg_install "mysql-server=8.4*" \
      || DEBIAN_FRONTEND=noninteractive pkg_install mysql-server
    DB_SERVICE="mysql"
    ;;
  "MySQL 8.0"*)
    step "Installing MySQL 8.0..."
    pkg_install mysql-server
    DB_SERVICE="mysql"
    ;;
  "MariaDB 11.7"*)
    step "Installing MariaDB 11.7..."
    curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-11.7" > /dev/null 2>&1
    apt-get update -qq
    pkg_install mariadb-server
    DB_SERVICE="mariadb"
    ;;
  "MariaDB 11.4"*)
    step "Installing MariaDB 11.4 (LTS)..."
    curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-11.4" > /dev/null 2>&1
    apt-get update -qq
    pkg_install mariadb-server
    DB_SERVICE="mariadb"
    ;;
  "MariaDB 10.11"*)
    step "Installing MariaDB 10.11 (LTS)..."
    curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-10.11" > /dev/null 2>&1
    apt-get update -qq
    pkg_install mariadb-server
    DB_SERVICE="mariadb"
    ;;
esac

systemctl enable "$DB_SERVICE" --quiet
systemctl start "$DB_SERVICE"
success "${DB_ENGINE} installed and running."

# Secure installation
step "Securing database installation..."
mysql --user=root << MYSQL_SECURE
  ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
  DELETE FROM mysql.user WHERE User='';
  DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
  DROP DATABASE IF EXISTS test;
  DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
  FLUSH PRIVILEGES;
MYSQL_SECURE
success "Database secured."

# Create app database & user
step "Creating database '${DB_NAME}' and user '${DB_USER}'..."
mysql --user=root --password="$MYSQL_ROOT_PASS" << MYSQL_SETUP
  CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
  FLUSH PRIVILEGES;
MYSQL_SETUP
success "Database '${DB_NAME}' and user '${DB_USER}' created."

# Performance tuning
ask_yn TUNE_DB "Apply performance tuning for Laravel?" "y"
if [[ "$TUNE_DB" == "true" ]]; then
  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
  IB_POOL_SIZE="$((TOTAL_RAM_MB / 2))M"

  cat > /etc/mysql/conf.d/laravel-tuning.cnf << EOF
[mysqld]
innodb_buffer_pool_size = ${IB_POOL_SIZE}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
query_cache_type = 0
max_connections = 150
thread_cache_size = 16
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
EOF
  systemctl restart "$DB_SERVICE"
  success "Performance tuning applied (InnoDB buffer: ${IB_POOL_SIZE})."
fi

# Save credentials
creds_section "Database"
creds_save "DB_ENGINE" "$DB_ENGINE"
creds_save "DB_SERVICE" "$DB_SERVICE"
creds_save "DB_HOST" "127.0.0.1"
creds_save "DB_PORT" "3306"
creds_save "DB_NAME" "$DB_NAME"
creds_save "DB_USER" "$DB_USER"
creds_save "DB_PASSWORD" "$DB_PASSWORD"
creds_save "DB_ROOT_PASSWORD" "$MYSQL_ROOT_PASS"

echo
success "Database module complete."
info "Laravel .env values:"
dim "DB_CONNECTION=mysql"
dim "DB_HOST=127.0.0.1"
dim "DB_PORT=3306"
dim "DB_DATABASE=${DB_NAME}"
dim "DB_USERNAME=${DB_USER}"
dim "DB_PASSWORD=${DB_PASSWORD}"
