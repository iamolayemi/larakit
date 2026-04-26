#!/usr/bin/env bash
# =============================================================================
#  Module — Server Hardening
#  Creates deploy user, hardens SSH, configures UFW & Fail2ban
#  Run standalone: sudo bash modules/server-hardening.sh
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

module_header "Server Hardening" "Deploy user · SSH hardening · UFW firewall · Fail2ban"
require_root

# Deploy user
ask DEPLOY_USER "Deploy username" "deploy"

USER_EXISTS=false
id "$DEPLOY_USER" &> /dev/null && USER_EXISTS=true

if [[ "$USER_EXISTS" == "true" ]]; then
  warn "User '${DEPLOY_USER}' already exists. Skipping creation."
else
  DEPLOY_PASS="$(gen_password 20)"
  step "Creating user '${DEPLOY_USER}'..."
  useradd -m -s /bin/bash "$DEPLOY_USER"
  echo "${DEPLOY_USER}:${DEPLOY_PASS}" | chpasswd
  usermod -aG sudo "$DEPLOY_USER"
  success "Created user: ${DEPLOY_USER}"

  creds_section "Deploy User"
  creds_save "DEPLOY_USER" "$DEPLOY_USER"
  creds_save "DEPLOY_USER_PASSWORD" "$DEPLOY_PASS"
fi

# SSH key for deploy user
ask_yn SETUP_SSH_KEY "Add an SSH public key for ${DEPLOY_USER}?" "y"
if [[ "$SETUP_SSH_KEY" == "true" ]]; then
  echo -e "  ${DIM}Paste the public key (e.g. ssh-rsa AAAA... user@host):${NC}"
  read -r SSH_PUBLIC_KEY
  if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    DEPLOY_HOME="/home/${DEPLOY_USER}"
    mkdir -p "${DEPLOY_HOME}/.ssh"
    echo "$SSH_PUBLIC_KEY" >> "${DEPLOY_HOME}/.ssh/authorized_keys"
    chmod 700 "${DEPLOY_HOME}/.ssh"
    chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
    success "SSH key added for ${DEPLOY_USER}."
    creds_save "DEPLOY_SSH_KEY_ADDED" "yes"
  fi
fi

# SSH hardening
# Safety warnings before changing SSH settings
CURRENT_USER="$(whoami)"
SSH_KEYS_EXIST=false
[[ -f "/root/.ssh/authorized_keys" ]] && [[ -s "/root/.ssh/authorized_keys" ]] && SSH_KEYS_EXIST=true
[[ -f "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]] && [[ -s "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]] && SSH_KEYS_EXIST=true

echo
warn "─────────────────────────────────────────────────────────"
warn "  SSH SAFETY — read before answering the next questions"
warn "─────────────────────────────────────────────────────────"
if [[ "$CURRENT_USER" == "root" ]]; then
  warn "  You are logged in as root. Disabling root SSH login"
  warn "  will prevent you from reconnecting as root."
fi
if [[ "$SSH_KEYS_EXIST" == "false" ]]; then
  warn "  No SSH keys detected. Disabling password auth"
  warn "  will lock you out completely."
fi
warn "─────────────────────────────────────────────────────────"
echo

ask SSH_PORT "SSH port" "22"

# Safe defaults: keep root login enabled, keep password auth unless keys exist
ask_yn DISABLE_ROOT_SSH "Disable root SSH login?" "n"
if [[ "$SSH_KEYS_EXIST" == "true" ]]; then
  ask_yn DISABLE_PASSWORD_AUTH "Disable password authentication (use keys only)?" "y"
else
  ask_yn DISABLE_PASSWORD_AUTH "Disable password authentication (use keys only)?" "n"
fi

if [[ "$DISABLE_ROOT_SSH" == "true" ]] && [[ "$CURRENT_USER" == "root" ]]; then
  warn "Root SSH will be disabled. Make sure you can log in as '${DEPLOY_USER}' before your next session."
fi
if [[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && [[ "$SSH_KEYS_EXIST" == "false" ]]; then
  error "Cannot disable password auth — no SSH keys are configured. Add a key first."
  DISABLE_PASSWORD_AUTH="false"
fi

step "Hardening SSH configuration..."
SSHD_CONF="/etc/ssh/sshd_config"
backup_file "$SSHD_CONF"

ROOT_LOGIN_VAL="$([[ "$DISABLE_ROOT_SSH" == "true" ]] && echo "no" || echo "yes")"
PASS_AUTH_VAL="$([[ "$DISABLE_PASSWORD_AUTH" == "true" ]] && echo "no" || echo "yes")"
tmp=$(mktemp)
sed \
  -e "s/^#*Port .*/Port ${SSH_PORT}/" \
  -e "s/^#*PermitRootLogin .*/PermitRootLogin ${ROOT_LOGIN_VAL}/" \
  -e "s/^#*PasswordAuthentication .*/PasswordAuthentication ${PASS_AUTH_VAL}/" \
  -e "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" \
  -e "s/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/" \
  -e "s/^#*X11Forwarding .*/X11Forwarding no/" \
  -e "s/^#*MaxAuthTries .*/MaxAuthTries 3/" \
  -e "s/^#*LoginGraceTime .*/LoginGraceTime 30/" \
  "$SSHD_CONF" > "$tmp" && mv "$tmp" "$SSHD_CONF"

# Ubuntu 22.04+ uses ssh.service; older distros use sshd.service
SSH_SVC="ssh"
systemctl list-units --full --all 2> /dev/null | grep -q "sshd.service" && SSH_SVC="sshd"
run_or_dry systemctl restart "$SSH_SVC"
ROOT_STATUS="$([[ "$DISABLE_ROOT_SSH" == "true" ]] && echo "disabled" || echo "enabled")"
success "SSH hardened (port: ${SSH_PORT}, root login: ${ROOT_STATUS})"

creds_save "SSH_PORT" "$SSH_PORT"

# UFW Firewall — preserve existing rules, just ensure SSH/HTTP/HTTPS are open
step "Configuring UFW firewall..."
ufw default deny incoming > /dev/null 2>&1 || true
ufw default allow outgoing > /dev/null 2>&1 || true
ufw allow "${SSH_PORT}/tcp" > /dev/null
ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null

ask_yn OPEN_3306 "Open MySQL port 3306 (only if remote DB access needed)?" "n"
[[ "$OPEN_3306" == "true" ]] && ufw allow 3306/tcp > /dev/null

ask_yn OPEN_6379 "Open Redis port 6379 (only if remote access needed)?" "n"
[[ "$OPEN_6379" == "true" ]] && ufw allow 6379/tcp > /dev/null

ufw --force enable > /dev/null
success "UFW enabled. Open ports: SSH (${SSH_PORT}), HTTP (80), HTTPS (443)"

# Fail2ban
step "Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 3
bantime  = 86400
EOF

systemctl enable fail2ban --quiet
systemctl restart fail2ban
success "Fail2ban configured (SSH: max 3 retries, 24h ban)."

# sudoers for deploy user (passwordless for artisan)
ask_yn SUDO_NOPASSWD "Allow ${DEPLOY_USER} passwordless sudo for artisan/supervisorctl?" "y"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  cat > "/etc/sudoers.d/${DEPLOY_USER}" << EOF
${DEPLOY_USER} ALL=(ALL) NOPASSWD: /usr/bin/php /usr/sbin/supervisorctl /bin/systemctl
EOF
  chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"
  success "Passwordless sudo configured for ${DEPLOY_USER}."
fi

success "Server hardening complete."
