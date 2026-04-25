#!/usr/bin/env bash
# =============================================================================
#  Module — PHP Installation & Configuration
#  Run standalone: sudo bash modules/php.sh
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

module_header "PHP Installation" "Installs PHP via ondrej/php PPA with all Laravel-required extensions."
require_root
detect_os

# Version selection
ask_choice PHP_VERSION "Select PHP version to install:" \
  "8.5 (Latest — 2026)" \
  "8.4 (Stable — recommended)" \
  "8.3 (Stable)" \
  "8.2 (Security fixes only)"

PHP_VERSION="${PHP_VERSION%% *}" # strip description

info "Will install PHP ${PHP_VERSION}"

# Extensions
BASE_EXTENSIONS=(
  "php${PHP_VERSION}"
  "php${PHP_VERSION}-fpm"
  "php${PHP_VERSION}-cli"
  "php${PHP_VERSION}-common"
  "php${PHP_VERSION}-mysql"
  "php${PHP_VERSION}-pgsql"
  "php${PHP_VERSION}-sqlite3"
  "php${PHP_VERSION}-redis"
  "php${PHP_VERSION}-mbstring"
  "php${PHP_VERSION}-xml"
  "php${PHP_VERSION}-curl"
  "php${PHP_VERSION}-zip"
  "php${PHP_VERSION}-gd"
  "php${PHP_VERSION}-intl"
  "php${PHP_VERSION}-bcmath"
  "php${PHP_VERSION}-soap"
  "php${PHP_VERSION}-tokenizer"
  "php${PHP_VERSION}-fileinfo"
  "php${PHP_VERSION}-exif"
  "php${PHP_VERSION}-opcache"
)

ask_yn INSTALL_IMAGICK "Install imagick extension?" "y"
[[ "$INSTALL_IMAGICK" == "true" ]] && BASE_EXTENSIONS+=("php${PHP_VERSION}-imagick" "imagemagick")

ask_yn INSTALL_MEMCACHED "Install memcached extension?" "n"
[[ "$INSTALL_MEMCACHED" == "true" ]] && BASE_EXTENSIONS+=("php${PHP_VERSION}-memcached" "memcached")

ask_yn INSTALL_SWOOLE "Install Swoole extension (needed for Octane)?" "n"
[[ "$INSTALL_SWOOLE" == "true" ]] && BASE_EXTENSIONS+=("php${PHP_VERSION}-swoole")

echo
confirm_or_exit "Install PHP ${PHP_VERSION} and extensions?"

# Add PPA
step "Adding ondrej/php PPA..."
if ! grep -q "ondrej/php" /etc/apt/sources.list.d/*.list 2> /dev/null; then
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
  apt-get update -qq
fi
success "PPA ready."

# Install PHP
step "Installing PHP ${PHP_VERSION} and extensions..."
pkg_install "${BASE_EXTENSIONS[@]}"
success "PHP ${PHP_VERSION} installed."

# PHP-FPM tuning
PHP_FPM_CONF="/etc/php/${PHP_VERSION}/fpm/php.ini"
backup_file "$PHP_FPM_CONF"

# Sensible production defaults
tmp=$(mktemp)
sed \
  -e "s/upload_max_filesize = .*/upload_max_filesize = 64M/" \
  -e "s/post_max_size = .*/post_max_size = 64M/" \
  -e "s/memory_limit = .*/memory_limit = 256M/" \
  -e "s/max_execution_time = .*/max_execution_time = 60/" \
  -e "s/;date.timezone =.*/date.timezone = UTC/" \
  "$PHP_FPM_CONF" > "$tmp" && mv "$tmp" "$PHP_FPM_CONF"

# OPcache (huge performance boost)
cat >> "$PHP_FPM_CONF" << EOF

; OPcache (added by laravel-server-setup)
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.fast_shutdown=1
EOF

# PHP CLI also
CLI_CONF="/etc/php/${PHP_VERSION}/cli/php.ini"
backup_file "$CLI_CONF"
tmp=$(mktemp)
sed \
  -e "s/memory_limit = .*/memory_limit = 512M/" \
  -e "s/;date.timezone =.*/date.timezone = UTC/" \
  "$CLI_CONF" > "$tmp" && mv "$tmp" "$CLI_CONF"

# Restart FPM
systemctl enable "php${PHP_VERSION}-fpm" --quiet
systemctl restart "php${PHP_VERSION}-fpm"
success "PHP-FPM configured and running."

# Composer
ask_choice COMPOSER_VERSION "Select Composer version:" \
  "2.x (Latest — recommended)" \
  "2.7 (Stable)" \
  "2.6 (Previous stable)"

COMPOSER_VERSION="${COMPOSER_VERSION%% *}" # strip label, keep e.g. "2.x" / "2.7" / "2.6"

step "Installing Composer..."
# Download the phar directly — the PHP installer script internally uses PHP's
# HTTP client which hangs on many VPS providers. curl has proper timeouts.
# composer-2.phar = latest 2.x; composer-stable.phar = latest stable (same thing today)
case "$COMPOSER_VERSION" in
  2.7 | 2.6) COMPOSER_PHAR_URL="https://getcomposer.org/composer-2.phar" ;;
  *) COMPOSER_PHAR_URL="https://getcomposer.org/composer-stable.phar" ;;
esac

if has_cmd composer; then
  CURRENT_COMPOSER=$(composer --version 2> /dev/null | awk '{print $3}')
  info "Composer ${CURRENT_COMPOSER} already installed — replacing with fresh phar..."
fi

run_or_dry curl -fsSL --max-time 60 --retry 3 --progress-bar "$COMPOSER_PHAR_URL" -o /tmp/composer.phar

# Sanity-check: phar must be >500KB (a truncated download is ~0 bytes)
PHAR_SIZE=$(wc -c < /tmp/composer.phar 2> /dev/null || echo 0)
if [[ "$PHAR_SIZE" -lt 500000 ]]; then
  error "Composer download looks incomplete (${PHAR_SIZE} bytes). Check connectivity."
  rm -f /tmp/composer.phar
  exit 1
fi

run_or_dry mv /tmp/composer.phar /usr/local/bin/composer
run_or_dry chmod +x /usr/local/bin/composer
success "Composer $(composer --version 2> /dev/null | awk '{print $3}') installed."

# Update alternatives (if multiple PHP versions)
update-alternatives --set php "/usr/bin/php${PHP_VERSION}" 2> /dev/null || true

# Save state
creds_section "PHP"
creds_save "PHP_VERSION" "$PHP_VERSION"
creds_save "PHP_FPM_SOCK" "/run/php/php${PHP_VERSION}-fpm.sock"
creds_save "COMPOSER_VERSION" "$(composer --version 2> /dev/null | awk '{print $3}')"

echo
php -v
echo
success "PHP module complete."
