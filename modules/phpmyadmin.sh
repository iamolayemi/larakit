#!/usr/bin/env bash
# =============================================================================
#  Module — phpMyAdmin
#  Web-based MySQL/MariaDB administration behind Nginx + HTTP Basic Auth.
#  Run standalone: sudo bash modules/phpmyadmin.sh
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

module_header "phpMyAdmin" "Web-based MySQL/MariaDB administration behind Nginx and HTTP Basic Auth."
require_root

# Detect existing installation
PMA_DIR="/var/www/phpmyadmin"
if [[ -d "$PMA_DIR" ]]; then
  if [[ "${LARAKIT_FORCE:-false}" == "true" ]]; then
    step "Force mode — reinstalling phpMyAdmin..."
  else
    ask_choice PMA_EXISTING "phpMyAdmin already installed. What would you like to do?" \
      "reconfigure — update Nginx and HTTP auth" \
      "reinstall   — download fresh copy" \
      "skip        — leave as-is"
    PMA_EXISTING="${PMA_EXISTING%% *}"
    case "$PMA_EXISTING" in
      skip)
        info "Skipping phpMyAdmin."
        exit 0
        ;;
      reconfigure) goto_config=true ;;
      reinstall) : ;;
    esac
  fi
fi

# Latest stable phpMyAdmin version (update as new versions release)
PMA_LATEST="5.2.1"
ask PMA_VERSION "phpMyAdmin version" "$PMA_LATEST"

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask PMA_DOMAIN "Subdomain for phpMyAdmin (e.g. pma.example.com)" "pma.${APP_DOMAIN:-example.com}"
ask PMA_ADMIN "HTTP Basic Auth username" "dbadmin"
PMA_PASSWORD="$(creds_load PMA_PASSWORD 2> /dev/null || gen_password 20)"
ask PMA_PASSWORD "HTTP Basic Auth password" "$PMA_PASSWORD"

# Optional IP restriction
ask_yn RESTRICT_IP "Restrict access to a specific IP?" "n"
if [[ "$RESTRICT_IP" == "true" ]]; then
  ask ALLOWED_IP "Your IP address (leave blank to detect)" ""
  if [[ -z "$ALLOWED_IP" ]]; then
    ALLOWED_IP="$(curl -fsSL https://ifconfig.me 2> /dev/null || echo "0.0.0.0")"
    info "Detected your public IP: ${ALLOWED_IP}"
  fi
fi

echo
confirm_or_exit "Install phpMyAdmin ${PMA_VERSION} on ${PMA_DOMAIN}?"

# ---- Download ---------------------------------------------------------------
if [[ "${goto_config:-false}" != "true" ]]; then
  step "Downloading phpMyAdmin ${PMA_VERSION}..."
  PMA_URL="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
  TMP_DIR="$(mktemp -d)"
  curl -fsSL "$PMA_URL" -o "${TMP_DIR}/phpmyadmin.tar.gz"
  tar -xzf "${TMP_DIR}/phpmyadmin.tar.gz" -C "$TMP_DIR"
  run_or_dry mkdir -p "$PMA_DIR"
  run_or_dry rm -rf "${PMA_DIR:?}"/*
  run_or_dry cp -r "${TMP_DIR}/phpMyAdmin-${PMA_VERSION}-all-languages/." "$PMA_DIR/"
  rm -rf "$TMP_DIR"
  success "phpMyAdmin extracted to ${PMA_DIR}."
fi

# ---- Config -----------------------------------------------------------------
step "Writing config.inc.php..."
BLOWFISH_SECRET="$(gen_secret 32)"
run_or_dry cp "${PMA_DIR}/config.sample.inc.php" "${PMA_DIR}/config.inc.php" 2> /dev/null || true

if [[ -f "${PMA_DIR}/config.inc.php" ]]; then
  backup_file "${PMA_DIR}/config.inc.php"
  # Replace blowfish_secret inline (safe: no sed -i)
  tmp=$(mktemp)
  grep -v "blowfish_secret" "${PMA_DIR}/config.inc.php" > "$tmp"
  sed "s/\$cfg\['blowfish_secret'\] = ''/\$cfg['blowfish_secret'] = '${BLOWFISH_SECRET}'/" "$tmp" > "${PMA_DIR}/config.inc.php" || true
  rm -f "$tmp"
fi

run_or_dry chown -R www-data:www-data "$PMA_DIR"
run_or_dry chmod 750 "$PMA_DIR"
run_or_dry chmod 640 "${PMA_DIR}/config.inc.php" 2> /dev/null || true

# ---- HTTP Basic Auth --------------------------------------------------------
step "Creating HTTP Basic Auth credentials..."
if ! has_cmd htpasswd; then
  pkg_install apache2-utils
fi
run_or_dry mkdir -p /etc/nginx/.htpasswd
htpasswd -cb /etc/nginx/.htpasswd/"$PMA_DOMAIN" "$PMA_ADMIN" "$PMA_PASSWORD"
success "Auth file: /etc/nginx/.htpasswd/${PMA_DOMAIN}"

# ---- Nginx vhost ------------------------------------------------------------
step "Writing Nginx vhost for ${PMA_DOMAIN}..."
VHOST_FILE="/etc/nginx/sites-available/${PMA_DOMAIN}"
backup_file "$VHOST_FILE" 2> /dev/null || true

IP_RESTRICT_BLOCK=""
if [[ "$RESTRICT_IP" == "true" ]]; then
  IP_RESTRICT_BLOCK="    allow ${ALLOWED_IP};
    deny all;"
fi

cat > "$VHOST_FILE" << NGINX
server {
    listen 80;
    server_name ${PMA_DOMAIN};
    root ${PMA_DIR};
    index index.php;

    charset utf-8;
    client_max_body_size 64M;

    access_log /var/log/nginx/${PMA_DOMAIN}-access.log;
    error_log  /var/log/nginx/${PMA_DOMAIN}-error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;

        auth_basic "Database Administration";
        auth_basic_user_file /etc/nginx/.htpasswd/${PMA_DOMAIN};
${IP_RESTRICT_BLOCK}
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(ht|git) { deny all; }
    location ~* \.(sql|bak|cfg|log)$ { deny all; }
}
NGINX

run_or_dry ln -sf "$VHOST_FILE" "/etc/nginx/sites-enabled/${PMA_DOMAIN}" 2> /dev/null || true
nginx -t && run_or_dry systemctl reload nginx
success "Nginx vhost created for ${PMA_DOMAIN}."

# ---- Credentials ------------------------------------------------------------
creds_section "phpMyAdmin"
creds_save PMA_DOMAIN "$PMA_DOMAIN"
creds_save PMA_ADMIN "$PMA_ADMIN"
creds_save PMA_PASSWORD "$PMA_PASSWORD"
creds_save PMA_PATH "$PMA_DIR"

echo
success "phpMyAdmin module complete."
info "URL:      http://${PMA_DOMAIN}  (add SSL with: larakit install ssl)"
info "Username: ${PMA_ADMIN}"
info "Password: ${PMA_PASSWORD}"
warn "Secure this interface: use SSL, restrict to VPN/IP, or remove after use."
