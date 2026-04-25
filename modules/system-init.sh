#!/usr/bin/env bash
# =============================================================================
#  Module — System Initialization & Updates
#  Run standalone: sudo bash modules/system-init.sh
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

module_header "System Initialization" "Updates packages, installs essentials, configures swap & timezone."
require_root
detect_os

# Timezone
ask TIMEZONE "Server timezone (e.g. Africa/Lagos, UTC, America/New_York)" "UTC"

# Swap
local_swap=$(free -m | awk '/Swap:/ {print $2}')
if [[ "$local_swap" -gt 0 ]]; then
  info "Swap already configured (${local_swap}MB). Skipping."
  SETUP_SWAP=false
else
  ask_yn SETUP_SWAP "Configure swap space?" "y"
fi

if [[ "${SETUP_SWAP}" == "true" ]]; then
  ask SWAP_SIZE "Swap size" "2G"
fi

# Hostname
ask_yn SET_HOSTNAME "Set a custom hostname?" "n"
if [[ "$SET_HOSTNAME" == "true" ]]; then
  ask SERVER_HOSTNAME "Hostname" "laravel-server"
fi

# Confirm
echo
info "Configuration summary:"
dim "Timezone:  ${TIMEZONE}"
dim "Swap:      ${SETUP_SWAP} ${SWAP_SIZE:-}"
dim "Hostname:  ${SET_HOSTNAME} ${SERVER_HOSTNAME:-}"
echo
confirm_or_exit "Apply system initialization?"

# Update & upgrade
step "Updating package lists..."
apt-get update -qq

step "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q

step "Installing essential packages..."
pkg_install \
  curl wget git unzip zip \
  acl software-properties-common \
  apt-transport-https ca-certificates gnupg \
  htop tree nano vim \
  build-essential \
  ufw fail2ban \
  cron logrotate

# Timezone
step "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"
success "Timezone set: $(timedatectl | grep 'Time zone' | awk '{print $3}')"

# Swap
if [[ "${SETUP_SWAP:-false}" == "true" ]]; then
  step "Configuring ${SWAP_SIZE} swap..."
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  ensure_line "/swapfile none swap sw 0 0" /etc/fstab
  # Tune swappiness for server workloads
  sysctl vm.swappiness=10 > /dev/null
  ensure_line "vm.swappiness=10" /etc/sysctl.conf
  ensure_line "vm.vfs_cache_pressure=50" /etc/sysctl.conf
  success "Swap configured: ${SWAP_SIZE}"
fi

# Hostname
if [[ "${SET_HOSTNAME:-false}" == "true" ]]; then
  step "Setting hostname to ${SERVER_HOSTNAME}..."
  hostnamectl set-hostname "$SERVER_HOSTNAME"
  ensure_line "127.0.1.1  ${SERVER_HOSTNAME}" /etc/hosts
  creds_save "SERVER_HOSTNAME" "$SERVER_HOSTNAME"
  success "Hostname set: $SERVER_HOSTNAME"
fi

# Auto security updates
ask_yn ENABLE_AUTO_UPDATES "Enable unattended security updates?" "y"
if [[ "$ENABLE_AUTO_UPDATES" == "true" ]]; then
  pkg_install unattended-upgrades
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades < /dev/null > /dev/null 2>&1 || true
  success "Automatic security updates enabled."
fi

# Save state
creds_section "System"
creds_save "SYSTEM_TIMEZONE" "$TIMEZONE"
creds_save "SYSTEM_OS" "${OS_ID} ${OS_VERSION} ${OS_CODENAME:-}"

success "System initialization complete."
