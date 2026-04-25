#!/usr/bin/env bash
# =============================================================================
#  Module — Elasticsearch
#  Full-text search engine for Laravel Scout or custom indexing.
#  Run standalone: sudo bash modules/elasticsearch.sh
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

module_header "Elasticsearch" "Full-text search engine for Laravel Scout or custom indexing."
require_root

ES_VERSION="$(creds_load ES_VERSION 2> /dev/null || echo "")"
ES_PORT="$(creds_load ES_PORT 2> /dev/null || echo "9200")"
ES_DOMAIN="$(creds_load ES_DOMAIN 2> /dev/null || echo "")"

if has_cmd elasticsearch; then
  INSTALLED_VER=$(elasticsearch --version 2> /dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
  warn "Elasticsearch ${INSTALLED_VER} is already installed."
  ES_CHOICE=""
  if [[ "${LARAKIT_FORCE:-false}" == "true" ]]; then
    ES_CHOICE="Reinstall"
  else
    ask_choice ES_CHOICE "What would you like to do?" \
      "Reconfigure (keep binaries, update settings)" \
      "Reinstall (download fresh packages)" \
      "Skip"
  fi
  [[ "$ES_CHOICE" == "Skip" ]] && {
    info "Skipping Elasticsearch."
    exit 0
  }
  [[ "$ES_CHOICE" == "Reconfigure"* ]] && SKIP_INSTALL=true
fi

ask_choice ES_VERSION "Elasticsearch version:" \
  "8.14 (Latest stable)" \
  "8.13 (Stable)" \
  "8.12 (Previous)" \
  "7.17 (Legacy LTS)"
ES_VERSION="${ES_VERSION%% *}"
ES_MAJOR="${ES_VERSION%%.*}"

ask ES_PORT "Elasticsearch port" "$ES_PORT"

ADD_KIBANA=""
ask_yn ADD_KIBANA "Install Kibana dashboard?" "n"

ADD_PROXY=""
ask_yn ADD_PROXY "Add Nginx proxy for Elasticsearch?" "n"
if [[ "$ADD_PROXY" == "true" ]]; then
  APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
  ask ES_DOMAIN "Subdomain for Elasticsearch" "es.${APP_DOMAIN:-example.com}"
fi

echo
confirm_or_exit "Install Elasticsearch ${ES_VERSION}?"

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Adding Elastic APT repository..."
  run_or_dry curl -fsSL "https://artifacts.elastic.co/GPG-KEY-elasticsearch" \
    | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/${ES_MAJOR}.x/apt stable main" \
    | tee /etc/apt/sources.list.d/elastic-${ES_MAJOR}.x.list > /dev/null
  run_or_dry apt-get update -qq
  run_quiet "Installing Elasticsearch ${ES_VERSION}..." pkg_install "elasticsearch"
fi

step "Configuring Elasticsearch..."
ES_CONF="/etc/elasticsearch/elasticsearch.yml"
if [[ "${DRY_RUN:-false}" != "true" ]]; then
  backup_file "$ES_CONF"
  set_env_value "network.host" "127.0.0.1" "$ES_CONF"
  set_env_value "http.port" "$ES_PORT" "$ES_CONF"
  set_env_value "discovery.type" "single-node" "$ES_CONF"
  set_env_value "xpack.security.enabled" "false" "$ES_CONF"
fi

step "Setting JVM heap (min 512m / max 1g)..."
if [[ "${DRY_RUN:-false}" != "true" ]] && [[ -f /etc/elasticsearch/jvm.options ]]; then
  backup_file /etc/elasticsearch/jvm.options
  tmp=$(mktemp)
  sed \
    -e 's/^-Xms.*/-Xms512m/' \
    -e 's/^-Xmx.*/-Xmx1g/' \
    /etc/elasticsearch/jvm.options > "$tmp" && mv "$tmp" /etc/elasticsearch/jvm.options
fi

run_or_dry service_enable_start elasticsearch
success "Elasticsearch is running on port ${ES_PORT}."

if [[ "$ADD_KIBANA" == "true" ]]; then
  step "Installing Kibana..."
  run_or_dry pkg_install kibana
  KIBANA_CONF="/etc/kibana/kibana.yml"
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    backup_file "$KIBANA_CONF"
    set_env_value "server.port" "5601" "$KIBANA_CONF"
    set_env_value "server.host" "127.0.0.1" "$KIBANA_CONF"
    set_env_value "elasticsearch.hosts" "[\"http://127.0.0.1:${ES_PORT}\"]" "$KIBANA_CONF"
  fi
  run_or_dry service_enable_start kibana
  success "Kibana is running on port 5601."
fi

if [[ "$ADD_PROXY" == "true" && -n "$ES_DOMAIN" ]]; then
  step "Configuring Nginx proxy for ${ES_DOMAIN}..."
  if [[ "${DRY_RUN:-false}" != "true" ]]; then
    cat > "/etc/nginx/sites-available/${ES_DOMAIN}" << EOF
server {
    listen 80;
    server_name ${ES_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${ES_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${ES_DOMAIN}" "/etc/nginx/sites-enabled/${ES_DOMAIN}"
    nginx -t && systemctl reload nginx
  fi
  success "Nginx proxy configured for ${ES_DOMAIN}."
fi

add_firewall_rule "$ES_PORT"

creds_section "Elasticsearch"
creds_save ES_VERSION "$ES_VERSION"
creds_save ES_PORT "$ES_PORT"
[[ -n "$ES_DOMAIN" ]] && creds_save ES_DOMAIN "$ES_DOMAIN"

echo
info "Add to your Laravel .env:"
echo
echo -e "  SCOUT_DRIVER=elastic"
echo -e "  ELASTICSEARCH_HOST=127.0.0.1"
echo -e "  ELASTICSEARCH_PORT=${ES_PORT}"
echo -e "  ELASTICSEARCH_SCHEME=http"
echo
info "Install the Scout + Elasticsearch driver:"
echo -e "  ${DIM}composer require laravel/scout elasticsearch/elasticsearch${NC}"
echo
success "Elasticsearch setup complete."
