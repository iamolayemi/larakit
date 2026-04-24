#!/usr/bin/env bash
# =============================================================================
#  Module 26 — Monitoring & Observability
#  Installs Netdata (real-time metrics) + UptimeKuma (uptime monitoring)
#  Run standalone: sudo bash modules/26-monitoring.sh
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

module_header "Monitoring & Observability" "Real-time server metrics and uptime monitoring for your Laravel stack."
require_root

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask_yn INSTALL_NETDATA "Install Netdata (real-time server metrics dashboard)?" "y"
ask_yn INSTALL_UPTIME_KUMA "Install UptimeKuma (uptime/status page)?" "y"
ask_yn INSTALL_FAIL2BAN_LOGS "Set up fail2ban + Laravel log monitoring in Netdata?" "y"

if [[ "$INSTALL_UPTIME_KUMA" == "true" ]]; then
  ask UPTIME_KUMA_PORT "UptimeKuma port" "3001"
  ask_yn KUMA_NGINX_PROXY "Proxy UptimeKuma via Nginx?" "y"
  [[ "$KUMA_NGINX_PROXY" == "true" ]] && ask KUMA_SUBDOMAIN "UptimeKuma subdomain" "status.${APP_DOMAIN:-example.com}"
fi

if [[ "$INSTALL_NETDATA" == "true" ]]; then
  ask NETDATA_PORT "Netdata port" "19999"
  ask_yn NETDATA_PUBLIC "Expose Netdata publicly (via Nginx with auth)?" "n"
  if [[ "$NETDATA_PUBLIC" == "true" ]]; then
    NETDATA_USER="netdata-admin"
    NETDATA_PASS="$(gen_password 16)"
    ask NETDATA_USER "Netdata admin username" "$NETDATA_USER"
    warn "Generated Netdata password: ${NETDATA_PASS}"
    ask_yn USE_GEN_NETDATA "Use generated password?" "y"
    [[ "$USE_GEN_NETDATA" != "true" ]] && ask_secret NETDATA_PASS "Netdata password"
  fi
fi

echo
confirm_or_exit "Install monitoring stack?"

# Netdata
if [[ "$INSTALL_NETDATA" == "true" ]]; then
  step "Installing Netdata..."
  if has_cmd netdata; then
    info "Netdata already installed. Updating..."
    netdata-claim.sh -token="" -rooms="" -url="" 2> /dev/null || true
  else
    curl -fsSL https://get.netdata.cloud/kickstart.sh | bash -s -- --dont-wait --no-updates --stable-channel > /dev/null 2>&1 &
    pid=$!
    spinner "$pid" "Installing Netdata (this takes a minute)..."
    wait "$pid"
  fi

  systemctl enable netdata --quiet
  systemctl start netdata

  # Bind to localhost by default (expose via Nginx if needed)
  NETDATA_CONF="/etc/netdata/netdata.conf"
  if [[ -f "$NETDATA_CONF" ]]; then
    tmp=$(mktemp)
    sed "s/.*bind to.*/    bind to = 127.0.0.1/" "$NETDATA_CONF" > "$tmp" && mv "$tmp" "$NETDATA_CONF"
    systemctl restart netdata
  fi

  success "Netdata running on port ${NETDATA_PORT}."

  # Laravel-specific Netdata config
  if [[ "$INSTALL_FAIL2BAN_LOGS" == "true" ]]; then
    APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
    if [[ -n "$APP_PATH" ]]; then
      mkdir -p /etc/netdata/go.d/
      cat > /etc/netdata/go.d/web_log.conf << EOF
