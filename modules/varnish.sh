#!/usr/bin/env bash
# =============================================================================
#  Module 21 — Varnish Cache
#  HTTP accelerator in front of Nginx for high-traffic sites.
#  Run standalone: sudo bash modules/21-varnish.sh
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

module_header "Varnish Cache" "HTTP reverse proxy cache. Nginx moves to port 8080; Varnish listens on port 80."
require_root
detect_os

info "Varnish sits in front of Nginx: internet → Varnish :80 → Nginx :8080"
warn "SSL must terminate at a separate load balancer or you can keep port 443 going directly to Nginx."

if has_cmd varnishd; then
  CURRENT_VER=$(varnishd -V 2>&1 | head -1)
  warn "Varnish already installed: ${CURRENT_VER}"
  ask_choice VNS_ACTION "What would you like to do?" \
    "Reconfigure only (keep existing binary)" \
    "Reinstall" \
    "Skip this module"
  case "$VNS_ACTION" in
    "Skip"*)
      info "Skipping."
      exit 0
      ;;
    "Reinstall"*) : ;;
    *) SKIP_INSTALL=true ;;
  esac
fi

ask_choice VNS_VERSION "Select Varnish version:" \
  "7.6 (Latest)" \
  "7.5 (Stable)" \
  "7.4 (LTS)"
VNS_VERSION="${VNS_VERSION%% *}"

ask VNS_PORT "Varnish public port (replace Nginx on 80)" "80"
ask VNS_BACKEND_PORT "Nginx backend port (Nginx will be moved here)" "8080"
ask VNS_CACHE_SIZE "Cache size (e.g. 256m, 1g, 2g)" "256m"
ask VNS_TTL "Default TTL in seconds" "120"
ask VNS_DOMAIN "Primary domain name (for VCL host matching)" ""

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  step "Adding Varnish ${VNS_VERSION} repository..."
  pkg_install apt-transport-https curl gnupg
  curl -fsSL "https://packagecloud.io/varnishcache/varnish${VNS_VERSION//./}/gpgkey" \
    | gpg --dearmor -o /usr/share/keyrings/varnish-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/varnish-keyring.gpg] \
https://packagecloud.io/varnishcache/varnish${VNS_VERSION//./}/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/ \
$(lsb_release -cs) main" > /etc/apt/sources.list.d/varnish.list

  apt-get update -qq
  pkg_install "varnish"
  success "Varnish installed."
fi

step "Moving Nginx to backend port ${VNS_BACKEND_PORT}..."
NGINX_DEFAULT="/etc/nginx/sites-available/default"
NGINX_LARAVEL="/etc/nginx/sites-available/laravel"
for f in "$NGINX_DEFAULT" "$NGINX_LARAVEL"; do
  if [[ -f "$f" ]]; then
    backup_file "$f"
    tmp=$(mktemp)
    sed \
      -e "s/listen 80;/listen ${VNS_BACKEND_PORT};/g" \
      -e "s/listen \[::\]:80;/listen [::]:${VNS_BACKEND_PORT};/g" \
      "$f" > "$tmp" && mv "$tmp" "$f"
  fi
done
nginx -t 2> /dev/null && systemctl reload nginx && success "Nginx moved to :${VNS_BACKEND_PORT}."

step "Writing Varnish VCL configuration..."
mkdir -p /etc/varnish
cat > /etc/varnish/default.vcl << VCLEOF
vcl 4.1;

backend default {
    .host = "127.0.0.1";
    .port = "${VNS_BACKEND_PORT}";
    .connect_timeout = 5s;
    .first_byte_timeout = 60s;
    .between_bytes_timeout = 10s;
}

sub vcl_recv {
    # Strip cookies for static assets
    if (req.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }

    # Do not cache POST, PUT, DELETE, PATCH
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Do not cache authenticated/session requests
    if (req.http.Authorization || req.http.Cookie ~ "(laravel_session|XSRF-TOKEN)") {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    # Cache only successful responses
    if (beresp.status >= 400) {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Default TTL for cacheable responses
    if (!beresp.http.Cache-Control) {
        set beresp.ttl = ${VNS_TTL}s;
    }

    # Strip Set-Cookie from cacheable responses
    if (beresp.http.Cache-Control !~ "private" && beresp.http.Cache-Control !~ "no-cache") {
        unset beresp.http.Set-Cookie;
    }

    return (deliver);
}

sub vcl_deliver {
    # Add debug header showing cache HIT/MISS
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }

    # Remove Varnish identifying headers in production
    unset resp.http.X-Varnish;
    unset resp.http.Via;

    return (deliver);
}
VCLEOF

step "Configuring Varnish systemd service..."
mkdir -p /etc/systemd/system/varnish.service.d
cat > /etc/systemd/system/varnish.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/varnishd \\
  -a 0.0.0.0:${VNS_PORT} \\
  -T 127.0.0.1:6082 \\
  -f /etc/varnish/default.vcl \\
  -s malloc,${VNS_CACHE_SIZE}
EOF

systemctl daemon-reload
systemctl enable --quiet varnish
systemctl restart varnish
success "Varnish running on :${VNS_PORT} → Nginx :${VNS_BACKEND_PORT}."

ask_yn RESTRICT_BACKEND "Block direct access to Nginx backend port via UFW?" "y"
if [[ "$RESTRICT_BACKEND" == "true" ]]; then
  ufw deny "${VNS_BACKEND_PORT}" 2> /dev/null || true
  ufw allow "${VNS_PORT}" 2> /dev/null || true
  success "UFW rules updated."
fi

creds_section "Varnish"
creds_save "VARNISH_VERSION" "$VNS_VERSION"
creds_save "VARNISH_PORT" "$VNS_PORT"
creds_save "VARNISH_BACKEND_PORT" "$VNS_BACKEND_PORT"
creds_save "VARNISH_CACHE_SIZE" "$VNS_CACHE_SIZE"
creds_save "VARNISH_TTL" "${VNS_TTL}s"

echo
info "Verify Varnish is caching:"
echo -e "  ${DIM}curl -I http://your-domain.com${NC}"
echo -e "  ${DIM}# Look for: X-Cache: HIT${NC}"
echo
success "Varnish module complete."
