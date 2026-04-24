#!/usr/bin/env bash
# =============================================================================
#  Module 22 — Load Balancer & Horizontal Scaling
#  Sets up Nginx or HAProxy as a load balancer for multiple app servers
#  Run standalone: sudo bash modules/22-load-balancer.sh
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

module_header "Load Balancer & Scaling" "Distributes traffic across multiple app servers for horizontal scaling."
require_root

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

warn "This module configures a LOAD BALANCER node — run it on a dedicated server, not on your app servers."

ask_choice LB_ENGINE "Load balancer:" \
  "Nginx (simple, HTTP/HTTPS — built-in)" \
  "HAProxy (advanced, TCP/HTTP, health checks, stats)"

ask APP_DOMAIN_INPUT "Domain to load balance" "${APP_DOMAIN:-}"

# Collect backend servers
BACKENDS=()
step "Enter backend app server IPs (one per line, blank to finish):"
while true; do
  read -r -p "$(echo -e "  ${YELLOW}+${NC}  Backend IP (or leave blank to stop): ")" backend
  [[ -z "$backend" ]] && break
  ask backend_port "Port for ${backend}" "80"
  BACKENDS+=("${backend}:${backend_port}")
done

if [[ ${#BACKENDS[@]} -eq 0 ]]; then
  error "No backend servers specified."
  exit 1
fi

ask_choice LB_ALGORITHM "Load balancing algorithm:" \
  "round-robin (default — equal distribution)" \
  "least-conn  (send to least busy server)" \
  "ip-hash     (sticky sessions by client IP)"

ask_yn HEALTH_CHECK "Enable health checks on backends?" "y"
ask_yn LB_SSL "Terminate SSL at the load balancer?" "y"
[[ "$LB_SSL" == "true" ]] && ask LB_SSL_EMAIL "Email for SSL certificate" ""

echo
info "Load balancer plan:"
dim "Engine:    ${LB_ENGINE%% *}"
dim "Domain:    ${APP_DOMAIN_INPUT}"
dim "Backends:  ${BACKENDS[*]}"
dim "Algorithm: ${LB_ALGORITHM%% *}"
echo
confirm_or_exit "Set up load balancer?"

# Nginx load balancer
if [[ "$LB_ENGINE" == "Nginx"* ]]; then
  pkg_install nginx

  # Build upstream block
  UPSTREAM_BLOCK=""
  for backend in "${BACKENDS[@]}"; do
    UPSTREAM_BLOCK+="    server ${backend};\n"
  done

  LB_DIRECTIVE=""
  case "$LB_ALGORITHM" in
    "least-conn"*) LB_DIRECTIVE="    least_conn;" ;;
    "ip-hash"*) LB_DIRECTIVE="    ip_hash;" ;;
    *) LB_DIRECTIVE="    # round-robin (default)" ;;
  esac

  HEALTH_CHECK_BLOCK=""
  if [[ "$HEALTH_CHECK" == "true" ]] && pkg_installed nginx-extras 2> /dev/null; then
    HEALTH_CHECK_BLOCK='check interval=3000 rise=2 fall=3 timeout=1000 type=http;
        check_http_send "GET /api/health HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;'
  fi

  cat > /etc/nginx/sites-available/lb-"${APP_DOMAIN_INPUT}" << NGINX
upstream app_backend {
${LB_DIRECTIVE}
$(printf '%b' "$UPSTREAM_BLOCK")
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${APP_DOMAIN_INPUT} www.${APP_DOMAIN_INPUT};

    # Health check endpoint
    location /lb-health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_read_timeout 300s;

        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 16 8k;
    }
}
NGINX

  ln -sf "/etc/nginx/sites-available/lb-${APP_DOMAIN_INPUT}" "/etc/nginx/sites-enabled/lb-${APP_DOMAIN_INPUT}" 2> /dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2> /dev/null || true
  nginx -t && systemctl reload nginx
  success "Nginx load balancer configured for ${#BACKENDS[@]} backends."

  # SSL
  if [[ "$LB_SSL" == "true" ]] && [[ -n "$LB_SSL_EMAIL" ]]; then
    pkg_install certbot python3-certbot-nginx -y -q
    certbot --nginx -d "$APP_DOMAIN_INPUT" -d "www.${APP_DOMAIN_INPUT}" \
      --email "$LB_SSL_EMAIL" --agree-tos --non-interactive --redirect 2> /dev/null \
      || warn "SSL certificate failed — check DNS and retry."
  fi

# HAProxy load balancer
elif [[ "$LB_ENGINE" == "HAProxy"* ]]; then
  pkg_install haproxy

  # Build backend servers block
  HAPROXY_BACKENDS=""
  i=1
  for backend in "${BACKENDS[@]}"; do
    HOST="${backend%%:*}"
    PORT="${backend##*:}"
    CHECK_OPT=""
    [[ "$HEALTH_CHECK" == "true" ]] && CHECK_OPT=" check inter 3s rise 2 fall 3"
    HAPROXY_BACKENDS+="    server app${i} ${HOST}:${PORT}${CHECK_OPT}\n"
    ((i++))
  done

  BALANCE_ALG="roundrobin"
  [[ "$LB_ALGORITHM" == "least-conn"* ]] && BALANCE_ALG="leastconn"
  [[ "$LB_ALGORITHM" == "ip-hash"* ]] && BALANCE_ALG="source"

  backup_file /etc/haproxy/haproxy.cfg
  cat > /etc/haproxy/haproxy.cfg << HAPROXY
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 50000
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option forwardfor
    option http-server-close
    timeout connect 5s
    timeout client  30s
    timeout server  300s
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 503 /etc/haproxy/errors/503.http

frontend http_in
    bind *:80
    default_backend app_servers
    option forwardfor

    # Health check
    acl is_health_check path /lb-health
    use_backend health_check if is_health_check

backend app_servers
    balance ${BALANCE_ALG}
    option httpchk GET /api/health
    http-check expect status 200
$(printf '%b' "$HAPROXY_BACKENDS")

backend health_check
    http-request return status 200

listen stats
    bind *:8404
    stats enable
    stats uri /haproxy-stats
    stats refresh 10s
    stats auth $(gen_secret 8):$(gen_password 12)
HAPROXY

  haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl restart haproxy
  success "HAProxy configured for ${#BACKENDS[@]} backends."
  info "Stats page: http://$(get_public_ip):8404/haproxy-stats"
  add_firewall_rule "8404" "tcp"
fi

# Scaling tips
echo
section "Horizontal Scaling Tips"
info "Shared session storage:"
dim "→ Set SESSION_DRIVER=redis in all app servers"
dim "→ Point all servers to the same Redis instance"

info "Shared file storage:"
dim "→ Use S3/MinIO for file uploads (not local disk)"
dim "→ Set FILESYSTEM_DISK=s3"

info "Database:"
dim "→ Use a single primary DB + read replicas"
dim "→ Configure Laravel DB read/write splitting in config/database.php"

info "Cache:"
dim "→ All servers share the same Redis for CACHE_STORE=redis"

# Save
creds_section "Load Balancer"
creds_save "LB_ENGINE" "${LB_ENGINE%% *}"
creds_save "LB_DOMAIN" "$APP_DOMAIN_INPUT"
creds_save "LB_BACKENDS" "${BACKENDS[*]}"

success "Load balancer module complete."