jobs:
  - name: nginx_${APP_DOMAIN//./_}
    path: /var/log/nginx/${APP_DOMAIN:-app}-access.log

  - name: laravel
    path: ${APP_PATH}/storage/logs/laravel.log
    log_type: csv
EOF
      systemctl restart netdata 2> /dev/null || true
    fi
  fi

  # Nginx proxy for Netdata (with auth)
  if [[ "$NETDATA_PUBLIC" == "true" ]]; then
    pkg_install apache2-utils -y -q 2> /dev/null || true
    htpasswd -bc /etc/nginx/.htpasswd-netdata "$NETDATA_USER" "$NETDATA_PASS" 2> /dev/null

    cat > /etc/nginx/sites-available/netdata << NGINX
server {
    listen 80;
    server_name netdata.${APP_DOMAIN:-localhost};

    location / {
        auth_basic "Netdata";
        auth_basic_user_file /etc/nginx/.htpasswd-netdata;
        proxy_pass http://127.0.0.1:${NETDATA_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/netdata /etc/nginx/sites-enabled/netdata 2> /dev/null || true
    nginx -t && systemctl reload nginx && success "Netdata exposed at http://netdata.${APP_DOMAIN}."

    creds_save "NETDATA_URL" "http://netdata.${APP_DOMAIN}"
    creds_save "NETDATA_USER" "$NETDATA_USER"
    creds_save "NETDATA_PASSWORD" "$NETDATA_PASS"
  fi
fi

# UptimeKuma
if [[ "$INSTALL_UPTIME_KUMA" == "true" ]]; then
  step "Installing UptimeKuma..."

  # Install Node.js if not present
  if ! has_cmd node; then
    pkg_install nodejs npm
  fi

  # Install via npm globally
  if ! has_cmd uptime-kuma; then
    npm install -g uptime-kuma 2> /dev/null || {
      # Alternative: Docker or manual install
      pkg_install docker.io 2> /dev/null || true
      systemctl start docker 2> /dev/null || true
      docker run -d \
        --restart unless-stopped \
        -p "${UPTIME_KUMA_PORT}":3001 \
        -v uptime-kuma:/app/data \
        --name uptime-kuma \
        louislam/uptime-kuma:1 > /dev/null 2>&1 || warn "Docker install of UptimeKuma failed — install manually."
    }
  fi

  # Systemd service
  cat > /etc/systemd/system/uptime-kuma.service << EOF
[Unit]
Description=Uptime Kuma
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/uptime-kuma
ExecStart=node /usr/lib/node_modules/uptime-kuma/server/server.js
Restart=always
Environment=PORT=${UPTIME_KUMA_PORT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable uptime-kuma --quiet 2> /dev/null || true
  systemctl start uptime-kuma 2> /dev/null || true
  success "UptimeKuma service configured on port ${UPTIME_KUMA_PORT}."

  # Nginx proxy
  if [[ "$KUMA_NGINX_PROXY" == "true" ]] && [[ -n "${KUMA_SUBDOMAIN:-}" ]]; then
    cat > /etc/nginx/sites-available/uptime-kuma << NGINX
server {
    listen 80;
    server_name ${KUMA_SUBDOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${UPTIME_KUMA_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/uptime-kuma /etc/nginx/sites-enabled/uptime-kuma 2> /dev/null || true
    nginx -t && systemctl reload nginx
    creds_save "UPTIME_KUMA_URL" "http://${KUMA_SUBDOMAIN}"
    success "UptimeKuma available at: http://${KUMA_SUBDOMAIN}"
  fi

  open_port=false
  add_firewall_rule "$UPTIME_KUMA_PORT" tcp 2> /dev/null || true
fi

# Telescope tip
echo
info "Tip: Install Laravel Telescope for in-app observability:"
dim "composer require laravel/telescope && php artisan telescope:install && php artisan migrate"

creds_section "Monitoring"
[[ "$INSTALL_NETDATA" == "true" ]] && creds_save "NETDATA_LOCAL" "http://localhost:${NETDATA_PORT}"
[[ "$INSTALL_UPTIME_KUMA" == "true" ]] && creds_save "UPTIME_KUMA_LOCAL" "http://localhost:${UPTIME_KUMA_PORT}"

success "Monitoring module complete."
