#!/usr/bin/env bash
# =============================================================================
#  Module 17 — Meilisearch
#  Fast, typo-tolerant full-text search engine for Laravel Scout.
#  Run standalone: sudo bash modules/17-meilisearch.sh
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

module_header "Meilisearch" "Installs Meilisearch with systemd service and optional Nginx proxy."
require_root
detect_os

if has_cmd meilisearch; then
  CURRENT_VER=$(meilisearch --version 2> /dev/null | awk '{print $NF}')
  warn "Meilisearch ${CURRENT_VER} is already installed."
  ask_choice REINSTALL_ACTION "What would you like to do?" \
    "Reconfigure only (keep existing binary)" \
    "Reinstall (replace binary + reconfigure)" \
    "Skip this module"
  case "$REINSTALL_ACTION" in
    "Skip"*)
      info "Skipping."
      exit 0
      ;;
    "Reinstall"*) : ;;
    *) SKIP_INSTALL=true ;;
  esac
fi

ask_choice MEILI_VERSION "Select Meilisearch version:" \
  "v1.11 (Latest)" \
  "v1.10 (Stable)" \
  "v1.9 (Previous)"
MEILI_VERSION="${MEILI_VERSION%% *}"

ask MEILI_PORT "Meilisearch HTTP port" "7700"
MEILI_MASTER_KEY=$(creds_load MEILI_MASTER_KEY 2> /dev/null || gen_secret 32)
ask_secret KEY_INPUT "Master key (blank to use generated)"
[[ -n "$KEY_INPUT" ]] && MEILI_MASTER_KEY="$KEY_INPUT"

MEILI_DATA_DIR="/var/lib/meilisearch"
MEILI_BIN="/usr/local/bin/meilisearch"

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Downloading Meilisearch ${MEILI_VERSION}..."
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" ]] && ARCH="aarch64" || ARCH="amd64"
  MEILI_URL="https://github.com/meilisearch/meilisearch/releases/download/${MEILI_VERSION}/meilisearch-linux-${ARCH}"
  curl -fsSL "$MEILI_URL" -o "$MEILI_BIN"
  chmod +x "$MEILI_BIN"
  success "Meilisearch binary installed."
fi

step "Creating meilisearch user and data directory..."
id -u meilisearch &> /dev/null || useradd --system --no-create-home --shell /bin/false meilisearch
mkdir -p "$MEILI_DATA_DIR"
chown -R meilisearch:meilisearch "$MEILI_DATA_DIR"

step "Writing systemd service..."
cat > /etc/systemd/system/meilisearch.service << EOF
[Unit]
Description=Meilisearch Search Engine
After=network.target

[Service]
User=meilisearch
Group=meilisearch
ExecStart=${MEILI_BIN} \\
  --db-path ${MEILI_DATA_DIR}/data \\
  --dumps-dir ${MEILI_DATA_DIR}/dumps \\
  --snapshots-dir ${MEILI_DATA_DIR}/snapshots \\
  --http-addr 127.0.0.1:${MEILI_PORT} \\
  --master-key ${MEILI_MASTER_KEY} \\
  --env production
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --quiet meilisearch
systemctl restart meilisearch
success "Meilisearch service running on 127.0.0.1:${MEILI_PORT}."

add_firewall_rule "$MEILI_PORT" tcp 2> /dev/null || true

ask_yn SETUP_NGINX_PROXY "Set up Nginx proxy for Meilisearch (public access)?" "n"
if [[ "$SETUP_NGINX_PROXY" == "true" ]]; then
  ask MEILI_DOMAIN "Meilisearch public domain (e.g. search.example.com)" ""
  if [[ -n "$MEILI_DOMAIN" ]] && has_cmd nginx; then
    cat > "/etc/nginx/sites-available/meilisearch" << NGINXEOF
server {
    listen 80;
    server_name ${MEILI_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${MEILI_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF
    ln -sf /etc/nginx/sites-available/meilisearch /etc/nginx/sites-enabled/meilisearch
    nginx -t && systemctl reload nginx
    success "Nginx proxy configured for ${MEILI_DOMAIN}."
    creds_save "MEILI_DOMAIN" "$MEILI_DOMAIN"
  fi
fi

creds_section "Meilisearch"
creds_save "MEILI_VERSION" "$MEILI_VERSION"
creds_save "MEILI_PORT" "$MEILI_PORT"
creds_save "MEILI_MASTER_KEY" "$MEILI_MASTER_KEY"
creds_save "MEILI_DATA_DIR" "$MEILI_DATA_DIR"

echo
info "Add to your Laravel .env:"
echo -e "  ${DIM}SCOUT_DRIVER=meilisearch"
echo -e "  MEILISEARCH_HOST=http://127.0.0.1:${MEILI_PORT}"
echo -e "  MEILISEARCH_KEY=${MEILI_MASTER_KEY}${NC}"
echo
success "Meilisearch module complete."
