#!/usr/bin/env bash
# =============================================================================
#  Module 20 — RabbitMQ
#  AMQP message broker — alternative queue driver for high-throughput apps.
#  Run standalone: sudo bash modules/20-rabbitmq.sh
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

module_header "RabbitMQ" "AMQP message broker — alternative queue driver for high-throughput apps"
require_root

RABBITMQ_PORT="$(creds_load RABBITMQ_PORT 2> /dev/null || echo "5672")"
RABBITMQ_MGMT_PORT="$(creds_load RABBITMQ_MGMT_PORT 2> /dev/null || echo "15672")"
RABBITMQ_USER="$(creds_load RABBITMQ_USER 2> /dev/null || echo "laravel")"
RABBITMQ_PASSWORD="$(creds_load RABBITMQ_PASSWORD 2> /dev/null || gen_password 20)"
RABBITMQ_VHOST="$(creds_load RABBITMQ_VHOST 2> /dev/null || echo "laravel")"

if has_cmd rabbitmqctl; then
  INSTALLED_VER=$(rabbitmqctl version 2> /dev/null | head -1 || echo "unknown")
  warn "RabbitMQ ${INSTALLED_VER} is already installed."
  if [[ "${LARAKIT_FORCE:-false}" == "true" ]]; then
    EXISTING_MODE="Reinstall"
  else
    ask_choice EXISTING_MODE "What would you like to do?" \
      "Reconfigure (keep binaries, update users)" \
      "Reinstall (download fresh packages)" \
      "Skip"
  fi
  [[ "$EXISTING_MODE" == "Skip" ]] && {
    info "Skipping RabbitMQ."
    exit 0
  }
  [[ "$EXISTING_MODE" == "Reconfigure"* ]] && SKIP_INSTALL=true
fi

ask_choice VERSION_LABEL "RabbitMQ version" \
  "3.13 (latest stable)" \
  "3.12" \
  "3.11"
RABBITMQ_VERSION="${VERSION_LABEL%% *}"

ask RABBITMQ_PORT "AMQP port" "$RABBITMQ_PORT"
ask RABBITMQ_MGMT_PORT "Management UI port" "$RABBITMQ_MGMT_PORT"
ask RABBITMQ_USER "Laravel queue user" "$RABBITMQ_USER"
ask RABBITMQ_PASSWORD "Queue user password" "$RABBITMQ_PASSWORD"
ask RABBITMQ_VHOST "Virtual host" "$RABBITMQ_VHOST"

ask_yn ENABLE_MGMT "Enable management web UI?" "y"

ask_yn ADD_PROXY "Add Nginx proxy for management UI?" "n"
RABBITMQ_DOMAIN=""
if [[ "$ADD_PROXY" == "true" ]]; then
  APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
  ask RABBITMQ_DOMAIN "Subdomain for RabbitMQ UI" "mq.${APP_DOMAIN:-example.com}"
fi

echo
confirm_or_exit "Install RabbitMQ ${RABBITMQ_VERSION}?"

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Adding RabbitMQ APT repository..."
  run_or_dry curl -fsSL "https://packagecloud.io/rabbitmq/rabbitmq-server/gpgkey" \
    | gpg --dearmor -o /usr/share/keyrings/rabbitmq-keyring.gpg

  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  echo "deb [signed-by=/usr/share/keyrings/rabbitmq-keyring.gpg] \
https://packagecloud.io/rabbitmq/rabbitmq-server/ubuntu/ ${CODENAME} main" \
    | tee /etc/apt/sources.list.d/rabbitmq.list > /dev/null

  run_or_dry apt-get update -qq
  run_quiet "Installing RabbitMQ..." pkg_install rabbitmq-server
fi

step "Configuring RabbitMQ..."
if [[ "${DRY_RUN:-false}" != "true" ]]; then
  CONF_DIR="/etc/rabbitmq"
  mkdir -p "$CONF_DIR"
  cat > "${CONF_DIR}/rabbitmq.conf" << EOF
listeners.tcp.default = ${RABBITMQ_PORT}
management.tcp.port   = ${RABBITMQ_MGMT_PORT}
loopback_users        = none
EOF
fi

run_or_dry service_enable_start rabbitmq-server

step "Creating virtual host and user..."
if [[ "${DRY_RUN:-false}" != "true" ]]; then
  rabbitmqctl add_vhost "$RABBITMQ_VHOST" 2> /dev/null || true
  rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD" 2> /dev/null \
    || rabbitmqctl change_password "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"
  rabbitmqctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" ".*" ".*" ".*"
fi

if [[ "$ENABLE_MGMT" == "true" ]]; then
  step "Enabling management plugin..."
  run_or_dry rabbitmq-plugins enable rabbitmq_management
  success "Management UI available at http://127.0.0.1:${RABBITMQ_MGMT_PORT}"
fi

if [[ "$ADD_PROXY" == "true" && -n "$RABBITMQ_DOMAIN" ]]; then
  step "Configuring Nginx proxy for ${RABBITMQ_DOMAIN}..."
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    cat > "/etc/nginx/sites-available/${RABBITMQ_DOMAIN}" << EOF
server {
    listen 80;
    server_name ${RABBITMQ_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${RABBITMQ_MGMT_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${RABBITMQ_DOMAIN}" "/etc/nginx/sites-enabled/${RABBITMQ_DOMAIN}"
    nginx -t && systemctl reload nginx
  fi
  success "Nginx proxy configured for ${RABBITMQ_DOMAIN}."
fi

add_firewall_rule "$RABBITMQ_PORT"

creds_section "RabbitMQ"
creds_save RABBITMQ_VERSION "$RABBITMQ_VERSION"
creds_save RABBITMQ_PORT "$RABBITMQ_PORT"
creds_save RABBITMQ_MGMT_PORT "$RABBITMQ_MGMT_PORT"
creds_save RABBITMQ_USER "$RABBITMQ_USER"
creds_save RABBITMQ_PASSWORD "$RABBITMQ_PASSWORD"
creds_save RABBITMQ_VHOST "$RABBITMQ_VHOST"
[[ -n "$RABBITMQ_DOMAIN" ]] && creds_save RABBITMQ_DOMAIN "$RABBITMQ_DOMAIN"

echo
info "Add to your Laravel .env:"
echo
echo -e "  QUEUE_CONNECTION=rabbitmq"
echo -e "  RABBITMQ_HOST=127.0.0.1"
echo -e "  RABBITMQ_PORT=${RABBITMQ_PORT}"
echo -e "  RABBITMQ_USER=${RABBITMQ_USER}"
echo -e "  RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"
echo -e "  RABBITMQ_VHOST=${RABBITMQ_VHOST}"
echo
info "Install the Laravel RabbitMQ driver:"
echo -e "  ${DIM}composer require vyuldashev/laravel-queue-rabbitmq${NC}"
echo
success "RabbitMQ setup complete."
