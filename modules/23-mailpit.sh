#!/usr/bin/env bash
# =============================================================================
#  Module 23 — Mailpit
#  SMTP mail catcher with web UI. Ideal for staging/dev environments.
#  Run standalone: sudo bash modules/23-mailpit.sh
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

module_header "Mailpit" "SMTP mail interceptor with web UI for staging and development."
require_root
detect_os

warn "Mailpit is intended for staging/dev environments, not production mail delivery."
ask_yn CONTINUE_MAILPIT "Continue installing Mailpit?" "y"
[[ "$CONTINUE_MAILPIT" != "true" ]] && {
  info "Skipping."
  exit 0
}

if has_cmd mailpit; then
  warn "Mailpit is already installed."
  ask_choice MP_ACTION "What would you like to do?" \
    "Reconfigure only" \
    "Reinstall" \
    "Skip this module"
  case "$MP_ACTION" in
    "Skip"*)
      info "Skipping."
      exit 0
      ;;
    "Reinstall"*) : ;;
    *) SKIP_INSTALL=true ;;
  esac
fi

ask_choice MP_VERSION "Select Mailpit version:" \
  "v1.21 (Latest)" \
  "v1.20 (Stable)" \
  "v1.19 (Previous)"
MP_VERSION="${MP_VERSION%% *}"

ask MP_SMTP_PORT "SMTP listen port" "1025"
ask MP_WEB_PORT "Web UI port" "8025"

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Downloading Mailpit ${MP_VERSION}..."
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" ]] && GOARCH="arm64" || GOARCH="amd64"
  MP_URL="https://github.com/axllent/mailpit/releases/download/${MP_VERSION}/mailpit-linux-${GOARCH}.tar.gz"
  TMP_DIR=$(mktemp -d)
  curl -fsSL "$MP_URL" | tar -xz -C "$TMP_DIR"
  mv "${TMP_DIR}/mailpit" /usr/local/bin/mailpit
  chmod +x /usr/local/bin/mailpit
  rm -rf "$TMP_DIR"
  success "Mailpit binary installed."
fi

step "Writing systemd service..."
cat > /etc/systemd/system/mailpit.service << EOF
[Unit]
Description=Mailpit Mail Catcher
After=network.target

[Service]
ExecStart=/usr/local/bin/mailpit \\
  --smtp 0.0.0.0:${MP_SMTP_PORT} \\
  --listen 0.0.0.0:${MP_WEB_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --quiet mailpit
systemctl restart mailpit
success "Mailpit running — SMTP :${MP_SMTP_PORT}, UI :${MP_WEB_PORT}."

add_firewall_rule "$MP_SMTP_PORT" tcp 2> /dev/null || true
add_firewall_rule "$MP_WEB_PORT" tcp 2> /dev/null || true

ask_yn SETUP_NGINX_MP "Set up Nginx proxy for Mailpit web UI?" "y"
if [[ "$SETUP_NGINX_MP" == "true" ]]; then
  ask MP_DOMAIN "Mailpit web UI domain (e.g. mail.example.com)" ""
  if [[ -n "$MP_DOMAIN" ]] && has_cmd nginx; then
    cat > "/etc/nginx/sites-available/mailpit" << NGINXEOF
server {
    listen 80;
    server_name ${MP_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${MP_WEB_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
    }
}
NGINXEOF
    ln -sf /etc/nginx/sites-available/mailpit /etc/nginx/sites-enabled/mailpit
    nginx -t && systemctl reload nginx
    success "Nginx proxy configured for ${MP_DOMAIN}."
    creds_save "MAILPIT_DOMAIN" "$MP_DOMAIN"
  fi
fi

creds_section "Mailpit"
creds_save "MAILPIT_VERSION" "$MP_VERSION"
creds_save "MAILPIT_SMTP_PORT" "$MP_SMTP_PORT"
creds_save "MAILPIT_WEB_PORT" "$MP_WEB_PORT"

echo
info "Add to your Laravel .env:"
echo -e "  ${DIM}MAIL_MAILER=smtp"
echo -e "  MAIL_HOST=127.0.0.1"
echo -e "  MAIL_PORT=${MP_SMTP_PORT}"
echo -e "  MAIL_USERNAME=null"
echo -e "  MAIL_PASSWORD=null"
echo -e "  MAIL_ENCRYPTION=null${NC}"
echo
success "Mailpit module complete."
