#!/usr/bin/env bash
# =============================================================================
#  Module — Redis Cache & Sessions
#  Run standalone: sudo bash modules/redis.sh
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

module_header "Redis" "Installs Redis for caching, sessions, and queues."
require_root

# Version selection
ask_choice REDIS_VERSION "Select Redis version:" \
  "8.0 (Latest — 2025)" \
  "7.4 (Stable)" \
  "7.2 (Stable LTS)" \
  "7.0 (Previous stable)"

REDIS_VERSION="${REDIS_VERSION%% *}"

# Config
REDIS_PASSWORD="$(gen_secret 32)"
warn "Generated Redis password: ${REDIS_PASSWORD}"
ask_yn USE_GENERATED_REDIS_PASS "Use this generated password?" "y"
if [[ "$USE_GENERATED_REDIS_PASS" != "true" ]]; then
  ask_secret REDIS_PASSWORD "Enter Redis password (leave blank for no password)"
fi

ask REDIS_PORT "Redis port" "6379"
ask REDIS_MAX_MEMORY "Redis max memory" "256mb"

ask_choice REDIS_EVICTION "Memory eviction policy:" \
  "allkeys-lru  (recommended for cache)" \
  "volatile-lru (LRU on keys with expiry)" \
  "allkeys-lfu  (LFU — Redis 4+)" \
  "noeviction   (return error when full)"

REDIS_EVICTION="${REDIS_EVICTION%% *}"

echo
confirm_or_exit "Install Redis ${REDIS_VERSION}?"

# Install Redis
step "Adding Redis official repo..."
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/redis.list
apt-get update -qq
pkg_install redis
success "Redis $(redis-server --version | awk '{print $3}' | cut -d= -f2) installed."

# Configure Redis
step "Configuring Redis..."
REDIS_CONF="/etc/redis/redis.conf"
backup_file "$REDIS_CONF"

tmp=$(mktemp)
sed \
  -e "s/^port .*/port ${REDIS_PORT}/" \
  -e "s/^# maxmemory .*/maxmemory ${REDIS_MAX_MEMORY}/" \
  -e "s/^maxmemory .*/maxmemory ${REDIS_MAX_MEMORY}/" \
  -e "s/^# maxmemory-policy .*/maxmemory-policy ${REDIS_EVICTION}/" \
  -e "s/^maxmemory-policy .*/maxmemory-policy ${REDIS_EVICTION}/" \
  -e "s/^bind .*/bind 127.0.0.1 ::1/" \
  "$REDIS_CONF" > "$tmp" && mv "$tmp" "$REDIS_CONF"

if [[ -n "$REDIS_PASSWORD" ]]; then
  tmp=$(mktemp)
  sed \
    -e "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" \
    -e "s/^requirepass .*/requirepass ${REDIS_PASSWORD}/" \
    "$REDIS_CONF" > "$tmp" && mv "$tmp" "$REDIS_CONF"
fi

# Persistence — use RDB + AOF for durability
cat >> /etc/redis/redis.conf << EOF

# Persistence (added by laravel-server-setup)
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec
EOF

systemctl enable redis --quiet
systemctl restart redis
success "Redis configured and running."

# Test connection
if redis-cli -p "$REDIS_PORT" -a "$REDIS_PASSWORD" PING 2> /dev/null | grep -q PONG; then
  success "Redis connection test passed."
else
  warn "Redis PING test failed — check configuration."
fi

# Save
creds_section "Redis"
creds_save "REDIS_HOST" "127.0.0.1"
creds_save "REDIS_PORT" "$REDIS_PORT"
creds_save "REDIS_PASSWORD" "$REDIS_PASSWORD"

echo
success "Redis module complete."
info "Laravel .env values:"
dim "REDIS_HOST=127.0.0.1"
dim "REDIS_PASSWORD=${REDIS_PASSWORD}"
dim "REDIS_PORT=${REDIS_PORT}"
dim "CACHE_STORE=redis"
dim "SESSION_DRIVER=redis"
dim "QUEUE_CONNECTION=redis"
