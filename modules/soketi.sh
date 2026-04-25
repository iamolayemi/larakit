#!/usr/bin/env bash
# =============================================================================
#  Module — Soketi
#  Self-hosted, Pusher-compatible WebSocket server for Laravel Broadcasting.
#  Run standalone: sudo bash modules/soketi.sh
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

module_header "Soketi" "Self-hosted Pusher-compatible WebSocket server — drop-in replacement for Pusher Channels."
require_root

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"

# Detect existing install
if has_cmd soketi; then
  CURRENT_VER=$(soketi --version 2> /dev/null || echo "unknown")
  warn "Soketi already installed: ${CURRENT_VER}"
  ask_choice EXISTING_MODE "Soketi detected — what to do?" \
    "Reconfigure only (keep existing binary)" \
    "Reinstall" \
    "Skip this module"
  case "$EXISTING_MODE" in
    "Skip"*)
      info "Skipping."
      exit 0
      ;;
    "Reinstall"*) : ;;
    *) SKIP_INSTALL=true ;;
  esac
fi

ask SOKETI_PORT "Soketi WebSocket port" "6001"
ask SOKETI_METRICS_PORT "Soketi metrics port" "9601"
ask SOKETI_APP_ID "Default app ID" "app-id"
ask SOKETI_APP_KEY "Default app key" "app-key"

SOKETI_APP_SECRET="$(gen_secret 32)"
warn "Generated app secret: ${SOKETI_APP_SECRET}"
ask_yn USE_GEN_SECRET "Use generated app secret?" "y"
[[ "$USE_GEN_SECRET" != "true" ]] && ask_secret SOKETI_APP_SECRET "Soketi app secret"

ask_yn NGINX_PROXY "Proxy Soketi via Nginx (port 443 → ${SOKETI_PORT})?" "y"
[[ "$NGINX_PROXY" == "true" ]] && ask SOKETI_SUBDOMAIN "Soketi subdomain (or leave blank to use /ws path on main domain)" "ws.${APP_DOMAIN:-example.com}"

echo
confirm_or_exit "Install Soketi?"

# Node.js prerequisite
if ! has_cmd node; then
  step "Installing Node.js (required by Soketi)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
  pkg_install nodejs
fi

# Install Soketi
if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Installing Soketi globally via npm..."
  npm install -g @soketi/soketi > /dev/null 2>&1
  success "Soketi installed ($(soketi --version 2> /dev/null || echo 'latest'))."
fi

# Config file
step "Writing Soketi configuration..."
mkdir -p /etc/soketi
cat > /etc/soketi/config.json << JSON
{
  "debug": false,
  "port": ${SOKETI_PORT},
  "appManager.driver": "array",
  "appManager.array.apps": [
    {
      "id": "${SOKETI_APP_ID}",
      "key": "${SOKETI_APP_KEY}",
      "secret": "${SOKETI_APP_SECRET}",
      "webhooks": [],
      "maxConnections": -1,
      "enableClientMessages": false,
      "enabled": true,
      "enableUserAuthentication": false
    }
  ],
  "metrics.enabled": true,
  "metrics.driver": "prometheus",
  "metrics.port": ${SOKETI_METRICS_PORT}
}
JSON
success "Config written to /etc/soketi/config.json."

# Systemd service
step "Creating Soketi systemd service..."
SOKETI_BIN="$(command -v soketi)"
cat > /etc/systemd/system/soketi.service << EOF
[Unit]
Description=Soketi WebSocket Server
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
ExecStart=${SOKETI_BIN} start --config=/etc/soketi/config.json
Restart=always
RestartSec=5
LimitNOFILE=65536
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable soketi --quiet
systemctl restart soketi
success "Soketi service running on port ${SOKETI_PORT}."

# Nginx proxy
if [[ "$NGINX_PROXY" == "true" ]] && [[ -n "${SOKETI_SUBDOMAIN:-}" ]]; then
  step "Configuring Nginx proxy for Soketi..."
  cat > /etc/nginx/sites-available/soketi << NGINX
server {
    listen 80;
    server_name ${SOKETI_SUBDOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${SOKETI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/soketi /etc/nginx/sites-enabled/soketi 2> /dev/null || true
  nginx -t && systemctl reload nginx
  success "Nginx proxy configured: http://${SOKETI_SUBDOMAIN}"
fi

add_firewall_rule "$SOKETI_PORT" tcp 2> /dev/null || true

creds_section "Soketi"
creds_save "SOKETI_APP_ID" "$SOKETI_APP_ID"
creds_save "SOKETI_APP_KEY" "$SOKETI_APP_KEY"
creds_save "SOKETI_APP_SECRET" "$SOKETI_APP_SECRET"
creds_save "SOKETI_PORT" "$SOKETI_PORT"
creds_save "SOKETI_HOST" "${SOKETI_SUBDOMAIN:-127.0.0.1}"

echo
success "Soketi module complete."
info "Laravel .env values:"
dim "BROADCAST_DRIVER=pusher"
dim "PUSHER_APP_ID=${SOKETI_APP_ID}"
dim "PUSHER_APP_KEY=${SOKETI_APP_KEY}"
dim "PUSHER_APP_SECRET=${SOKETI_APP_SECRET}"
dim "PUSHER_HOST=${SOKETI_SUBDOMAIN:-127.0.0.1}"
dim "PUSHER_PORT=${SOKETI_PORT}"
dim "PUSHER_SCHEME=https"
dim "PUSHER_APP_CLUSTER=mt1"
