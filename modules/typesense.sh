#!/usr/bin/env bash
# =============================================================================
#  Module — Typesense
#  Fast, typo-tolerant search engine — an alternative to Meilisearch for Scout.
#  Run standalone: sudo bash modules/typesense.sh
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

module_header "Typesense" "Fast, typo-tolerant search engine — an alternative to Meilisearch for Laravel Scout"
require_root

TYPESENSE_VERSION="$(creds_load TYPESENSE_VERSION 2> /dev/null || echo "")"
TYPESENSE_PORT="$(creds_load TYPESENSE_PORT 2> /dev/null || echo "8108")"
TYPESENSE_DATA_DIR="$(creds_load TYPESENSE_DATA_DIR 2> /dev/null || echo "/var/lib/typesense")"

if has_cmd typesense-server; then
  INSTALLED_VER=$(typesense-server --version 2> /dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
  warn "Typesense ${INSTALLED_VER} is already installed."
  ask_choice EXISTING_MODE "What would you like to do?" \
    "Reconfigure (keep binary, update settings)" \
    "Reinstall (download fresh binary)" \
    "Skip"
  [[ "$EXISTING_MODE" == "Skip" ]] && {
    info "Skipping Typesense."
    exit 0
  }
  [[ "$EXISTING_MODE" == "Reconfigure"* ]] && SKIP_INSTALL=true
fi

ask_choice VERSION_LABEL "Typesense version" \
  "27.1 (latest stable)" \
  "26.0" \
  "0.25.2 (legacy)"
TYPESENSE_VERSION="${VERSION_LABEL%% *}"

ask TYPESENSE_PORT "Typesense port" "$TYPESENSE_PORT"
ask TYPESENSE_DATA_DIR "Data directory" "$TYPESENSE_DATA_DIR"

TYPESENSE_API_KEY="$(creds_load TYPESENSE_API_KEY 2> /dev/null || gen_secret 32)"
info "API key: ${TYPESENSE_API_KEY}"
echo -e "  ${DIM}(a new key will be used if this is a fresh install)${NC}"

ask_yn ADD_PROXY "Add an Nginx proxy for Typesense?" "n"
TYPESENSE_DOMAIN=""
if [[ "$ADD_PROXY" == "true" ]]; then
  APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
  ask TYPESENSE_DOMAIN "Subdomain for Typesense" "search.${APP_DOMAIN:-example.com}"
fi

echo
confirm_or_exit "Install Typesense ${TYPESENSE_VERSION}?"

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Downloading Typesense ${TYPESENSE_VERSION}..."
  ARCH=$(dpkg --print-architecture 2> /dev/null || uname -m)
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64" || ARCH="amd64"

  DEB_URL="https://dl.typesense.org/releases/${TYPESENSE_VERSION}/typesense-server-${TYPESENSE_VERSION}-${ARCH}.deb"
  DEB_FILE=$(mktemp /tmp/typesense.XXXXXX.deb)

  run_or_dry curl -fsSL "$DEB_URL" -o "$DEB_FILE"
  run_or_dry dpkg -i "$DEB_FILE"
  rm -f "$DEB_FILE"
  success "Typesense installed."
fi

step "Configuring Typesense..."
run_or_dry mkdir -p "$TYPESENSE_DATA_DIR"
run_or_dry chown -R typesense:typesense "$TYPESENSE_DATA_DIR" 2> /dev/null || true

CONFIG_FILE="/etc/typesense/typesense-server.ini"
run_or_dry mkdir -p "$(dirname "$CONFIG_FILE")"

if [[ "${DRY_RUN:-false}" != "true" ]]; then
  cat > "$CONFIG_FILE" << EOF
[server]
api-key = ${TYPESENSE_API_KEY}
data-dir = ${TYPESENSE_DATA_DIR}
api-port = ${TYPESENSE_PORT}
log-dir = /var/log/typesense
EOF
  chmod 640 "$CONFIG_FILE"
fi

step "Starting Typesense service..."
run_or_dry service_enable_start typesense-server
success "Typesense is running on port ${TYPESENSE_PORT}."

if [[ "$ADD_PROXY" == "true" && -n "$TYPESENSE_DOMAIN" ]]; then
  step "Configuring Nginx proxy for ${TYPESENSE_DOMAIN}..."
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    cat > "/etc/nginx/sites-available/${TYPESENSE_DOMAIN}" << EOF
server {
    listen 80;
    server_name ${TYPESENSE_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${TYPESENSE_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${TYPESENSE_DOMAIN}" "/etc/nginx/sites-enabled/${TYPESENSE_DOMAIN}"
    nginx -t && systemctl reload nginx
  fi
  success "Nginx proxy configured for ${TYPESENSE_DOMAIN}."
fi

add_firewall_rule "$TYPESENSE_PORT"

creds_section "Typesense"
creds_save TYPESENSE_VERSION "$TYPESENSE_VERSION"
creds_save TYPESENSE_PORT "$TYPESENSE_PORT"
creds_save TYPESENSE_DATA_DIR "$TYPESENSE_DATA_DIR"
creds_save TYPESENSE_API_KEY "$TYPESENSE_API_KEY"
[[ -n "$TYPESENSE_DOMAIN" ]] && creds_save TYPESENSE_DOMAIN "$TYPESENSE_DOMAIN"

echo
info "Add to your Laravel .env:"
echo
echo -e "  TYPESENSE_API_KEY=${TYPESENSE_API_KEY}"
echo -e "  TYPESENSE_HOST=127.0.0.1"
echo -e "  TYPESENSE_PORT=${TYPESENSE_PORT}"
echo -e "  TYPESENSE_PROTOCOL=http"
echo -e "  TYPESENSE_COLLECTION_PREFIX=laravel_"
echo -e "  SCOUT_DRIVER=typesense"
echo
info "Install the Scout + Typesense driver:"
echo -e "  ${DIM}composer require laravel/scout typesense/typesense-php${NC}"
echo
success "Typesense setup complete."
