#!/usr/bin/env bash
# =============================================================================
#  Module 28 — pgAdmin 4
#  Web-based PostgreSQL administration behind Nginx + HTTP Basic Auth.
#  Run standalone: sudo bash modules/28-pgadmin.sh
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

module_header "pgAdmin 4" "Web-based PostgreSQL administration behind Nginx and HTTP Basic Auth."
require_root

# Detect existing
if has_cmd pgadmin4 || [[ -d "/var/lib/pgadmin" ]]; then
  if [[ "${LARAKIT_FORCE:-false}" == "true" ]]; then
    step "Force mode — reinstalling pgAdmin..."
  else
    ask_choice PGA_EXISTING "pgAdmin already installed. What would you like to do?" \
      "reconfigure — update Nginx and HTTP auth" \
      "reinstall   — fresh install" \
      "skip        — leave as-is"
    PGA_EXISTING="${PGA_EXISTING%% *}"
    case "$PGA_EXISTING" in
      skip)
        info "Skipping pgAdmin."
        exit 0
        ;;
      reconfigure) goto_config=true ;;
      reinstall) : ;;
    esac
  fi
fi

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask PGA_DOMAIN "Subdomain for pgAdmin (e.g. pgadmin.example.com)" "pgadmin.${APP_DOMAIN:-example.com}"
ask PGA_EMAIL "pgAdmin admin email" "admin@${APP_DOMAIN:-example.com}"
PGA_PASSWORD="$(creds_load PGA_PASSWORD 2> /dev/null || gen_password 20)"
ask PGA_PASSWORD "pgAdmin admin password" "$PGA_PASSWORD"

ask_yn RESTRICT_IP "Restrict access to a specific IP?" "n"
if [[ "$RESTRICT_IP" == "true" ]]; then
  ask ALLOWED_IP "Your IP address (leave blank to detect)" ""
  if [[ -z "$ALLOWED_IP" ]]; then
    ALLOWED_IP="$(curl -fsSL https://ifconfig.me 2> /dev/null || echo "0.0.0.0")"
    info "Detected your public IP: ${ALLOWED_IP}"
  fi
fi

echo
confirm_or_exit "Install pgAdmin 4 on ${PGA_DOMAIN}?"

# ---- Install pgAdmin --------------------------------------------------------
if [[ "${goto_config:-false}" != "true" ]]; then
  step "Adding pgAdmin APT repository..."
  pkg_install curl ca-certificates

  PGA_REPO_KEY="/usr/share/keyrings/pgadmin-keyring.gpg"
  curl -fsSL "https://www.pgadmin.org/static/packages_pgadmin_org.pub" \
    | gpg --dearmor -o "$PGA_REPO_KEY"

  detect_os 2> /dev/null || true
  distro="${OS_CODENAME:-jammy}"

  echo "deb [signed-by=${PGA_REPO_KEY}] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${distro} pgadmin4 main" \
    > /etc/apt/sources.list.d/pgadmin4.list

  step "Installing pgadmin4-web..."
  run_or_dry apt-get update -qq
  run_or_dry pkg_install pgadmin4-web

  # Configure pgAdmin — create initial admin account non-interactively
  step "Configuring pgAdmin..."
  if [[ -f "/usr/pgadmin4/bin/setup-web.sh" ]]; then
    PGADMIN_SETUP_EMAIL="$PGA_EMAIL" \
      PGADMIN_SETUP_PASSWORD="$PGA_PASSWORD" \
      run_or_dry /usr/pgadmin4/bin/setup-web.sh --yes 2> /dev/null || true
  fi
  success "pgAdmin installed."
fi

# ---- Nginx vhost ------------------------------------------------------------
step "Writing Nginx vhost for ${PGA_DOMAIN}..."
VHOST_FILE="/etc/nginx/sites-available/${PGA_DOMAIN}"
backup_file "$VHOST_FILE" 2> /dev/null || true

IP_RESTRICT_BLOCK=""
if [[ "$RESTRICT_IP" == "true" ]]; then
  IP_RESTRICT_BLOCK="    allow ${ALLOWED_IP};
    deny all;"
fi

# pgAdmin ships its own WSGI app; use the Apache/Nginx config it creates
# or write a minimal proxy pass to its gunicorn socket
PGA_SOCKET="/run/pgadmin4/gunicorn.sock"

cat > "$VHOST_FILE" << NGINX
server {
    listen 80;
    server_name ${PGA_DOMAIN};

    access_log /var/log/nginx/${PGA_DOMAIN}-access.log;
    error_log  /var/log/nginx/${PGA_DOMAIN}-error.log;

    location / {
        proxy_pass         http://unix:${PGA_SOCKET}:/;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
${IP_RESTRICT_BLOCK}
    }

    location /static/ {
        alias /usr/pgadmin4/web/pgadmin/static/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    client_max_body_size 16M;
}
NGINX

run_or_dry ln -sf "$VHOST_FILE" "/etc/nginx/sites-enabled/${PGA_DOMAIN}" 2> /dev/null || true
nginx -t && run_or_dry systemctl reload nginx
success "Nginx vhost created for ${PGA_DOMAIN}."

# Enable and start pgAdmin service if present
if systemctl list-unit-files pgadmin4.service &> /dev/null; then
  run_or_dry systemctl enable pgadmin4
  run_or_dry systemctl start pgadmin4
  success "pgAdmin service started."
fi

# ---- Credentials ------------------------------------------------------------
creds_section "pgAdmin"
creds_save PGA_DOMAIN "$PGA_DOMAIN"
creds_save PGA_EMAIL "$PGA_EMAIL"
creds_save PGA_PASSWORD "$PGA_PASSWORD"

echo
success "pgAdmin module complete."
info "URL:      http://${PGA_DOMAIN}  (add SSL with: larakit install ssl)"
info "Email:    ${PGA_EMAIL}"
info "Password: ${PGA_PASSWORD}"
warn "Secure this interface: use SSL and restrict access to trusted IPs."
