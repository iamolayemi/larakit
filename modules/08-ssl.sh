#!/usr/bin/env bash
# =============================================================================
#  Module 08 — SSL / TLS via Let's Encrypt (Certbot)
#  Run standalone: sudo bash modules/08-ssl.sh
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

module_header "SSL / TLS — Let's Encrypt" "Issues a free SSL certificate and configures auto-renewal."
require_root

# Config
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
ask SSL_DOMAIN "Primary domain for SSL" "${APP_DOMAIN:-}"
[[ -z "$SSL_DOMAIN" ]] && {
  error "Domain cannot be empty."
  exit 1
}

ask_yn HAS_WWW "Also include www.${SSL_DOMAIN}?" "y"
ask SSL_EMAIL "Email for Let's Encrypt notifications" ""
[[ -z "$SSL_EMAIL" ]] && {
  error "Email is required for Let's Encrypt."
  exit 1
}

ask_choice SSL_CHALLENGE "Verification method:" \
  "Nginx (webroot — recommended, requires Nginx running)" \
  "Standalone (temporarily stops Nginx)" \
  "DNS (wildcard certs, requires manual DNS TXT record)"

ask_yn DRY_RUN_FIRST "Do a dry run first to verify everything works?" "y"

echo
confirm_or_exit "Issue SSL certificate for ${SSL_DOMAIN}?"

# Install Certbot
step "Installing Certbot..."
if ! has_cmd certbot; then
  pkg_install snapd
  snap install --classic certbot > /dev/null 2>&1
  ln -sf /snap/bin/certbot /usr/bin/certbot 2> /dev/null || true

  if ! has_cmd certbot; then
    # Fallback to apt
    pkg_install certbot python3-certbot-nginx
  fi
fi
success "Certbot $(certbot --version 2>&1 | awk '{print $2}') ready."

# Build certbot command
CERTBOT_CMD="certbot"
DOMAINS="-d ${SSL_DOMAIN}"
[[ "$HAS_WWW" == "true" ]] && DOMAINS="${DOMAINS} -d www.${SSL_DOMAIN}"

case "$SSL_CHALLENGE" in
  "Nginx"*)
    CERTBOT_CMD="${CERTBOT_CMD} --nginx ${DOMAINS} --email ${SSL_EMAIL} --agree-tos --non-interactive --redirect"
    ;;
  "Standalone"*)
    systemctl stop nginx 2> /dev/null || true
    CERTBOT_CMD="${CERTBOT_CMD} certonly --standalone ${DOMAINS} --email ${SSL_EMAIL} --agree-tos --non-interactive"
    ;;
  "DNS"*)
    CERTBOT_CMD="${CERTBOT_CMD} certonly --manual --preferred-challenges dns ${DOMAINS} --email ${SSL_EMAIL} --agree-tos"
    ;;
esac

# Dry run
if [[ "$DRY_RUN_FIRST" == "true" ]]; then
  step "Running dry run..."
  if eval "${CERTBOT_CMD} --dry-run" 2>&1 | tail -5; then
    success "Dry run passed!"
  else
    error "Dry run failed. Check DNS records and Nginx config before retrying."
    [[ "$SSL_CHALLENGE" == "Standalone"* ]] && systemctl start nginx 2> /dev/null || true
    exit 1
  fi
fi

# Issue certificate
step "Issuing SSL certificate..."
if eval "$CERTBOT_CMD"; then
  success "SSL certificate issued for ${SSL_DOMAIN}!"
else
  error "Certificate issuance failed."
  [[ "$SSL_CHALLENGE" == "Standalone"* ]] && systemctl start nginx 2> /dev/null || true
  exit 1
fi

[[ "$SSL_CHALLENGE" == "Standalone"* ]] && systemctl start nginx 2> /dev/null || true

# Auto-renewal
step "Verifying auto-renewal..."
if certbot renew --dry-run --quiet 2> /dev/null; then
  success "Auto-renewal working (runs twice daily via systemd timer)."
else
  warn "Auto-renewal test failed. Check: systemctl status certbot.timer"
fi

# Also add cron as backup
(
  crontab -l 2> /dev/null
  echo "0 12 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'"
) | sort -u | crontab -

# HTTPS security headers in Nginx
VHOST_FILE="/etc/nginx/sites-available/${SSL_DOMAIN}"
if [[ -f "$VHOST_FILE" ]]; then
  step "Adding HSTS header to Nginx vhost..."
  if ! grep -q "Strict-Transport-Security" "$VHOST_FILE"; then
    tmp=$(mktemp)
    awk '/add_header X-Frame-Options/ {
      print
      print "    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\" always;"
      next
    } { print }' "$VHOST_FILE" > "$tmp" && mv "$tmp" "$VHOST_FILE"
    nginx -t && systemctl reload nginx
    success "HSTS header added."
  fi
fi

# Save
CERT_PATH="/etc/letsencrypt/live/${SSL_DOMAIN}"
creds_section "SSL"
creds_save "SSL_DOMAIN" "$SSL_DOMAIN"
creds_save "SSL_EMAIL" "$SSL_EMAIL"
creds_save "SSL_CERT_PATH" "$CERT_PATH"
creds_save "SSL_EXPIRES" "$(certbot certificates 2> /dev/null | grep -A3 "$SSL_DOMAIN" | grep 'Expiry Date' | awk '{print $3}' || echo "check manually")"

echo
success "SSL module complete."
info "Certificate path: ${CERT_PATH}"
info "Auto-renewal: systemctl status certbot.timer"
