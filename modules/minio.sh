#!/usr/bin/env bash
# =============================================================================
#  Module — MinIO Object Storage (S3-compatible)
#  Run standalone: sudo bash modules/minio.sh
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

module_header "MinIO Object Storage" "Self-hosted S3-compatible storage. Ideal for file uploads, backups, and media."
require_root

# Detect existing
MINIO_EXISTING=false
if has_cmd minio || [[ -f /usr/local/bin/minio ]]; then
  MINIO_EXISTING=true
  warn "MinIO is already installed."
  ask_choice EXISTING_MODE "MinIO detected — what to do?" \
    "Reconfigure and generate new credentials" \
    "Reconfigure only (keep existing credentials)" \
    "Skip — just show .env values"
else
  EXISTING_MODE="Fresh install"
fi

# Config
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask MINIO_DATA_DIR "MinIO data directory" "/var/data/minio"
ask MINIO_PORT "MinIO API port" "9000"
ask MINIO_CONSOLE_PORT "MinIO console port" "9001"
ask MINIO_USER "MinIO system user" "minio-user"

MINIO_ROOT_USER="$(gen_secret 16)"
MINIO_ROOT_PASS="$(gen_password 32)"

if [[ "$EXISTING_MODE" != "Reconfigure only"* ]]; then
  warn "Generated MinIO root user: ${MINIO_ROOT_USER}"
  warn "Generated MinIO root password: ${MINIO_ROOT_PASS}"
  ask_yn USE_GEN_CREDS "Use generated credentials?" "y"
  if [[ "$USE_GEN_CREDS" != "true" ]]; then
    ask MINIO_ROOT_USER "MinIO root access key (min 3 chars)" ""
    ask_secret MINIO_ROOT_PASS "MinIO root secret key (min 8 chars)"
  fi
fi

ask MINIO_DEFAULT_BUCKET "Default bucket to create" "laravel-app"
ask_yn MINIO_NGINX_PROXY "Proxy MinIO via Nginx (serve on HTTPS sub-path)?" "y"
if [[ "$MINIO_NGINX_PROXY" == "true" ]]; then
  ask MINIO_SUBDOMAIN "MinIO subdomain" "storage.${APP_DOMAIN:-example.com}"
fi

echo
confirm_or_exit "Set up MinIO?"

# Install MinIO
if [[ "$EXISTING_MODE" != "Reconfigure only"* ]] && [[ "$EXISTING_MODE" != "Skip"* ]]; then
  step "Downloading MinIO binary..."
  curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
  chmod +x /usr/local/bin/minio
  success "MinIO $(minio --version | head -1) installed."

  # mc (MinIO client)
  step "Installing mc (MinIO client)..."
  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
  chmod +x /usr/local/bin/mc
  success "mc installed."
fi

# System user and dirs
if ! id "$MINIO_USER" &> /dev/null; then
  useradd --system --no-create-home --shell /sbin/nologin "$MINIO_USER"
fi
mkdir -p "$MINIO_DATA_DIR"
chown -R "${MINIO_USER}:${MINIO_USER}" "$MINIO_DATA_DIR"

# Environment file
cat > /etc/default/minio << EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASS}
MINIO_VOLUMES=${MINIO_DATA_DIR}
MINIO_OPTS="--console-address :${MINIO_CONSOLE_PORT}"
EOF
chmod 600 /etc/default/minio

# Systemd service
cat > /etc/systemd/system/minio.service << EOF
[Unit]
Description=MinIO Object Storage
After=network.target

[Service]
User=${MINIO_USER}
Group=${MINIO_USER}
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server \$MINIO_VOLUMES \$MINIO_OPTS
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio --quiet
systemctl restart minio
success "MinIO service started on port ${MINIO_PORT}."

# Create default bucket via mc
sleep 3 # wait for MinIO to start
step "Creating default bucket '${MINIO_DEFAULT_BUCKET}'..."
mc alias set local "http://127.0.0.1:${MINIO_PORT}" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASS" > /dev/null 2>&1 || true
mc mb "local/${MINIO_DEFAULT_BUCKET}" --ignore-existing > /dev/null 2>&1 && success "Bucket '${MINIO_DEFAULT_BUCKET}' ready." || warn "Could not create bucket — create manually after startup."

# Nginx proxy for MinIO
if [[ "$MINIO_NGINX_PROXY" == "true" ]] && [[ -n "${MINIO_SUBDOMAIN:-}" ]]; then
  step "Creating Nginx proxy for MinIO..."

  cat > /etc/nginx/sites-available/minio << NGINX
server {
    listen 80;
    server_name ${MINIO_SUBDOMAIN};
    client_max_body_size 0;

    # MinIO API
    location / {
        proxy_pass http://127.0.0.1:${MINIO_PORT};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 300;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        chunked_transfer_encoding off;
    }
}

server {
    listen 80;
    server_name console.${MINIO_SUBDOMAIN};

    # MinIO Console
    location / {
        proxy_pass http://127.0.0.1:${MINIO_CONSOLE_PORT};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX

  ln -sf /etc/nginx/sites-available/minio /etc/nginx/sites-enabled/minio 2> /dev/null || true
  nginx -t && systemctl reload nginx && success "Nginx proxy configured for MinIO."

  # Open firewall
  add_firewall_rule "80" "tcp"
  add_firewall_rule "443" "tcp"
fi

# Save
creds_section "MinIO"
creds_save "MINIO_ENDPOINT" "http://127.0.0.1:${MINIO_PORT}"
creds_save "MINIO_ACCESS_KEY" "$MINIO_ROOT_USER"
creds_save "MINIO_SECRET_KEY" "$MINIO_ROOT_PASS"
creds_save "MINIO_BUCKET" "$MINIO_DEFAULT_BUCKET"
creds_save "MINIO_CONSOLE" "http://127.0.0.1:${MINIO_CONSOLE_PORT}"
[[ -n "${MINIO_SUBDOMAIN:-}" ]] && creds_save "MINIO_PUBLIC_URL" "https://${MINIO_SUBDOMAIN}"

echo
success "MinIO module complete."
info "Laravel .env values (S3-compatible):"
dim "FILESYSTEM_DISK=s3"
dim "AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER}"
dim "AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASS}"
dim "AWS_DEFAULT_REGION=us-east-1"
dim "AWS_BUCKET=${MINIO_DEFAULT_BUCKET}"
dim "AWS_ENDPOINT=http://127.0.0.1:${MINIO_PORT}"
dim "AWS_USE_PATH_STYLE_ENDPOINT=true"
