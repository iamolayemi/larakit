#!/usr/bin/env bash
# =============================================================================
#  Module 02 — Server Hardening
#  Creates deploy user, hardens SSH, configures UFW & Fail2ban
#  Run standalone: sudo bash modules/02-server-hardening.sh
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
ask SSH_PORT "SSH port" "22"
ask_yn DISABLE_ROOT_SSH "Disable root SSH login?" "y"
ask_yn DISABLE_PASSWORD_AUTH "Disable password authentication (use keys only)?" "y"

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

systemctl restart sshd
ROOT_STATUS="$([[ "$DISABLE_ROOT_SSH" == "true" ]] && echo "disabled" || echo "enabled")"
success "SSH hardened (port: ${SSH_PORT}, root login: ${ROOT_STATUS})"

creds_save "SSH_PORT" "$SSH_PORT"

# UFW Firewall
step "Configuring UFW firewall..."
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
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
